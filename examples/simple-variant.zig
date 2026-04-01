//! Minimal nightwatch example: watch the current directory with an
//! explicitly selected backend variant and print every event to stderr.
//!
//! Build and run (from this directory):
//!
//!   zig build-exe --dep nightwatch -Msimple-variant=simple-variant.zig -Mnightwatch=../src/nightwatch.zig
//!   ./simple-variant

const nightwatch = @import("nightwatch");
const std = @import("std");

// Select a backend variant explicitly by passing a nightwatch.Variant value to
// nightwatch.Create(). The available variants depend on the target platform:
//
//   Linux:                .threaded (default), .polling
//   macOS (kqueue):       .kqueue (default), .kqueuedir
//   macOS (FSEvents):     .fsevents (default), .kqueue, .kqueuedir
//   FreeBSD/OpenBSD/etc.: .kqueue (default), .kqueuedir
//   Windows:              .windows
//
// Replace nightwatch.default_variant below with any variant from the list above.
const Watcher = nightwatch.Create(nightwatch.default_variant);

const H = struct {
    handler: Watcher.Handler,

    const vtable = Watcher.Handler.VTable{ .change = change, .rename = rename };

    fn change(_: *Watcher.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("{s}  {s}\n", .{ @tagName(event), path });
    }

    fn rename(_: *Watcher.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("rename  {s}  ->  {s}\n", .{ src, dst });
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var h = H{ .handler = .{ .vtable = &H.vtable } };
    var watcher = try Watcher.init(allocator, &h.handler);
    defer watcher.deinit();
    try watcher.watch(".");
    std.Thread.sleep(std.time.ns_per_s * 60);
}
