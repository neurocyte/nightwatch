const std = @import("std");
const builtin = @import("builtin");

/// The kind of filesystem change that occurred.
pub const EventType = enum {
    /// A new file or directory was created.
    created,
    /// A file's contents were modified.
    modified,
    /// A file was closed.
    ///
    /// Only delivered by INotfiy (Linux) and only if the file was opened
    /// for writing.
    closed,
    /// A file or directory was deleted.
    deleted,
    /// A file or directory was renamed or moved.
    ///
    /// Delivery varies by backend:
    ///
    /// - **INotify**: all watches share a single inotify file descriptor, so
    ///   moves are paired by cookie across all watched roots. Renames between
    ///   two watched directories - even separate watch roots on the same
    ///   watcher instance - are delivered as a single atomic `rename`
    ///   callback. A move out of all watched paths appears as `deleted`; a
    ///   move in from an unwatched path appears as `created`.
    ///
    /// - **Windows**: renames within a single watched root are delivered as a
    ///   single atomic `rename` callback. However, each root uses an
    ///   independent `ReadDirectoryChangesW` handle with no shared cookie, so
    ///   a move between two separately watched roots cannot be paired: it
    ///   appears as `deleted` on the source side and `created` on the
    ///   destination side.
    ///
    /// - **kqueue / kqueuedir**: when a watched *directory* is itself
    ///   renamed, a `renamed` change event is emitted for the old directory
    ///   path (the new path is not known). Renames of *files inside* a
    ///   watched directory are detected indirectly via directory-level
    ///   `NOTE_WRITE` events and appear as `deleted` + `created`.
    ///
    /// - **FSEvents**: each path involved in a rename receives its own
    ///   `renamed` change event; the two sides are not paired.
    renamed,
};

/// Whether the affected filesystem object is a file, directory, or unknown.
pub const ObjectType = enum {
    file,
    dir,
    /// The object type could not be determined. This happens on Windows
    /// when an object is deleted and the path no longer exists to query.
    unknown,
};

/// Errors that may be returned by the public nightwatch API.
pub const Error = error{
    /// The user-supplied handler returned `error.HandlerFailed`.
    HandlerFailed,
    OutOfMemory,
    /// The watch could not be registered (e.g. path does not exist, fd
    /// limit reached, or the backend rejected the path).
    WatchFailed,
};

/// Selects how the watcher delivers events to the caller.
///
/// - `.threaded` - the backend spawns an internal thread that calls the
///   handler directly. The caller just needs to keep the `Watcher` alive.
/// - `.polling` - no internal thread is created. The caller must poll
///   `poll_fd()` for readability and call `handle_read_ready()` whenever
///   data is available. Currently only supported on Linux (inotify).
pub const InterfaceType = enum { polling, threaded };

/// Event handler interface used by threaded backends.
///
/// Implement this by embedding a `Handler` field in your context struct
/// and pointing `vtable` at a comptime-constant `VTable`:
///
/// ```zig
/// const MyHandler = struct {
///     handler: nightwatch.Handler,
///     // ... your fields ...
///
///     const vtable = nightwatch.Handler.VTable{
///         .change = changeCb,
///         .rename = renameCb,
///     };
///
///     fn changeCb(h: *nightwatch.Handler, path: []const u8,
///                 ev: nightwatch.EventType, obj: nightwatch.ObjectType)
///                 error{HandlerFailed}!void
///     {
///         const self: *MyHandler = @fieldParentPtr("handler", h);
///         _ = self; // use self...
///     }
///
///     fn renameCb(h: *nightwatch.Handler, src: []const u8, dst: []const u8,
///                 obj: nightwatch.ObjectType) error{HandlerFailed}!void
///     {
///         const self: *MyHandler = @fieldParentPtr("handler", h);
///         _ = self;
///     }
/// };
///
/// var my_handler = MyHandler{ .handler = .{ .vtable = &MyHandler.vtable }, ... };
/// var watcher = try nightwatch.Default.init(allocator, &my_handler.handler);
/// ```
pub const Handler = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called for every create / modify / delete / rename event.
        /// `path` is the absolute path of the affected object.
        /// The string is only valid for the duration of the call.
        change: *const fn (handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void,

        /// Called on INotify when a rename can be delivered as a single
        /// (src -> dst) pair. `src` and `dst` are absolute paths valid only
        /// for the duration of the call.
        rename: *const fn (handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void,
    };

    pub fn change(handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.change(handler, path, event_type, object_type);
    }

    pub fn rename(handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.rename(handler, src_path, dst_path, object_type);
    }
};

/// Event handler interface used by polling backends (Linux inotify in poll mode).
///
/// Like `Handler` but with an additional `wait_readable` callback that the
/// backend calls to yield control back to the caller's event loop while
/// waiting for the inotify fd to become readable.
///
/// Usage is identical to `Handler`; use this type only when constructing a
/// `Create(.polling)` watcher on Linux.
pub const PollingHandler = struct {
    vtable: *const VTable,

    /// Returned by `wait_readable` to describe what the backend should do next.
    pub const ReadableStatus = enum {
        /// The backend should wait for the next `handle_read_ready()` call
        /// before reading from the fd. The caller is responsible for polling.
        will_notify,
    };

    pub const VTable = struct {
        /// See `Handler.VTable.change`.
        change: *const fn (handler: *PollingHandler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void,
        /// See `Handler.VTable.rename`.
        rename: *const fn (handler: *PollingHandler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void,
        /// Called by the backend when it needs the fd to be readable before
        /// it can continue. The handler should arrange to call
        /// `handle_read_ready()` when `poll_fd()` becomes readable and return
        /// the appropriate `ReadableStatus`.
        wait_readable: *const fn (handler: *PollingHandler) error{HandlerFailed}!ReadableStatus,
    };

    pub fn change(handler: *PollingHandler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.change(handler, path, event_type, object_type);
    }

    pub fn rename(handler: *PollingHandler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.rename(handler, src_path, dst_path, object_type);
    }

    pub fn wait_readable(handler: *PollingHandler) error{HandlerFailed}!ReadableStatus {
        return handler.vtable.wait_readable(handler);
    }
};
