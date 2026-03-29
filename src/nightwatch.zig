const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const types = @import("types.zig");

pub const EventType = types.EventType;
pub const ObjectType = types.ObjectType;
pub const Error = types.Error;
pub const InterfaceType = types.InterfaceType;

/// The set of backend variants available on the current platform.
///
/// On Linux this is `InterfaceType` (`.polling` or `.threaded`), since the
/// only backend is inotify and the choice is how events are delivered.
/// On macOS, BSD, and Windows the variants select the OS-level mechanism.
/// Pass a value to `Create()` to get a watcher type for that variant.
///
/// On macOS the `.fsevents` variant is only present when the `macos_fsevents`
/// build option is enabled. To enable it when using nightwatch as a dependency,
/// pass the option in your `build.zig`:
///
/// ```zig
/// const nightwatch_dep = b.dependency("nightwatch", .{
///     .macos_fsevents = true,
/// });
/// exe.root_module.addImport("nightwatch", nightwatch_dep.module("nightwatch"));
/// ```
pub const Variant = switch (builtin.os.tag) {
    .linux => InterfaceType,
    .macos => if (build_options.macos_fsevents) enum { fsevents, kqueue, kqueuedir } else enum { kqueue, kqueuedir },
    .freebsd, .openbsd, .netbsd, .dragonfly => enum { kqueue, kqueuedir },
    .windows => enum { windows },
    else => @compileError("unsupported OS"),
};

/// The recommended variant for the current platform. `Default` is a
/// shorthand for `Create(default_variant)`.
pub const default_variant: Variant = switch (builtin.os.tag) {
    .linux => .threaded,
    .macos => if (build_options.macos_fsevents) .fsevents else .kqueue,
    .freebsd, .openbsd, .netbsd, .dragonfly => .kqueue,
    .windows => .windows,
    else => @compileError("unsupported OS"),
};

/// A ready-to-use watcher type using the recommended backend for the current
/// platform. Equivalent to `Create(default_variant)`.
pub const Default: type = Create(default_variant);

/// Returns a `Watcher` type parameterized on the given backend variant.
///
/// Typical usage:
/// ```zig
/// const Watcher = nightwatch.Default; // or nightwatch.Create(.kqueue), etc.
/// var watcher = try Watcher.init(allocator, &my_handler.handler);
/// defer watcher.deinit();
/// try watcher.watch("/path/to/dir");
/// ```
///
/// To iterate all available variants at comptime (e.g. in tests):
/// ```zig
/// inline for (comptime std.enums.values(nightwatch.Variant)) |v| {
///     const W = nightwatch.Create(v);
///     // ...
/// }
/// ```
pub fn Create(comptime variant: Variant) type {
    return struct {
        pub const Backend = switch (builtin.os.tag) {
            .linux => @import("backend/INotify.zig").Create(variant),
            .macos => if (build_options.macos_fsevents) switch (variant) {
                .fsevents => @import("backend/FSEvents.zig"),
                .kqueue => @import("backend/KQueue.zig"),
                .kqueuedir => @import("backend/KQueueDir.zig"),
            } else switch (variant) {
                .kqueue => @import("backend/KQueue.zig"),
                .kqueuedir => @import("backend/KQueueDir.zig"),
            },
            .freebsd, .openbsd, .netbsd, .dragonfly => switch (variant) {
                .kqueue => @import("backend/KQueue.zig"),
                .kqueuedir => @import("backend/KQueueDir.zig"),
            },
            .windows => switch (variant) {
                .windows => @import("backend/Windows.zig"),
            },
            else => @compileError("unsupported OS"),
        };
        /// Whether this watcher variant uses a background thread or requires
        /// the caller to drive the event loop. See `InterfaceType`.
        pub const interface_type: InterfaceType = switch (builtin.os.tag) {
            .linux => variant,
            else => .threaded,
        };
        /// The handler type expected by `init`. `Handler` for threaded
        /// variants, `PollingHandler` for the polling variant.
        pub const Handler = switch (interface_type) {
            .threaded => types.Handler,
            .polling => types.PollingHandler,
        };
        pub const InterceptorType = switch (interface_type) {
            .threaded => Interceptor,
            .polling => PollingInterceptor,
        };

        allocator: std.mem.Allocator,
        interceptor: *InterceptorType,

        /// Whether this backend detects file content modifications in real time.
        ///
        /// `false` only for the `kqueuedir` variant, which uses directory-level
        /// kqueue watches. Because directory `NOTE_WRITE` events are not
        /// triggered by writes to files inside the directory, file modifications
        /// are not detected for unwatched files. Files added explicitly via
        /// `watch()` do receive per-file `NOTE_WRITE` events and will report
        /// modifications.
        pub const detects_file_modifications = Backend.detects_file_modifications;
        pub const emits_close_events = Backend.emits_close_events;

        /// Create a new watcher.
        ///
        /// `handler` must remain valid for the lifetime of the watcher. For
        /// threaded variants the backend's internal thread will call into it
        /// concurrently; for the polling variant calls happen synchronously
        /// inside `handle_read_ready()`.
        pub fn init(allocator: std.mem.Allocator, handler: *Handler) !@This() {
            const ic = try allocator.create(InterceptorType);
            errdefer allocator.destroy(ic);
            ic.* = .{
                .handler = .{ .vtable = &InterceptorType.vtable },
                .user_handler = handler,
                .allocator = allocator,
                .backend = undefined,
            };
            ic.backend = try Backend.init(&ic.handler);
            errdefer ic.backend.deinit(allocator);
            try ic.backend.arm(allocator);
            return .{ .allocator = allocator, .interceptor = ic };
        }

        /// Stop the watcher, release all watches, and free resources.
        /// For threaded variants this joins the background thread.
        pub fn deinit(self: *@This()) void {
            self.interceptor.backend.deinit(self.allocator);
            self.allocator.destroy(self.interceptor);
        }

        /// Watch a path for changes.
        ///
        /// `path` may be a file or a directory. Relative paths are resolved
        /// against the current working directory at the time of the call.
        /// Events are always delivered with absolute paths.
        ///
        /// When `path` is a directory, all existing subdirectories are watched
        /// recursively and any newly created subdirectory is automatically
        /// added to the watch set.
        ///
        /// The handler's `change` callback is called for every event. On
        /// Linux (inotify), renames that can be paired atomically are delivered
        /// via the `rename` callback instead; on all other platforms a rename
        /// appears as a `deleted` event followed by a `created` event.
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
                break :blk std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ cwd, std.fs.path.sep, path }) catch return error.WatchFailed;
            };
            // Collapse any . and .. segments without touching the filesystem so that
            // relative inputs like "../sibling" or "./sub" produce the same watch key
            // and event-path prefix as an equivalent absolute path would.
            const norm = try std.fs.path.resolve(self.allocator, &.{abs_path});
            defer self.allocator.free(norm);
            try self.interceptor.backend.add_watch(self.allocator, norm);
            if (!Backend.watches_recursively) {
                recurse_watch(&self.interceptor.backend, self.allocator, norm);
            }
        }

        const UnwatchReturnType = @typeInfo(@TypeOf(Backend.remove_watch)).@"fn".return_type orelse void;
        pub const UnwatchError = switch (@typeInfo(UnwatchReturnType)) {
            .error_union => |info| info.error_set,
            .void => error{},
            else => @compileError("invalid remove_watch return type: " ++ @typeName(UnwatchReturnType)),
        };

        /// Stop watching a previously watched path. Has no effect if `path`
        /// was never watched. Does not unwatch subdirectories that were
        /// added automatically as a result of watching `path`.
        pub fn unwatch(self: *@This(), path: []const u8) UnwatchError!void {
            // Normalize path the same way watch() does so that relative or
            // dot-containing paths resolve to the same key that was stored.
            const norm = std.fs.path.resolve(self.allocator, &.{path}) catch {
                return; // OOM: treat as no-op; path was never watched under the resolved form
            };
            defer self.allocator.free(norm);
            return self.interceptor.backend.remove_watch(self.allocator, norm);
        }

        /// Read pending events from the backend fd and deliver them to the handler.
        ///
        /// Only available for the `.polling` variant (Linux inotify). Call this
        /// whenever `poll_fd()` is readable.
        pub fn handle_read_ready(self: *@This()) !void {
            comptime if (!(@hasDecl(Backend, "polling") and Backend.polling)) @compileError("handle_read_ready is only available in polling backends");
            try self.interceptor.backend.handle_read_ready(self.allocator);
        }

        /// Returns the file descriptor to poll for `POLLIN` before calling
        /// `handle_read_ready()`.
        ///
        /// Only available for the `.polling` variant (Linux inotify).
        pub fn poll_fd(self: *const @This()) std.posix.fd_t {
            comptime if (!(@hasDecl(Backend, "polling") and Backend.polling)) @compileError("poll_fd is only available in polling backends");
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
            };

            fn change_cb(h: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
                const self: *Interceptor = @fieldParentPtr("handler", h);
                if (event_type == .created and object_type == .dir and !Backend.watches_recursively) {
                    self.backend.add_watch(self.allocator, path) catch |e|
                        std.log.err("nightwatch: add_watch failed for {s}: {s}", .{ path, @errorName(e) });
                    recurse_watch(&self.backend, self.allocator, path);
                }
                return self.user_handler.change(path, event_type, object_type);
            }

            fn rename_cb(h: *Handler, src: []const u8, dst: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
                const self: *Interceptor = @fieldParentPtr("handler", h);
                return self.user_handler.rename(src, dst, object_type);
            }
        };

        const PollingInterceptor = struct {
            handler: PollingHandler,
            user_handler: *PollingHandler,
            allocator: std.mem.Allocator,
            backend: Backend,

            const vtable = PollingHandler.VTable{
                .change = change_cb,
                .rename = rename_cb,
                .wait_readable = wait_readable_cb,
            };

            const PollingHandler = types.PollingHandler;

            fn change_cb(h: *PollingHandler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
                const self: *PollingInterceptor = @fieldParentPtr("handler", h);
                if (event_type == .created and object_type == .dir and !Backend.watches_recursively) {
                    self.backend.add_watch(self.allocator, path) catch |e|
                        std.log.err("nightwatch: add_watch failed for {s}: {s}", .{ path, @errorName(e) });
                    recurse_watch(&self.backend, self.allocator, path);
                }
                return self.user_handler.change(path, event_type, object_type);
            }

            fn rename_cb(h: *PollingHandler, src: []const u8, dst: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
                const self: *PollingInterceptor = @fieldParentPtr("handler", h);
                return self.user_handler.rename(src, dst, object_type);
            }

            fn wait_readable_cb(h: *PollingHandler) error{HandlerFailed}!PollingHandler.ReadableStatus {
                const self: *PollingInterceptor = @fieldParentPtr("handler", h);
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
                const sub = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, entry.name }) catch continue;
                backend.add_watch(allocator, sub) catch |e|
                    std.log.err("nightwatch: add_watch failed for {s}: {s}", .{ sub, @errorName(e) });
                recurse_watch(backend, allocator, sub);
            }
        }
    };
}
