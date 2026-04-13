//! Minimal nightwatch example: watch the current directory with the Linux
//! inotify polling backend and print every event to stderr.
//!
//! Build and run (from this directory):
//!
//!   zig build-exe \
//!     --dep nightwatch -Msimple-polling=simple-polling.zig \
//!     --dep build_options -Mnightwatch=../src/nightwatch.zig \
//!     -Mbuild_options=build_options.zig
//!   ./simple-polling

const nightwatch = @import("nightwatch");
const std = @import("std");

// The .polling variant is Linux-only (inotify). Unlike the threaded backends,
// it does not spawn an internal thread; instead the caller drives event
// delivery by polling poll_fd() for readability and calling handle_read_ready()
// whenever data is available. The handler vtable requires an extra
// wait_readable callback that the backend calls to notify the handler that it
// should re-arm the fd in its polling loop before the next handle_read_ready().
const Watcher = nightwatch.Create(.polling);

const H = struct {
    handler: Watcher.Handler,

    const vtable = Watcher.Handler.VTable{ .change = change, .rename = rename, .wait_readable = wait_readable };

    fn change(_: *Watcher.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("{s}  {s}\n", .{ @tagName(event), path });
    }

    fn rename(_: *Watcher.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("rename  {s}  ->  {s}\n", .{ src, dst });
    }

    // Called by the backend at arm time and after each handle_read_ready().
    // Return .will_notify (currently the only option) to signal that the
    // caller's loop will drive delivery.
    fn wait_readable(_: *Watcher.Handler) error{HandlerFailed}!Watcher.Handler.ReadableStatus {
        return .will_notify;
    }
};

pub fn main(init: std.process.Init) !void {
    var h = H{ .handler = .{ .vtable = &H.vtable } };
    var watcher = try Watcher.init(init.io, init.gpa, &h.handler);
    defer watcher.deinit();
    try watcher.watch(".");

    var pfd = [_]std.posix.pollfd{.{ .fd = watcher.poll_fd(), .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        _ = try std.posix.poll(&pfd, -1);
        try watcher.handle_read_ready();
    }
}
