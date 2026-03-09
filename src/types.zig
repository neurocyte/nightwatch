const std = @import("std");
const builtin = @import("builtin");

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

pub const InterfaceType = enum {
    polling,
    threaded,
};

pub const Handler = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        change: *const fn (handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void,
        rename: *const fn (handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void,
    };

    pub fn change(handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.change(handler, path, event_type, object_type);
    }

    pub fn rename(handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.rename(handler, src_path, dst_path, object_type);
    }
};

/// Used only by the inotify backend in poll mode (caller drives the event
/// loop via poll_fd / handle_read_ready)
pub const PollingHandler = struct {
    vtable: *const VTable,

    pub const ReadableStatus = enum {
        // TODO: is_readable, // backend may now read from fd (blocking mode)
        will_notify, // backend must wait for a handle_read_ready call
    };

    pub const VTable = struct {
        change: *const fn (handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void,
        rename: *const fn (handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void,
        wait_readable: *const fn (handler: *Handler) error{HandlerFailed}!ReadableStatus,
    };

    pub fn change(handler: *Handler, path: []const u8, event_type: EventType, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.change(handler, path, event_type, object_type);
    }

    pub fn rename(handler: *Handler, src_path: []const u8, dst_path: []const u8, object_type: ObjectType) error{HandlerFailed}!void {
        return handler.vtable.rename(handler, src_path, dst_path, object_type);
    }

    pub fn wait_readable(handler: *Handler) error{HandlerFailed}!ReadableStatus {
        return handler.vtable.wait_readable(handler);
    }
};
