const std = @import("std");
const build_options = @import("build_options");
const types = @import("../types.zig");
const Handler = types.Handler;
const EventType = types.EventType;
const ObjectType = types.ObjectType;

pub const watches_recursively = false;
pub const detects_file_modifications = true;

const PendingRename = struct {
    cookie: u32,
    path: []u8, // owned
    object_type: ObjectType,
};

handler: *Handler,
inotify_fd: std.posix.fd_t,
watches: std.AutoHashMapUnmanaged(i32, []u8), // wd -> owned path
pending_renames: std.ArrayListUnmanaged(PendingRename),
// Used only in linux_read_thread mode:
stop_pipe: if (build_options.linux_read_thread) [2]std.posix.fd_t else void,
thread: if (build_options.linux_read_thread) ?std.Thread else void,

const IN = std.os.linux.IN;

const watch_mask: u32 = IN.CREATE | IN.DELETE | IN.MODIFY |
    IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF |
    IN.MOVE_SELF | IN.CLOSE_WRITE;

const in_flags: std.os.linux.O = .{ .NONBLOCK = true };

pub fn init(handler: *Handler) !@This() {
    const inotify_fd = try std.posix.inotify_init1(@bitCast(in_flags));
    errdefer std.posix.close(inotify_fd);
    if (comptime build_options.linux_read_thread) {
        const stop_pipe = try std.posix.pipe();
        return .{
            .handler = handler,
            .inotify_fd = inotify_fd,
            .watches = .empty,
            .pending_renames = .empty,
            .stop_pipe = stop_pipe,
            .thread = null,
        };
    } else {
        return .{
            .handler = handler,
            .inotify_fd = inotify_fd,
            .watches = .empty,
            .pending_renames = .empty,
            .stop_pipe = {},
            .thread = {},
        };
    }
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    if (comptime build_options.linux_read_thread) {
        // Signal thread to stop and wait for it to exit.
        _ = std.posix.write(self.stop_pipe[1], "x") catch {};
        if (self.thread) |t| t.join();
        std.posix.close(self.stop_pipe[0]);
        std.posix.close(self.stop_pipe[1]);
    }
    var it = self.watches.iterator();
    while (it.next()) |entry| allocator.free(entry.value_ptr.*);
    self.watches.deinit(allocator);
    for (self.pending_renames.items) |r| allocator.free(r.path);
    self.pending_renames.deinit(allocator);
    std.posix.close(self.inotify_fd);
}

pub fn arm(self: *@This(), allocator: std.mem.Allocator) error{HandlerFailed}!void {
    if (comptime build_options.linux_read_thread) {
        if (self.thread != null) return; // already running
        self.thread = std.Thread.spawn(.{}, thread_fn, .{ self, allocator }) catch return error.HandlerFailed;
    } else {
        return switch (self.handler.wait_readable() catch |e| switch (e) {
            error.HandlerFailed => |e_| return e_,
        }) {
            .will_notify => {},
        };
    }
}

fn thread_fn(self: *@This(), allocator: std.mem.Allocator) void {
    var pfds = [_]std.posix.pollfd{
        .{ .fd = self.inotify_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = self.stop_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        _ = std.posix.poll(&pfds, -1) catch return;
        if (pfds[1].revents & std.posix.POLL.IN != 0) return; // stop signal
        if (pfds[0].revents & std.posix.POLL.IN != 0) {
            self.handle_read_ready(allocator) catch return;
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
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const result = try self.watches.getOrPut(allocator, @intCast(wd));
    if (result.found_existing) allocator.free(result.value_ptr.*);
    result.value_ptr.* = owned_path;
}

pub fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.*, path)) continue;
        _ = std.os.linux.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
        self.watches.removeByPtr(entry.key_ptr);
        return;
    }
}

fn has_watch_for_path(self: *const @This(), path: []const u8) bool {
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, path)) return true;
    }
    return false;
}

pub fn handle_read_ready(self: *@This(), allocator: std.mem.Allocator) (std.posix.ReadError || error{ NoSpaceLeft, OutOfMemory, HandlerFailed })!void {
    const InotifyEvent = extern struct {
        wd: i32,
        mask: u32,
        cookie: u32,
        len: u32,
    };

    var buf: [65536]u8 align(@alignOf(InotifyEvent)) = undefined;
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
                // re-arm the file_discriptor
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
            const watched_path = self.watches.get(ev.wd) orelse continue;
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
                    try self.handler.rename(r.path, full_path, r.object_type);
                } else {
                    // No paired MOVED_FROM, file was moved in from outside the watched tree.
                    const ot: ObjectType = if (ev.mask & IN.ISDIR != 0) .dir else .file;
                    try self.handler.change(full_path, EventType.created, ot);
                }
            } else if (ev.mask & IN.MOVE_SELF != 0) {
                // The watched directory itself was renamed/moved away.
                try self.handler.change(full_path, EventType.deleted, .dir);
            } else {
                const is_dir = ev.mask & IN.ISDIR != 0;
                const object_type: ObjectType = if (is_dir) .dir else .file;
                const event_type: EventType = if (ev.mask & IN.CREATE != 0)
                    .created
                else if (ev.mask & (IN.DELETE | IN.DELETE_SELF) != 0) blk: {
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
