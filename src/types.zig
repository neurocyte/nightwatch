const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const EventType = enum {
    created,
    modified,
    deleted,
    /// Only produced on macOS and Windows where the OS gives no pairing info.
    /// On Linux, paired renames are emitted as a rename event with both paths instead.
    renamed,
};

pub const ObjectType = enum {
    file,
    dir,
    /// The object type could not be determined (e.g. a deleted file on Windows
    /// where the path no longer exists to query).
    unknown,
};

pub const Error = error{
    HandlerFailed,
    OutOfMemory,
    WatchFailed,
};

/// True when the Linux inotify backend runs in poll mode (caller drives the
/// event loop via poll_fd / handle_read_ready).  False on all other platforms
/// and on Linux when the `linux_read_thread` build option is set.
pub const linux_poll_mode = builtin.os.tag == .linux and !build_options.linux_read_thread;

pub const ReadableStatus = enum {
    // TODO: is_readable, // backend may now read from fd (blocking mode)
    will_notify, // backend must wait for a handle_read_ready call
};

pub const Handler = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        change: *const fn (handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void,
        rename: *const fn (handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void,
        /// Only present in Linux poll mode (linux_poll_mode == true).
        wait_readable: if (linux_poll_mode) *const fn (handler: *Handler) error{HandlerFailed}!ReadableStatus else void,
    };

    pub fn change(handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.change(handler, path, event_type, object_type);
    }

    pub fn rename(handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.rename(handler, src_path, dst_path, object_type);
    }

    pub fn wait_readable(handler: *Handler) error{HandlerFailed}!ReadableStatus {
        if (comptime linux_poll_mode) {
            return handler.vtable.wait_readable(handler);
        } else {
            unreachable;
        }
    }
};
