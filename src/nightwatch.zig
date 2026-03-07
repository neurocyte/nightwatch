const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const EventType = enum {
    created,
    modified,
    deleted,
    /// A new directory was created inside a watched directory.
    /// The library automatically begins watching it; no action is required.
    dir_created,
    /// Only produced on macOS and Windows where the OS gives no pairing info.
    /// On Linux, paired renames are emitted as a { "FW", "rename", from, to } message instead.
    renamed,
};

pub const Error = error{
    HandlerFailed,
    OutOfMemory,
    WatchFailed,
};

pub const Handler = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        change: *const fn (handler: *Handler, path: []const u8, event_type: EventType) error{HandlerFailed}!void,
        rename: *const fn (handler: *Handler, src_path: []const u8, dst_path: []const u8) error{HandlerFailed}!void,
        wait_readable: if (builtin.os.tag == .linux) *const fn (handler: *Handler) error{HandlerFailed}!ReadableStatus else void,
    };

    fn change(handler: *Handler, path: []const u8, event_type: EventType) error{HandlerFailed}!void {
        return handler.vtable.change(handler, path, event_type);
    }

    fn rename(handler: *Handler, src_path: []const u8, dst_path: []const u8) error{HandlerFailed}!void {
        return handler.vtable.rename(handler, src_path, dst_path);
    }

    fn wait_readable(handler: *Handler) error{HandlerFailed}!ReadableStatus {
        return handler.vtable.wait_readable(handler);
    }
};

pub const ReadableStatus = enum {
    // TODO: is_readable, // backend may now read from fd (blocking mode)
    will_notify, // backend must wait for a handle_read_ready call
};

allocator: std.mem.Allocator,
interceptor: *Interceptor,

pub fn init(allocator: std.mem.Allocator, handler: *Handler) !@This() {
    const ic = try allocator.create(Interceptor);
    errdefer allocator.destroy(ic);
    ic.* = .{
        .handler = .{ .vtable = &Interceptor.vtable },
        .user_handler = handler,
        .allocator = allocator,
        .backend = undefined,
    };
    ic.backend = try Backend.init(&ic.handler);
    errdefer ic.backend.deinit(allocator);
    try ic.backend.arm(allocator);
    return .{ .allocator = allocator, .interceptor = ic };
}

pub fn deinit(self: *@This()) void {
    self.interceptor.backend.deinit(self.allocator);
    self.allocator.destroy(self.interceptor);
}

/// Watch a path (file or directory) for changes. The handler will receive
/// `change` and (linux only) `rename` calls. When path is a directory,
/// all subdirectories are watched recursively and new directories created
/// inside are watched automatically.
pub fn watch(self: *@This(), path: []const u8) Error!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(path, &buf) catch return error.WatchFailed;
    try self.interceptor.backend.add_watch(self.allocator, abs_path);
    if (!Backend.watches_recursively) {
        recurse_watch(&self.interceptor.backend, self.allocator, abs_path);
    }
}

/// Stop watching a previously watched path
pub fn unwatch(self: *@This(), path: []const u8) void {
    self.interceptor.backend.remove_watch(self.allocator, path);
}

pub fn handle_read_ready(self: *@This()) !void {
    try self.interceptor.backend.handle_read_ready(self.allocator);
}

/// Returns the inotify file descriptor that should be polled for POLLIN
/// before calling handle_read_ready(). Only available on Linux.
pub fn poll_fd(self: *const @This()) std.posix.fd_t {
    comptime if (builtin.os.tag != .linux) @compileError("poll_fd is only available on Linux");
    return self.interceptor.backend.inotify_fd;
}

// Wraps the user's handler to intercept dir_created events and auto-watch
// new directories before forwarding to the user.
// Heap-allocated so that &ic.handler stays valid regardless of how the
// nightwatch struct is moved after init() returns.
const Interceptor = struct {
    handler: Handler,
    user_handler: *Handler,
    allocator: std.mem.Allocator,
    backend: Backend,

    const vtable = Handler.VTable{
        .change = change_cb,
        .rename = rename_cb,
        .wait_readable = if (builtin.os.tag == .linux) wait_readable_cb else {},
    };

    fn change_cb(h: *Handler, path: []const u8, event_type: EventType) error{HandlerFailed}!void {
        const self: *Interceptor = @fieldParentPtr("handler", h);
        if (event_type == .dir_created and !Backend.watches_recursively) {
            self.backend.add_watch(self.allocator, path) catch {};
            recurse_watch(&self.backend, self.allocator, path);
        }
        return self.user_handler.change(path, event_type);
    }

    fn rename_cb(h: *Handler, src: []const u8, dst: []const u8) error{HandlerFailed}!void {
        const self: *Interceptor = @fieldParentPtr("handler", h);
        return self.user_handler.rename(src, dst);
    }

    fn wait_readable_cb(h: *Handler) error{HandlerFailed}!ReadableStatus {
        const self: *Interceptor = @fieldParentPtr("handler", h);
        return self.user_handler.wait_readable();
    }
};

// Scans subdirectories of dir_path and adds a watch for each one, recursively.
fn recurse_watch(backend: *Backend, allocator: std.mem.Allocator, dir_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        if (entry.kind != .directory) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        backend.add_watch(allocator, sub) catch {};
        recurse_watch(backend, allocator, sub);
    }
}

const Backend = switch (builtin.os.tag) {
    .linux => INotifyBackend,
    .macos => if (build_options.use_fsevents) FSEventsBackend else KQueueBackend,
    .freebsd => KQueueBackend,
    .windows => WindowsBackend,
    else => @compileError("file_watcher: unsupported OS"),
};

const INotifyBackend = struct {
    const watches_recursively = false;

    handler: *Handler,
    inotify_fd: std.posix.fd_t,
    watches: std.AutoHashMapUnmanaged(i32, []u8), // wd -> owned path

    const IN = std.os.linux.IN;

    const watch_mask: u32 = IN.CREATE | IN.DELETE | IN.MODIFY |
        IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF |
        IN.MOVE_SELF | IN.CLOSE_WRITE;

    const in_flags: std.os.linux.O = .{ .NONBLOCK = true };

    fn init(handler: *Handler) error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, SystemResources, Unexpected }!@This() {
        return .{
            .handler = handler,
            .inotify_fd = try std.posix.inotify_init1(@bitCast(in_flags)),
            .watches = .empty,
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        self.watches.deinit(allocator);
        std.posix.close(self.inotify_fd);
    }

    fn arm(self: *@This(), _: std.mem.Allocator) error{HandlerFailed}!void {
        return switch (self.handler.wait_readable() catch |e| switch (e) {
            error.HandlerFailed => |e_| return e_,
        }) {
            .will_notify => {},
        };
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, WatchFailed }!void {
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

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, path)) continue;
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
            self.watches.removeByPtr(entry.key_ptr);
            return;
        }
    }

    fn handle_read_ready(self: *@This(), allocator: std.mem.Allocator) (std.posix.ReadError || error{ NoSpaceLeft, OutOfMemory, HandlerFailed })!void {
        const InotifyEvent = extern struct {
            wd: i32,
            mask: u32,
            cookie: u32,
            len: u32,
        };

        // A pending MOVED_FROM waiting to be paired with a MOVED_TO by cookie.
        const PendingRename = struct {
            cookie: u32,
            path: []u8, // owned by drain's allocator
        };

        var buf: [4096]u8 align(@alignOf(InotifyEvent)) = undefined;
        var pending_renames: std.ArrayListUnmanaged(PendingRename) = .empty;
        defer {
            // Any unpaired MOVED_FROM means the file was moved out of the watched tree.
            for (pending_renames.items) |r| {
                self.handler.change(r.path, EventType.deleted) catch {};
                allocator.free(r.path);
            }
            pending_renames.deinit(allocator);
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
                    try pending_renames.append(allocator, .{
                        .cookie = ev.cookie,
                        .path = try allocator.dupe(u8, full_path),
                    });
                } else if (ev.mask & IN.MOVED_TO != 0) {
                    // Look for a paired MOVED_FROM.
                    var found: ?usize = null;
                    for (pending_renames.items, 0..) |r, i| {
                        if (r.cookie == ev.cookie) {
                            found = i;
                            break;
                        }
                    }
                    if (found) |i| {
                        // Complete rename pair: emit a single atomic rename message.
                        const r = pending_renames.swapRemove(i);
                        defer allocator.free(r.path);
                        try self.handler.rename(r.path, full_path);
                    } else {
                        // No paired MOVED_FROM, file was moved in from outside the watched tree.
                        try self.handler.change(full_path, EventType.created);
                    }
                } else if (ev.mask & IN.MOVE_SELF != 0) {
                    // The watched directory itself was renamed/moved away.
                    try self.handler.change(full_path, EventType.deleted);
                } else {
                    const event_type: EventType = if (ev.mask & IN.CREATE != 0)
                        if (ev.mask & IN.ISDIR != 0) .dir_created else .created
                    else if (ev.mask & (IN.DELETE | IN.DELETE_SELF) != 0)
                        .deleted
                    else if (ev.mask & (IN.MODIFY | IN.CLOSE_WRITE) != 0)
                        .modified
                    else
                        continue;
                    try self.handler.change(full_path, event_type);
                }
            }
        }
    }
};

const FSEventsBackend = struct {
    const watches_recursively = true; // FSEventStreamCreate watches the entire subtree

    handler: *Handler,
    stream: ?*anyopaque, // FSEventStreamRef
    queue: ?*anyopaque, // dispatch_queue_t
    ctx: ?*CallbackContext, // heap-allocated, freed after stream is stopped
    watches: std.StringArrayHashMapUnmanaged(void), // owned paths

    const threaded = false; // callback fires on GCD thread; no FW_event needed

    const kFSEventStreamCreateFlagNoDefer: u32 = 0x00000002;
    const kFSEventStreamCreateFlagFileEvents: u32 = 0x00000010;
    const kFSEventStreamEventFlagItemCreated: u32 = 0x00000100;
    const kFSEventStreamEventFlagItemRemoved: u32 = 0x00000200;
    const kFSEventStreamEventFlagItemRenamed: u32 = 0x00000800;
    const kFSEventStreamEventFlagItemModified: u32 = 0x00001000;
    const kFSEventStreamEventFlagItemIsDir: u32 = 0x00020000;
    const kFSEventStreamEventIdSinceNow: u64 = 0xFFFFFFFFFFFFFFFF;
    const kCFStringEncodingUTF8: u32 = 0x08000100;

    const cf = struct {
        pub extern "c" fn CFStringCreateWithBytesNoCopy(
            alloc: ?*anyopaque,
            bytes: [*]const u8,
            numBytes: isize,
            encoding: u32,
            isExternalRepresentation: u8,
            contentsDeallocator: ?*anyopaque,
        ) ?*anyopaque;
        pub extern "c" fn CFArrayCreate(
            allocator: ?*anyopaque,
            values: [*]const ?*anyopaque,
            numValues: isize,
            callBacks: ?*anyopaque,
        ) ?*anyopaque;
        pub extern "c" fn CFRelease(cf: *anyopaque) void;
        pub extern "c" fn FSEventStreamCreate(
            allocator: ?*anyopaque,
            callback: *const anyopaque,
            context: ?*anyopaque,
            pathsToWatch: *anyopaque,
            sinceWhen: u64,
            latency: f64,
            flags: u32,
        ) ?*anyopaque;
        pub extern "c" fn FSEventStreamSetDispatchQueue(stream: *anyopaque, queue: *anyopaque) void;
        pub extern "c" fn FSEventStreamStart(stream: *anyopaque) u8;
        pub extern "c" fn FSEventStreamStop(stream: *anyopaque) void;
        pub extern "c" fn FSEventStreamInvalidate(stream: *anyopaque) void;
        pub extern "c" fn FSEventStreamRelease(stream: *anyopaque) void;
        pub extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) *anyopaque;
        pub extern "c" fn dispatch_release(obj: *anyopaque) void;
        pub extern "c" var kCFAllocatorNull: *anyopaque;
    };

    const CallbackContext = struct {
        handler: *Handler,
    };

    fn init(handler: *Handler) error{}!@This() {
        return .{
            .handler = handler,
            .stream = null,
            .queue = null,
            .ctx = null,
            .watches = .empty,
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.stream) |s| {
            cf.FSEventStreamStop(s);
            cf.FSEventStreamInvalidate(s);
            cf.FSEventStreamRelease(s);
            self.stream = null;
        }
        if (self.queue) |q| {
            cf.dispatch_release(q);
            self.queue = null;
        }
        if (self.ctx) |c| {
            allocator.destroy(c);
            self.ctx = null;
        }
        var it = self.watches.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.watches.deinit(allocator);
    }

    fn arm(self: *@This(), allocator: std.mem.Allocator) error{ OutOfMemory, ArmFailed }!void {
        if (self.stream != null) return;

        var cf_strings: std.ArrayListUnmanaged(?*anyopaque) = .empty;
        defer cf_strings.deinit(allocator);
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const s = cf.CFStringCreateWithBytesNoCopy(
                null,
                path.ptr,
                @intCast(path.len),
                kCFStringEncodingUTF8,
                0,
                cf.kCFAllocatorNull,
            ) orelse continue;
            cf_strings.append(allocator, s) catch {
                cf.CFRelease(s);
                break;
            };
        }
        defer for (cf_strings.items) |s| cf.CFRelease(s.?);

        const paths_array = cf.CFArrayCreate(
            null,
            cf_strings.items.ptr,
            @intCast(cf_strings.items.len),
            null,
        ) orelse return error.ArmFailed;
        defer cf.CFRelease(paths_array);

        const ctx = try allocator.create(CallbackContext);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .handler = self.handler };

        const stream = cf.FSEventStreamCreate(
            null,
            @ptrCast(&callback),
            ctx,
            paths_array,
            kFSEventStreamEventIdSinceNow,
            0.1,
            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents,
        ) orelse return error.ArmFailed;
        errdefer cf.FSEventStreamRelease(stream);

        const queue = cf.dispatch_queue_create("flow.file_watcher", null);
        cf.FSEventStreamSetDispatchQueue(stream, queue);
        _ = cf.FSEventStreamStart(stream);

        self.stream = stream;
        self.queue = queue;
        self.ctx = ctx;
    }

    fn callback(
        _: *anyopaque,
        info: ?*anyopaque,
        num_events: usize,
        event_paths: *anyopaque,
        event_flags: [*]const u32,
        _: [*]const u64,
    ) callconv(.c) void {
        const ctx: *CallbackContext = @ptrCast(@alignCast(info orelse return));
        const paths: [*][*:0]const u8 = @ptrCast(@alignCast(event_paths));
        for (0..num_events) |i| {
            const path = std.mem.sliceTo(paths[i], 0);
            const flags = event_flags[i];
            const event_type: EventType = if (flags & kFSEventStreamEventFlagItemRemoved != 0)
                .deleted
            else if (flags & kFSEventStreamEventFlagItemCreated != 0)
                if (flags & kFSEventStreamEventFlagItemIsDir != 0) .dir_created else .created
            else if (flags & kFSEventStreamEventFlagItemRenamed != 0)
                .renamed
            else if (flags & kFSEventStreamEventFlagItemModified != 0)
                .modified
            else
                continue;
            ctx.handler.change(path, event_type) catch |e| switch (e) {
                error.HandlerFailed => {
                    std.log.err("nightwatch.callback failed: {t}", .{e});
                },
            };
        }
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}!void {
        if (self.watches.contains(path)) return;
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.watches.put(allocator, owned, {});
        // Watches added after arm() take effect on the next restart.
        // In practice all watches are added before arm() is called.
    }

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        if (self.watches.fetchSwapRemove(path)) |entry| allocator.free(entry.key);
    }
};

const KQueueBackend = struct {
    const watches_recursively = false;

    handler: *Handler,
    kq: std.posix.fd_t,
    shutdown_pipe: [2]std.posix.fd_t, // [0]=read [1]=write; write a byte to wake the thread
    thread: ?std.Thread,
    watches: std.StringHashMapUnmanaged(std.posix.fd_t), // owned dir path -> fd
    watches_mutex: std.Thread.Mutex,
    file_watches: std.StringHashMapUnmanaged(std.posix.fd_t), // owned file path -> fd
    file_watches_mutex: std.Thread.Mutex,
    // Per-directory snapshots of filenames, used to diff on NOTE_WRITE.
    // Key: owned dir path (same as watches key), value: set of owned filenames.
    // Accessed from both the main thread (add_watch) and the background thread (scan_dir).
    snapshots: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
    snapshots_mutex: std.Thread.Mutex,

    const EVFILT_VNODE: i16 = -4;
    const EVFILT_READ: i16 = -1;
    const EV_ADD: u16 = 0x0001;
    const EV_ENABLE: u16 = 0x0004;
    const EV_CLEAR: u16 = 0x0020;
    const EV_DELETE: u16 = 0x0002;
    const NOTE_DELETE: u32 = 0x00000001;
    const NOTE_WRITE: u32 = 0x00000002;
    const NOTE_EXTEND: u32 = 0x00000004;
    const NOTE_ATTRIB: u32 = 0x00000008;
    const NOTE_RENAME: u32 = 0x00000020;

    fn init(handler: *Handler) (std.posix.KQueueError || std.posix.KEventError)!@This() {
        const kq = try std.posix.kqueue();
        errdefer std.posix.close(kq);
        const pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(pipe[0]);
            std.posix.close(pipe[1]);
        }
        // Register the read end of the shutdown pipe with kqueue so the thread
        // wakes up when we want to shut down.
        const shutdown_kev = std.posix.Kevent{
            .ident = @intCast(pipe[0]),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        _ = try std.posix.kevent(kq, &.{shutdown_kev}, &.{}, null);
        return .{
            .handler = handler,
            .kq = kq,
            .shutdown_pipe = pipe,
            .thread = null,
            .watches = .empty,
            .watches_mutex = .{},
            .file_watches = .empty,
            .file_watches_mutex = .{},
            .snapshots = .empty,
            .snapshots_mutex = .{},
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Signal the thread to exit by writing to the shutdown pipe.
        _ = std.posix.write(self.shutdown_pipe[1], &[_]u8{0}) catch {};
        if (self.thread) |t| t.join();
        std.posix.close(self.shutdown_pipe[0]);
        std.posix.close(self.shutdown_pipe[1]);
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            std.posix.close(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.watches.deinit(allocator);
        var fit = self.file_watches.iterator();
        while (fit.next()) |entry| {
            std.posix.close(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.file_watches.deinit(allocator);
        var sit = self.snapshots.iterator();
        while (sit.next()) |entry| {
            // Keys are borrowed from self.watches and freed in the watches loop above.
            var names = entry.value_ptr.*;
            var nit = names.iterator();
            while (nit.next()) |ne| allocator.free(ne.key_ptr.*);
            names.deinit(allocator);
        }
        self.snapshots.deinit(allocator);
        std.posix.close(self.kq);
    }

    fn arm(self: *@This(), allocator: std.mem.Allocator) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
        if (self.thread != null) return error.AlreadyArmed;
        self.thread = try std.Thread.spawn(.{}, thread_fn, .{ self, allocator });
    }

    fn thread_fn(self: *@This(), allocator: std.mem.Allocator) void {
        var events: [64]std.posix.Kevent = undefined;
        while (true) {
            // Block indefinitely until kqueue has events.
            const n = std.posix.kevent(self.kq, &.{}, &events, null) catch break;
            for (events[0..n]) |ev| {
                if (ev.filter == EVFILT_READ) return; // shutdown pipe readable, exit
                if (ev.filter != EVFILT_VNODE) continue;
                const fd: std.posix.fd_t = @intCast(ev.ident);

                // Check if this is a file watch: NOTE_WRITE/NOTE_EXTEND → modified.
                self.file_watches_mutex.lock();
                var fwit = self.file_watches.iterator();
                const file_path: ?[]const u8 = while (fwit.next()) |entry| {
                    if (entry.value_ptr.* == fd) break entry.key_ptr.*;
                } else null;
                self.file_watches_mutex.unlock();
                if (file_path) |fp| {
                    if (ev.fflags & (NOTE_WRITE | NOTE_EXTEND) != 0)
                        self.handler.change(fp, EventType.modified) catch return;
                    continue;
                }

                // Otherwise look up the directory path for this fd.
                self.watches_mutex.lock();
                var wit = self.watches.iterator();
                const dir_path: ?[]const u8 = while (wit.next()) |entry| {
                    if (entry.value_ptr.* == fd) break entry.key_ptr.*;
                } else null;
                self.watches_mutex.unlock();
                if (dir_path == null) continue;
                if (ev.fflags & NOTE_DELETE != 0) {
                    self.handler.change(dir_path.?, EventType.deleted) catch return;
                } else if (ev.fflags & NOTE_RENAME != 0) {
                    self.handler.change(dir_path.?, EventType.renamed) catch return;
                } else if (ev.fflags & NOTE_WRITE != 0) {
                    self.scan_dir(allocator, dir_path.?) catch {};
                }
            }
        }
    }

    // Scan a directory and diff against the snapshot, emitting created/deleted events.
    fn scan_dir(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect current files and subdirectories (no lock, reading filesystem only).
        var current_files: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = current_files.iterator();
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            current_files.deinit(allocator);
        }
        var current_dirs: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (current_dirs.items) |d| allocator.free(d);
            current_dirs.deinit(allocator);
        }
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const name = try allocator.dupe(u8, entry.name);
                    try current_files.put(allocator, name, {});
                },
                .directory => {
                    const name = try allocator.dupe(u8, entry.name);
                    try current_dirs.append(allocator, name);
                },
                else => {},
            }
        }

        // Diff against snapshot under the lock; collect events to emit after releasing it.
        var to_create: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_create.deinit(allocator);
        var to_delete: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_delete.deinit(allocator);
        var new_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer new_dirs.deinit(allocator);

        self.snapshots_mutex.lock();
        {
            for (current_dirs.items) |name| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
                if (!self.snapshots.contains(full_path))
                    try new_dirs.append(allocator, full_path);
            }

            const gop = self.snapshots.getOrPut(allocator, dir_path) catch |e| {
                self.snapshots_mutex.unlock();
                return e;
            };
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const snapshot = gop.value_ptr;

            var cit = current_files.iterator();
            while (cit.next()) |entry| {
                if (snapshot.contains(entry.key_ptr.*)) continue;
                const owned = allocator.dupe(u8, entry.key_ptr.*) catch |e| {
                    self.snapshots_mutex.unlock();
                    return e;
                };
                snapshot.put(allocator, owned, {}) catch |e| {
                    allocator.free(owned);
                    self.snapshots_mutex.unlock();
                    return e;
                };
                try to_create.append(allocator, owned);
            }

            var sit = snapshot.iterator();
            while (sit.next()) |entry| {
                if (current_files.contains(entry.key_ptr.*)) continue;
                try to_delete.append(allocator, entry.key_ptr.*);
            }
            for (to_delete.items) |name| _ = snapshot.fetchRemove(name);
        }
        self.snapshots_mutex.unlock();

        // Emit all events outside the lock so handlers may safely call watch()/unwatch().
        // Emit dir_created, then deletions, then creations. Deletions first ensures that
        // a rename (old disappears, new appears) reports the source path before the dest.
        for (new_dirs.items) |full_path|
            try self.handler.change(full_path, EventType.dir_created);
        for (to_delete.items) |name| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch {
                allocator.free(name);
                continue;
            };
            self.deregister_file_watch(allocator, full_path);
            try self.handler.change(full_path, EventType.deleted);
            allocator.free(name);
        }
        for (to_create.items) |name| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            self.register_file_watch(allocator, full_path);
            try self.handler.change(full_path, EventType.created);
        }
    }

    fn register_file_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        self.file_watches_mutex.lock();
        const already = self.file_watches.contains(path);
        self.file_watches_mutex.unlock();
        if (already) return;
        const fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return;
        const kev = std.posix.Kevent{
            .ident = @intCast(fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = NOTE_WRITE | NOTE_EXTEND,
            .data = 0,
            .udata = 0,
        };
        _ = std.posix.kevent(self.kq, &.{kev}, &.{}, null) catch {
            std.posix.close(fd);
            return;
        };
        const owned = allocator.dupe(u8, path) catch {
            std.posix.close(fd);
            return;
        };
        self.file_watches_mutex.lock();
        self.file_watches.put(allocator, owned, fd) catch {
            self.file_watches_mutex.unlock();
            std.posix.close(fd);
            allocator.free(owned);
            return;
        };
        self.file_watches_mutex.unlock();
    }

    fn deregister_file_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        self.file_watches_mutex.lock();
        const kv = self.file_watches.fetchRemove(path);
        self.file_watches_mutex.unlock();
        if (kv) |entry| {
            std.posix.close(entry.value);
            allocator.free(entry.key);
        }
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ WatchFailed, OutOfMemory }!void {
        self.watches_mutex.lock();
        const already = self.watches.contains(path);
        self.watches_mutex.unlock();
        if (already) return;
        const path_fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch |e| switch (e) {
            error.AccessDenied,
            error.PermissionDenied,
            error.PathAlreadyExists,
            error.SymLinkLoop,
            error.NameTooLong,
            error.FileNotFound,
            error.SystemResources,
            error.NoSpaceLeft,
            error.NotDir,
            error.InvalidUtf8,
            error.InvalidWtf8,
            error.BadPathName,
            error.NoDevice,
            error.NetworkNotFound,
            error.Unexpected,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.ProcessNotFound,
            error.FileTooBig,
            error.IsDir,
            error.DeviceBusy,
            error.FileLocksNotSupported,
            error.FileBusy,
            error.WouldBlock,
            => |e_| {
                std.log.err("{s} failed: {t}", .{ @src().fn_name, e_ });
                return error.WatchFailed;
            },
        };
        errdefer std.posix.close(path_fd);
        const kev = std.posix.Kevent{
            .ident = @intCast(path_fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND,
            .data = 0,
            .udata = 0,
        };
        _ = std.posix.kevent(self.kq, &.{kev}, &.{}, null) catch |e| switch (e) {
            error.AccessDenied,
            error.SystemResources,
            error.EventNotFound,
            error.ProcessNotFound,
            error.Overflow,
            => |e_| {
                std.log.err("{s} failed: {t}", .{ @src().fn_name, e_ });
                return error.WatchFailed;
            },
        };
        const owned_path = try allocator.dupe(u8, path);
        self.watches_mutex.lock();
        self.watches.put(allocator, owned_path, path_fd) catch |e| {
            self.watches_mutex.unlock();
            allocator.free(owned_path);
            return e;
        };
        self.watches_mutex.unlock();
        // Take initial snapshot so first NOTE_WRITE has a baseline to diff against.
        self.take_snapshot(allocator, owned_path) catch |e| switch (e) {
            error.AccessDenied,
            error.PermissionDenied,
            error.SystemResources,
            error.InvalidUtf8,
            error.Unexpected,
            => |e_| {
                std.log.err("{s} failed: {t}", .{ @src().fn_name, e_ });
                return error.WatchFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn take_snapshot(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        // Collect file names first so we can register file watches without holding the lock.
        var names: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        self.snapshots_mutex.lock();
        const gop = try self.snapshots.getOrPut(allocator, dir_path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        var snapshot = gop.value_ptr;
        for (names.items) |name| {
            if (snapshot.contains(name)) continue;
            const owned = try allocator.dupe(u8, name);
            try snapshot.put(allocator, owned, {});
        }
        self.snapshots_mutex.unlock();
        // Register a kqueue watch for each existing file so writes are detected.
        for (names.items) |name| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            self.register_file_watch(allocator, full_path);
        }
    }

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        self.watches_mutex.lock();
        const watches_entry = self.watches.fetchRemove(path);
        self.watches_mutex.unlock();
        if (watches_entry) |entry| {
            std.posix.close(entry.value);
            allocator.free(entry.key);
        }
        if (self.snapshots.fetchRemove(path)) |entry| {
            var names = entry.value;
            var it = names.iterator();
            while (it.next()) |ne| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, ne.key_ptr.* }) catch {
                    allocator.free(ne.key_ptr.*);
                    continue;
                };
                self.deregister_file_watch(allocator, full_path);
                allocator.free(ne.key_ptr.*);
            }
            names.deinit(allocator);
        }
    }
};

const WindowsBackend = struct {
    const watches_recursively = true; // ReadDirectoryChangesW with bWatchSubtree=1

    const windows = std.os.windows;

    const win32 = struct {
        pub extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn ReadDirectoryChangesW(
            hDirectory: windows.HANDLE,
            lpBuffer: *anyopaque,
            nBufferLength: windows.DWORD,
            bWatchSubtree: windows.BOOL,
            dwNotifyFilter: windows.DWORD,
            lpBytesReturned: ?*windows.DWORD,
            lpOverlapped: ?*windows.OVERLAPPED,
            lpCompletionRoutine: ?*anyopaque,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn GetQueuedCompletionStatus(
            CompletionPort: windows.HANDLE,
            lpNumberOfBytesTransferred: *windows.DWORD,
            lpCompletionKey: *windows.ULONG_PTR,
            lpOverlapped: *?*windows.OVERLAPPED,
            dwMilliseconds: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: [*:0]const windows.WCHAR,
            dwDesiredAccess: windows.DWORD,
            dwShareMode: windows.DWORD,
            lpSecurityAttributes: ?*anyopaque,
            dwCreationDisposition: windows.DWORD,
            dwFlagsAndAttributes: windows.DWORD,
            hTemplateFile: ?windows.HANDLE,
        ) callconv(.winapi) windows.HANDLE;
        pub extern "kernel32" fn PostQueuedCompletionStatus(
            CompletionPort: windows.HANDLE,
            dwNumberOfBytesTransferred: windows.DWORD,
            dwCompletionKey: windows.ULONG_PTR,
            lpOverlapped: ?*windows.OVERLAPPED,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const windows.WCHAR) callconv(.winapi) windows.DWORD;
    };

    handler: *Handler,
    iocp: windows.HANDLE,
    thread: ?std.Thread,
    watches: std.StringHashMapUnmanaged(Watch),
    watches_mutex: std.Thread.Mutex,

    // A completion key of zero is used to signal the background thread to exit.
    const SHUTDOWN_KEY: windows.ULONG_PTR = 0;

    const Watch = struct {
        handle: windows.HANDLE,
        buf: Buf,
        overlapped: windows.OVERLAPPED,
        path: []u8, // owned
    };

    const buf_size = 65536;
    const Buf = []align(4) u8;

    const FILE_NOTIFY_INFORMATION = extern struct {
        NextEntryOffset: windows.DWORD,
        Action: windows.DWORD,
        FileNameLength: windows.DWORD,
        FileName: [1]windows.WCHAR,
    };

    const FILE_ACTION_ADDED: windows.DWORD = 1;
    const FILE_ACTION_REMOVED: windows.DWORD = 2;
    const FILE_ACTION_MODIFIED: windows.DWORD = 3;
    const FILE_ACTION_RENAMED_OLD_NAME: windows.DWORD = 4;
    const FILE_ACTION_RENAMED_NEW_NAME: windows.DWORD = 5;

    const notify_filter: windows.DWORD =
        0x00000001 | // FILE_NOTIFY_CHANGE_FILE_NAME
        0x00000002 | // FILE_NOTIFY_CHANGE_DIR_NAME
        0x00000008 | // FILE_NOTIFY_CHANGE_SIZE
        0x00000010 | // FILE_NOTIFY_CHANGE_LAST_WRITE
        0x00000040; //  FILE_NOTIFY_CHANGE_CREATION

    fn init(handler: *Handler) windows.CreateIoCompletionPortError!@This() {
        const iocp = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 1);
        return .{ .handler = handler, .iocp = iocp, .thread = null, .watches = .empty, .watches_mutex = .{} };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Wake the background thread with a shutdown key, then wait for it.
        _ = win32.PostQueuedCompletionStatus(self.iocp, 0, SHUTDOWN_KEY, null);
        if (self.thread) |t| t.join();
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            _ = win32.CloseHandle(entry.value_ptr.*.handle);
            allocator.free(entry.value_ptr.*.path);
            allocator.free(entry.value_ptr.*.buf);
        }
        self.watches.deinit(allocator);
        _ = win32.CloseHandle(self.iocp);
    }

    fn arm(self: *@This(), allocator: std.mem.Allocator) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
        _ = allocator;
        if (self.thread != null) return error.AlreadyArmed;
        self.thread = try std.Thread.spawn(.{}, thread_fn, .{ self.iocp, &self.watches, &self.watches_mutex, self.handler });
    }

    fn thread_fn(
        iocp: windows.HANDLE,
        watches: *std.StringHashMapUnmanaged(Watch),
        watches_mutex: *std.Thread.Mutex,
        handler: *Handler,
    ) void {
        var bytes: windows.DWORD = 0;
        var key: windows.ULONG_PTR = 0;
        var overlapped_ptr: ?*windows.OVERLAPPED = null;
        while (true) {
            // Block indefinitely until IOCP has a completion or shutdown signal.
            const ok = win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_ptr, windows.INFINITE);
            if (ok == 0 or key == SHUTDOWN_KEY) return;
            const triggered_handle: windows.HANDLE = @ptrFromInt(key);
            watches_mutex.lock();
            var it = watches.iterator();
            while (it.next()) |entry| {
                const w = entry.value_ptr;
                if (w.handle != triggered_handle) continue;
                if (bytes > 0) {
                    var offset: usize = 0;
                    while (offset < bytes) {
                        const info: *FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(w.buf[offset..].ptr));
                        const name_wchars = (&info.FileName).ptr[0 .. info.FileNameLength / 2];
                        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const name_len = std.unicode.utf16LeToUtf8(&name_buf, name_wchars) catch 0;
                        const event_type: EventType = switch (info.Action) {
                            FILE_ACTION_ADDED => .created,
                            FILE_ACTION_REMOVED => .deleted,
                            FILE_ACTION_MODIFIED => .modified,
                            FILE_ACTION_RENAMED_OLD_NAME, FILE_ACTION_RENAMED_NEW_NAME => .renamed,
                            else => {
                                if (info.NextEntryOffset == 0) break;
                                offset += info.NextEntryOffset;
                                continue;
                            },
                        };
                        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const full_path = std.fmt.bufPrint(&full_buf, "{s}\\{s}", .{ w.path, name_buf[0..name_len] }) catch {
                            if (info.NextEntryOffset == 0) break;
                            offset += info.NextEntryOffset;
                            continue;
                        };
                        // Distinguish files from directories.
                        const is_dir = blk: {
                            var full_path_w: [std.fs.max_path_bytes]windows.WCHAR = undefined;
                            const len = std.unicode.utf8ToUtf16Le(&full_path_w, full_path) catch break :blk false;
                            full_path_w[len] = 0;
                            const attrs = win32.GetFileAttributesW(full_path_w[0..len :0]);
                            const INVALID: windows.DWORD = 0xFFFFFFFF;
                            const FILE_ATTRIBUTE_DIRECTORY: windows.DWORD = 0x10;
                            break :blk attrs != INVALID and (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
                        };
                        const adjusted_event_type: EventType = if (is_dir and event_type == .created)
                            .dir_created
                        else if (is_dir) { // Other directory events (modified, deleted, renamed), skip.
                            if (info.NextEntryOffset == 0) break;
                            offset += info.NextEntryOffset;
                            continue;
                        } else event_type;
                        // Capture next_entry_offset before releasing the mutex: after unlock,
                        // the main thread may call remove_watch() which frees w.buf, making
                        // the `info` pointer (which points into w.buf) a dangling reference.
                        const next_entry_offset = info.NextEntryOffset;
                        watches_mutex.unlock();
                        handler.change(full_path, adjusted_event_type) catch {
                            watches_mutex.lock();
                            break;
                        };
                        watches_mutex.lock();
                        if (next_entry_offset == 0) break;
                        offset += next_entry_offset;
                    }
                }
                // Re-arm ReadDirectoryChangesW for the next batch.
                w.overlapped = std.mem.zeroes(windows.OVERLAPPED);
                _ = win32.ReadDirectoryChangesW(w.handle, w.buf.ptr, buf_size, 1, notify_filter, null, &w.overlapped, null);
                break;
            }
            watches_mutex.unlock();
        }
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, WatchFailed }!void {
        self.watches_mutex.lock();
        defer self.watches_mutex.unlock();
        if (self.watches.contains(path)) return;
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return error.WatchFailed;
        defer allocator.free(path_w);
        const handle = win32.CreateFileW(
            path_w,
            windows.GENERIC_READ,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            0x02000000 | 0x40000000, // FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.WatchFailed;
        errdefer _ = win32.CloseHandle(handle);
        _ = windows.CreateIoCompletionPort(handle, self.iocp, @intFromPtr(handle), 0) catch return error.WatchFailed;
        const buf = try allocator.alignedAlloc(u8, .fromByteUnits(4), buf_size);
        errdefer allocator.free(buf);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        if (win32.ReadDirectoryChangesW(handle, buf.ptr, buf_size, 1, notify_filter, null, &overlapped, null) == 0)
            return error.WatchFailed;
        try self.watches.put(allocator, owned_path, .{
            .handle = handle,
            .buf = buf,
            .overlapped = overlapped,
            .path = owned_path,
        });
    }

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        self.watches_mutex.lock();
        defer self.watches_mutex.unlock();
        if (self.watches.fetchRemove(path)) |entry| {
            _ = win32.CloseHandle(entry.value.handle);
            allocator.free(entry.value.path);
            allocator.free(entry.value.buf);
        }
    }
};
