const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const types = @import("types.zig");

pub const EventType = types.EventType;
pub const ObjectType = types.ObjectType;
pub const Error = types.Error;
pub const ReadableStatus = types.ReadableStatus;
pub const linux_poll_mode = types.linux_poll_mode;
pub const Handler = types.Handler;

/// True if the current backend detects file content modifications in real time.
/// False only when kqueue_dir_only=true, where directory-level watches are used
/// and file writes do not trigger a directory NOTE_WRITE event.
pub const detects_file_modifications = Backend.detects_file_modifications;

const Backend = switch (builtin.os.tag) {
    .linux => @import("backend/INotify.zig"),
    .macos => if (build_options.macos_fsevents) @import("backend/FSEvents.zig") else if (build_options.kqueue_dir_only) @import("backend/KQueueDir.zig") else @import("backend/KQueue.zig"),
    .freebsd, .openbsd, .netbsd, .dragonfly => if (build_options.kqueue_dir_only) @import("backend/KQueueDir.zig") else @import("backend/KQueue.zig"),
    .windows => @import("backend/Windows.zig"),
    else => @compileError("file_watcher: unsupported OS"),
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
    // Make the path absolute without resolving symlinks so that callers who
    // pass "/tmp/foo" (where /tmp is a symlink) receive events with the same
    // "/tmp/foo" prefix rather than the resolved "/private/tmp/foo" prefix.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path: []const u8 = if (std.fs.path.isAbsolute(path))
        path
    else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch return error.WatchFailed;
        break :blk std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, path }) catch return error.WatchFailed;
    };
    try self.interceptor.backend.add_watch(self.allocator, abs_path);
    if (!Backend.watches_recursively) {
        recurse_watch(&self.interceptor.backend, self.allocator, abs_path);
    }
}

/// Stop watching a previously watched path
pub fn unwatch(self: *@This(), path: []const u8) void {
    self.interceptor.backend.remove_watch(self.allocator, path);
}

/// Drive event delivery by reading from the inotify fd.
/// Only available in Linux poll mode (linux_poll_mode == true).
pub fn handle_read_ready(self: *@This()) !void {
    comptime if (!linux_poll_mode) @compileError("handle_read_ready is only available in Linux poll mode; use linux_read_thread=true for a background-thread model");
    try self.interceptor.backend.handle_read_ready(self.allocator);
}

/// Returns the inotify file descriptor that should be polled for POLLIN
/// before calling handle_read_ready().
/// Only available in Linux poll mode (linux_poll_mode == true).
pub fn poll_fd(self: *const @This()) std.posix.fd_t {
    comptime if (!linux_poll_mode) @compileError("poll_fd is only available in Linux poll mode; use linux_read_thread=true for a background-thread model");
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
        .wait_readable = if (linux_poll_mode) wait_readable_cb else {},
    };

    fn change_cb(h: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        const self: *Interceptor = @fieldParentPtr("handler", h);
        if (event_type == .created and object_type == .dir and !Backend.watches_recursively) {
            self.backend.add_watch(self.allocator, path) catch {};
            recurse_watch(&self.backend, self.allocator, path);
        }
        return self.user_handler.change(path, event_type, object_type);
    }

    fn rename_cb(h: *Handler, src: []const u8, dst: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        const self: *Interceptor = @fieldParentPtr("handler", h);
        return self.user_handler.rename(src, dst, object_type);
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
