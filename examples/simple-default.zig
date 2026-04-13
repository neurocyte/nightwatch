//! Minimal nightwatch example: watch the current directory with the
//! platform default backend and print every event to stderr.
//!
//! Build and run (from this directory):
//!
//!   zig build-exe \
//!     --dep nightwatch -Msimple-default=simple-default.zig \
//!     --dep build_options -Mnightwatch=../src/nightwatch.zig \
//!     -Mbuild_options=build_options.zig
//!   ./simple-default

const nightwatch = @import("nightwatch");
const std = @import("std");

const H = struct {
    handler: nightwatch.Default.Handler,

    const vtable = nightwatch.Default.Handler.VTable{ .change = change, .rename = rename };

    fn change(_: *nightwatch.Default.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("{s}  {s}\n", .{ @tagName(event), path });
    }

    fn rename(_: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("rename  {s}  ->  {s}\n", .{ src, dst });
    }
};

pub fn main(init: std.process.Init) !void {
    var h = H{ .handler = .{ .vtable = &H.vtable } };
    var watcher = try nightwatch.Default.init(init.io, init.gpa, &h.handler);
    defer watcher.deinit();
    try watcher.watch(".");
    std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(60_000), .awake) catch {};
}
