//! Minimal nightwatch example: watch the current directory with the
//! platform default backend and print every event to stderr.
//!
//! Build and run (from this directory):
//!
//!   zig build-exe --dep nightwatch -Msimple-default=simple-default.zig -Mnightwatch=../src/nightwatch.zig
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var h = H{ .handler = .{ .vtable = &H.vtable } };
    var watcher = try nightwatch.Default.init(allocator, &h.handler);
    defer watcher.deinit();
    try watcher.watch(".");
    std.Thread.sleep(std.time.ns_per_s * 60);
}
