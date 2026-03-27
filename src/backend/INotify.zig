const std = @import("std");
const types = @import("../types.zig");
const EventType = types.EventType;
const ObjectType = types.ObjectType;
const InterfaceType = types.InterfaceType;

const PendingRename = struct {
    cookie: u32,
    path: []u8, // owned
    object_type: ObjectType,
};

pub fn Create(comptime variant: InterfaceType) type {
    return struct {
        handler: *Handler,
        inotify_fd: std.posix.fd_t,
        watches: std.AutoHashMapUnmanaged(i32, WatchEntry), // wd -> {owned path, is dir}
        // Protects `watches` against concurrent access by the background thread
        // (handle_read_ready / has_watch_for_path) and the main thread
        // (add_watch / remove_watch).  Void for the polling variant, which is
        // single-threaded.
        watches_mutex: switch (variant) {
            .threaded => std.Thread.Mutex,
            .polling => void,
        },
        pending_renames: std.ArrayListUnmanaged(PendingRename),
        stop_pipe: switch (variant) {
            .threaded => [2]std.posix.fd_t,
            .polling => void,
        },
        thread: switch (variant) {
            .threaded => ?std.Thread,
            .polling => void,
        },

        pub const watches_recursively = false;
        pub const detects_file_modifications = true;
        pub const polling = variant == .polling;

        const WatchEntry = struct { path: []u8, is_dir: bool };

        const Handler = switch (variant) {
            .threaded => types.Handler,
            .polling => types.PollingHandler,
        };

        const IN = std.os.linux.IN;

        const watch_mask: u32 = IN.CREATE | IN.DELETE | IN.MODIFY |
            IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF |
            IN.MOVE_SELF | IN.CLOSE_WRITE;

        const in_flags: std.os.linux.O = .{ .NONBLOCK = true };

        pub fn init(handler: *Handler) !@This() {
            const inotify_fd = try std.posix.inotify_init1(@bitCast(in_flags));
            errdefer std.posix.close(inotify_fd);
            switch (variant) {
                .threaded => {
                    const stop_pipe = try std.posix.pipe();
                    return .{
                        .handler = handler,
                        .inotify_fd = inotify_fd,
                        .watches = .empty,
                        .watches_mutex = .{},
                        .pending_renames = .empty,
                        .stop_pipe = stop_pipe,
                        .thread = null,
                    };
                },
                .polling => {
                    return .{
                        .handler = handler,
                        .inotify_fd = inotify_fd,
                        .watches = .empty,
                        .watches_mutex = {},
                        .pending_renames = .empty,
                        .stop_pipe = {},
                        .thread = {},
                    };
                },
            }
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (comptime variant == .threaded) {
                // Signal thread to stop and wait for it to exit.
                _ = std.posix.write(self.stop_pipe[1], "x") catch {};
                if (self.thread) |t| t.join();
                std.posix.close(self.stop_pipe[0]);
                std.posix.close(self.stop_pipe[1]);
            }
            var it = self.watches.iterator();
            while (it.next()) |entry| allocator.free(entry.value_ptr.*.path);
            self.watches.deinit(allocator);
            for (self.pending_renames.items) |r| allocator.free(r.path);
            self.pending_renames.deinit(allocator);
            std.posix.close(self.inotify_fd);
        }

        pub fn arm(self: *@This(), allocator: std.mem.Allocator) error{HandlerFailed}!void {
            switch (variant) {
                .threaded => {
                    if (self.thread != null) return; // already running
                    self.thread = std.Thread.spawn(.{}, thread_fn, .{ self, allocator }) catch return error.HandlerFailed;
                },
                .polling => {
                    return switch (self.handler.wait_readable() catch |e| switch (e) {
                        error.HandlerFailed => |e_| return e_,
                    }) {
                        .will_notify => {},
                    };
                },
            }
        }

        fn thread_fn(self: *@This(), allocator: std.mem.Allocator) void {
            var pfds = [_]std.posix.pollfd{
                .{ .fd = self.inotify_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
            };
            while (true) {
                _ = std.posix.poll(&pfds, -1) catch |e| {
                    std.log.err("nightwatch: poll failed: {s}, stopping watch thread", .{@errorName(e)});
                    return;
                };
                if (pfds[1].revents & std.posix.POLL.IN != 0) return; // stop signal
                if (pfds[0].revents & std.posix.POLL.IN != 0) {
                    self.handle_read_ready(allocator) catch |e| {
                        std.log.err("nightwatch: handler returned {s}, stopping watch thread", .{@errorName(e)});
                        return;
                    };
                }
            }
        }

        pub fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, WatchFailed }!void {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            const wd = std.os.linux.inotify_add_watch(self.inotify_fd, path_z, watch_mask);
            switch (std.posix.errno(wd)) {
                .SUCCESS => {},
                else => |e| {
                    std.log.err("nightwatch.add_watch failed: {t}", .{e});
                    return error.WatchFailed;
                },
            }
            const is_dir = blk: {
                var d = std.fs.openDirAbsolute(path, .{}) catch break :blk false;
                defer d.close();
                break :blk true;
            };
            const owned_path = try allocator.dupe(u8, path);
            errdefer allocator.free(owned_path);
            if (comptime variant == .threaded) self.watches_mutex.lock();
            defer if (comptime variant == .threaded) self.watches_mutex.unlock();
            const result = try self.watches.getOrPut(allocator, @intCast(wd));
            if (result.found_existing) allocator.free(result.value_ptr.*.path);
            result.value_ptr.* = .{ .path = owned_path, .is_dir = is_dir };
        }

        pub fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
            if (comptime variant == .threaded) self.watches_mutex.lock();
            defer if (comptime variant == .threaded) self.watches_mutex.unlock();
            var it = self.watches.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.value_ptr.*.path, path)) continue;
                _ = std.os.linux.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
                allocator.free(entry.value_ptr.*.path);
                self.watches.removeByPtr(entry.key_ptr);
                return;
            }
        }

        fn has_watch_for_path(self: *@This(), path: []const u8) bool {
            if (comptime variant == .threaded) self.watches_mutex.lock();
            defer if (comptime variant == .threaded) self.watches_mutex.unlock();
            var it = self.watches.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*.path, path)) return true;
            }
            return false;
        }

        // Rewrite stored watch paths after a directory rename.
        // Any entry equal to old_path is updated to new_path; any entry whose
        // path begins with old_path + sep has its prefix replaced with new_path.
        fn rename_watch_paths(self: *@This(), allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) void {
            if (comptime variant == .threaded) self.watches_mutex.lock();
            defer if (comptime variant == .threaded) self.watches_mutex.unlock();
            var it = self.watches.valueIterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.path, old_path)) {
                    const owned = allocator.dupe(u8, new_path) catch continue;
                    allocator.free(entry.path);
                    entry.path = owned;
                } else if (std.mem.startsWith(u8, entry.path, old_path) and
                    entry.path.len > old_path.len and
                    entry.path[old_path.len] == std.fs.path.sep)
                {
                    const suffix = entry.path[old_path.len..]; // includes leading sep
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const new_sub = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ new_path, suffix }) catch continue;
                    const owned = allocator.dupe(u8, new_sub) catch continue;
                    allocator.free(entry.path);
                    entry.path = owned;
                }
            }
        }

        pub fn handle_read_ready(self: *@This(), allocator: std.mem.Allocator) (std.posix.ReadError || error{ NoSpaceLeft, OutOfMemory, HandlerFailed })!void {
            const InotifyEvent = extern struct {
                wd: i32,
                mask: u32,
                cookie: u32,
                len: u32,
            };

            var buf: [65536]u8 align(@alignOf(InotifyEvent)) = undefined;
            // Src paths for which we already emitted a paired atomic rename this
            // read, so IN_MOVE_SELF for the same inode can be suppressed.
            var paired_src_paths: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (paired_src_paths.items) |p| allocator.free(p);
                paired_src_paths.deinit(allocator);
            }
            defer {
                // Any unpaired MOVED_FROM means the file was moved out of the watched tree.
                for (self.pending_renames.items) |r| {
                    self.handler.change(r.path, EventType.deleted, r.object_type) catch {};
                    allocator.free(r.path);
                }
                self.pending_renames.clearRetainingCapacity();
            }

            while (true) {
                const n = std.posix.read(self.inotify_fd, &buf) catch |e| switch (e) {
                    error.WouldBlock => {
                        // re-arm the file descriptor
                        try self.arm(allocator);
                        break;
                    },
                    else => return e,
                };
                var offset: usize = 0;
                while (offset + @sizeOf(InotifyEvent) <= n) {
                    const ev: *const InotifyEvent = @ptrCast(@alignCast(buf[offset..].ptr));
                    const name_offset = offset + @sizeOf(InotifyEvent);
                    offset = name_offset + ev.len;

                    // Copy the watched path under the lock so a concurrent remove_watch
                    // cannot free the slice while we are still reading from it.
                    var watched_buf: [std.fs.max_path_bytes]u8 = undefined;
                    var watched_len: usize = 0;
                    var watched_is_dir = false;
                    if (comptime variant == .threaded) self.watches_mutex.lock();
                    if (self.watches.get(ev.wd)) |e| {
                        @memcpy(watched_buf[0..e.path.len], e.path);
                        watched_len = e.path.len;
                        watched_is_dir = e.is_dir;
                    }
                    if (comptime variant == .threaded) self.watches_mutex.unlock();
                    if (watched_len == 0) continue;
                    const watched_path = watched_buf[0..watched_len];

                    const name: []const u8 = if (ev.len > 0)
                        std.mem.sliceTo(buf[name_offset..][0..ev.len], 0)
                    else
                        "";

                    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const full_path: []const u8 = if (name.len > 0)
                        try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ watched_path, name })
                    else
                        watched_path;

                    if (ev.mask & IN.MOVED_FROM != 0) {
                        // Park it, we may receive a paired MOVED_TO with the same cookie.
                        try self.pending_renames.append(allocator, .{
                            .cookie = ev.cookie,
                            .path = try allocator.dupe(u8, full_path),
                            .object_type = if (ev.mask & IN.ISDIR != 0) .dir else .file,
                        });
                    } else if (ev.mask & IN.MOVED_TO != 0) {
                        // Look for a paired MOVED_FROM.
                        var found: ?usize = null;
                        for (self.pending_renames.items, 0..) |r, i| {
                            if (r.cookie == ev.cookie) {
                                found = i;
                                break;
                            }
                        }
                        if (found) |i| {
                            // Complete rename pair: emit a single atomic rename message.
                            const r = self.pending_renames.swapRemove(i);
                            defer allocator.free(r.path);
                            // Rewrite any watch entries whose stored path starts with the
                            // old directory path so subsequent events use the new name.
                            if (r.object_type == .dir)
                                self.rename_watch_paths(allocator, r.path, full_path);
                            // Track the path MOVE_SELF will see so it can be suppressed.
                            // For directory renames the watch path has just been rewritten
                            // to full_path (new name); for file renames it stays r.path.
                            const move_self_path = if (r.object_type == .dir) full_path else r.path;
                            if (allocator.dupe(u8, move_self_path) catch null) |copy|
                                paired_src_paths.append(allocator, copy) catch allocator.free(copy);
                            try self.handler.rename(r.path, full_path, r.object_type);
                        } else {
                            // No paired MOVED_FROM, file was moved in from outside the watched tree.
                            const ot: ObjectType = if (ev.mask & IN.ISDIR != 0) .dir else .file;
                            try self.handler.change(full_path, EventType.created, ot);
                        }
                    } else if (ev.mask & IN.MOVE_SELF != 0) {
                        // Suppress if the rename was already delivered as a paired
                        // MOVED_FROM/MOVED_TO event, or if it is still in pending_renames
                        // as an unpaired MOVED_FROM (the defer above will emit 'deleted').
                        // Only emit here when the watched root was moved and its parent
                        // directory is not itself watched (no MOVED_FROM was generated).
                        const already_handled =
                            (for (paired_src_paths.items) |p| {
                                if (std.mem.eql(u8, p, full_path)) break true;
                            } else false) or
                            (for (self.pending_renames.items) |r| {
                                if (std.mem.eql(u8, r.path, full_path)) break true;
                            } else false);
                        if (!already_handled)
                            try self.handler.change(full_path, EventType.deleted, .dir);
                    } else if (ev.mask & IN.DELETE_SELF != 0) {
                        // The watched path itself was deleted. IN_DELETE_SELF does not
                        // set IN_ISDIR, so use the is_dir recorded at watch registration.
                        const object_type: ObjectType = if (watched_is_dir) .dir else .file;
                        try self.handler.change(full_path, EventType.deleted, object_type);
                    } else {
                        const is_dir = ev.mask & IN.ISDIR != 0;
                        const object_type: ObjectType = if (is_dir) .dir else .file;
                        const event_type: EventType = if (ev.mask & IN.CREATE != 0)
                            .created
                        else if (ev.mask & IN.DELETE != 0) blk: {
                            // Suppress IN_DELETE|IN_ISDIR for subdirs that have their
                            // own watch: IN_DELETE_SELF on that watch will fire the
                            // same path without duplication.
                            if (is_dir and self.has_watch_for_path(full_path))
                                continue;
                            break :blk .deleted;
                        } else if (ev.mask & (IN.MODIFY | IN.CLOSE_WRITE) != 0)
                            .modified
                        else
                            continue;
                        try self.handler.change(full_path, event_type, object_type);
                    }
                }
            }
        }
    };
}
