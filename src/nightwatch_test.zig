const std = @import("std");
const builtin = @import("builtin");
const nw = @import("nightwatch.zig");

// ---------------------------------------------------------------------------
// TestHandler - records every callback so tests can assert on them.
// ---------------------------------------------------------------------------

const RecordedEvent = union(enum) {
    change: struct { path: []u8, event_type: nw.EventType },
    rename: struct { src: []u8, dst: []u8 },

    fn deinit(self: RecordedEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .change => |c| allocator.free(c.path),
            .rename => |r| {
                allocator.free(r.src);
                allocator.free(r.dst);
            },
        }
    }
};

const TestHandler = struct {
    handler: nw.Handler,
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(RecordedEvent),

    fn init(allocator: std.mem.Allocator) !*TestHandler {
        const self = try allocator.create(TestHandler);
        self.* = .{
            .handler = .{ .vtable = &vtable },
            .allocator = allocator,
            .events = .empty,
        };
        return self;
    }

    fn deinit(self: *TestHandler) void {
        for (self.events.items) |e| e.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // -----------------------------------------------------------------------
    // vtable
    // -----------------------------------------------------------------------

    const vtable = nw.Handler.VTable{
        .change = change_cb,
        .rename = rename_cb,
        .wait_readable = if (builtin.os.tag == .linux) wait_readable_cb else {},
    };

    fn change_cb(handler: *nw.Handler, path: []const u8, event_type: nw.EventType) error{HandlerFailed}!void {
        const self: *TestHandler = @fieldParentPtr("handler", handler);
        const owned = self.allocator.dupe(u8, path) catch return error.HandlerFailed;
        self.events.append(self.allocator, .{
            .change = .{ .path = owned, .event_type = event_type },
        }) catch {
            self.allocator.free(owned);
            return error.HandlerFailed;
        };
    }

    fn rename_cb(handler: *nw.Handler, src: []const u8, dst: []const u8) error{HandlerFailed}!void {
        const self: *TestHandler = @fieldParentPtr("handler", handler);
        const owned_src = self.allocator.dupe(u8, src) catch return error.HandlerFailed;
        errdefer self.allocator.free(owned_src);
        const owned_dst = self.allocator.dupe(u8, dst) catch return error.HandlerFailed;
        self.events.append(self.allocator, .{
            .rename = .{ .src = owned_src, .dst = owned_dst },
        }) catch {
            self.allocator.free(owned_dst);
            return error.HandlerFailed;
        };
    }

    // On Linux the inotify backend calls wait_readable() inside arm() and
    // after each read-drain.  We return `will_notify` so it parks; the test
    // then calls handle_read_ready() explicitly to drive event delivery.
    fn wait_readable_cb(handler: *nw.Handler) error{HandlerFailed}!nw.ReadableStatus {
        _ = handler;
        return .will_notify;
    }

    // -----------------------------------------------------------------------
    // Query helpers
    // -----------------------------------------------------------------------

    fn hasChange(self: *const TestHandler, path: []const u8, event_type: nw.EventType) bool {
        return self.indexOfChange(path, event_type) != null;
    }

    fn hasRename(self: *const TestHandler, src: []const u8, dst: []const u8) bool {
        return self.indexOfRename(src, dst) != null;
    }

    /// Returns the list index of the first matching change event, or null.
    fn indexOfChange(self: *const TestHandler, path: []const u8, event_type: nw.EventType) ?usize {
        for (self.events.items, 0..) |e, i| {
            if (e == .change and
                e.change.event_type == event_type and
                std.mem.eql(u8, e.change.path, path)) return i;
        }
        return null;
    }

    /// Returns the list index of the first matching rename event, or null.
    fn indexOfRename(self: *const TestHandler, src: []const u8, dst: []const u8) ?usize {
        for (self.events.items, 0..) |e, i| {
            if (e == .rename and
                std.mem.eql(u8, e.rename.src, src) and
                std.mem.eql(u8, e.rename.dst, dst)) return i;
        }
        return null;
    }

    /// Returns the list index of the first event (any type) whose path equals
    /// `path`, or null.  Used for cross-platform ordering checks where we care
    /// about position but not the exact event variant.
    fn indexOfAnyPath(self: *const TestHandler, path: []const u8) ?usize {
        for (self.events.items, 0..) |e, i| {
            const p = switch (e) {
                .change => |c| c.path,
                .rename => |r| r.src, // treat src as the "from" path
            };
            if (std.mem.eql(u8, p, path)) return i;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Watcher type alias - nightwatch.zig is itself a struct type.
// ---------------------------------------------------------------------------
const Watcher = nw;

// ---------------------------------------------------------------------------
// Test utilities
// ---------------------------------------------------------------------------

var temp_dir_counter = std.atomic.Value(u32).init(0);

/// Create a fresh temporary directory and return its absolute path (caller frees).
fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const n = temp_dir_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(
        allocator,
        "/tmp/nightwatch_test_{d}_{d}",
        .{ std.os.linux.getpid(), n },
    );
    errdefer allocator.free(name);
    try std.fs.makeDirAbsolute(name);
    return name;
}

fn removeTempDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

/// Drive event delivery:
///  - Linux:   call handle_read_ready() so inotify events are processed.
///  - Others:  the backend uses its own thread/callback; sleep briefly.
fn drainEvents(watcher: *Watcher) !void {
    if (builtin.os.tag == .linux) {
        try watcher.handle_read_ready();
    } else {
        std.Thread.sleep(300 * std.time.ns_per_ms);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "creating a file emits a 'created' event" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }

    try drainEvents(&watcher);

    try std.testing.expect(th.hasChange(file_path, .created));
}

test "writing to a file emits a 'modified' event" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    // Create the file before setting up the watcher to start from a clean slate.
    const file_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    {
        const f = try std.fs.openFileAbsolute(file_path, .{ .mode = .write_only });
        defer f.close();
        try f.writeAll("hello nightwatch\n");
    }

    try drainEvents(&watcher);

    try std.testing.expect(th.hasChange(file_path, .modified));
}

test "deleting a file emits a 'deleted' event" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/gone.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.fs.deleteFileAbsolute(file_path);

    try drainEvents(&watcher);

    try std.testing.expect(th.hasChange(file_path, .deleted));
}

test "creating a sub-directory emits a 'dir_created' event" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/subdir", .{tmp});
    defer allocator.free(dir_path);
    try std.fs.makeDirAbsolute(dir_path);

    try drainEvents(&watcher);

    try std.testing.expect(th.hasChange(dir_path, .dir_created));
}

test "renaming a file is reported correctly per-platform" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    const src_path = try std.fmt.allocPrint(allocator, "{s}/before.txt", .{tmp});
    defer allocator.free(src_path);
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/after.txt", .{tmp});
    defer allocator.free(dst_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.fs.renameAbsolute(src_path, dst_path);

    try drainEvents(&watcher);

    if (builtin.os.tag == .linux) {
        // inotify pairs MOVED_FROM + MOVED_TO by cookie → single rename event.
        try std.testing.expect(th.hasRename(src_path, dst_path));
    } else {
        // macOS/Windows emit individual .renamed change events per path.
        const has_old = th.hasChange(src_path, .renamed) or th.hasChange(src_path, .deleted);
        const has_new = th.hasChange(dst_path, .renamed) or th.hasChange(dst_path, .created);
        try std.testing.expect(has_old or has_new);
    }
}

test "an unwatched directory produces no events" {
    const allocator = std.testing.allocator;

    const watched = try makeTempDir(allocator);
    defer {
        removeTempDir(watched);
        allocator.free(watched);
    }
    const unwatched = try makeTempDir(allocator);
    defer {
        removeTempDir(unwatched);
        allocator.free(unwatched);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(watched); // only watch the first dir

    const file_path = try std.fmt.allocPrint(allocator, "{s}/silent.txt", .{unwatched});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }

    try drainEvents(&watcher);

    try std.testing.expectEqual(@as(usize, 0), th.events.items.len);
}

test "unwatch stops delivering events for that directory" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    // Create a file while watching - should be reported.
    const file1 = try std.fmt.allocPrint(allocator, "{s}/watched.txt", .{tmp});
    defer allocator.free(file1);
    {
        const f = try std.fs.createFileAbsolute(file1, .{});
        f.close();
    }
    try drainEvents(&watcher);
    try std.testing.expect(th.hasChange(file1, .created));

    // Stop watching, then create another file - must NOT appear.
    watcher.unwatch(tmp);
    const count_before = th.events.items.len;

    const file2 = try std.fmt.allocPrint(allocator, "{s}/after_unwatch.txt", .{tmp});
    defer allocator.free(file2);
    {
        const f = try std.fs.createFileAbsolute(file2, .{});
        f.close();
    }
    try drainEvents(&watcher);

    try std.testing.expectEqual(count_before, th.events.items.len);
}

test "multiple files created sequentially all appear in the event list" {
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const N = 5;
    var paths: [N][]u8 = undefined;
    for (&paths, 0..) |*p, i| {
        p.* = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{ tmp, i });
        const f = try std.fs.createFileAbsolute(p.*, .{});
        f.close();
    }
    defer for (paths) |p| allocator.free(p);

    try drainEvents(&watcher);

    for (paths) |p| {
        try std.testing.expect(th.hasChange(p, .created));
    }
}

test "rename: old-name event precedes new-name event" {
    // On Linux inotify produces a single paired rename event, so there is
    // nothing to order.  On macOS/Windows two separate change events are
    // emitted; we assert the old-name (source) event arrives first.
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    const src_path = try std.fmt.allocPrint(allocator, "{s}/old.txt", .{tmp});
    defer allocator.free(src_path);
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/new.txt", .{tmp});
    defer allocator.free(dst_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.fs.renameAbsolute(src_path, dst_path);
    try drainEvents(&watcher);

    // Both paths must have produced some event.
    const src_idx = th.indexOfAnyPath(src_path) orelse
        return error.MissingSrcEvent;
    const dst_idx = th.indexOfChange(dst_path, .renamed) orelse
        th.indexOfChange(dst_path, .created) orelse
        return error.MissingDstEvent;

    // The source (old name) event must precede the destination (new name) event.
    try std.testing.expect(src_idx < dst_idx);
}

test "rename-then-modify: rename event precedes the subsequent modify event" {
    // After renaming a file, a write to the new name should produce events in
    // the order [rename/old-name, rename/new-name, modify] so that a consumer
    // always knows the current identity of the file before seeing changes to it.
    const allocator = std.testing.allocator;

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TestHandler.init(allocator);
    defer th.deinit();

    const src_path = try std.fmt.allocPrint(allocator, "{s}/original.txt", .{tmp});
    defer allocator.free(src_path);
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/renamed.txt", .{tmp});
    defer allocator.free(dst_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    // Step 1: rename.
    try std.fs.renameAbsolute(src_path, dst_path);
    try drainEvents(&watcher);

    // Step 2: modify the file under its new name.
    {
        const f = try std.fs.openFileAbsolute(dst_path, .{ .mode = .write_only });
        defer f.close();
        try f.writeAll("post-rename content\n");
    }
    try drainEvents(&watcher);

    // Locate the rename boundary: on Linux a single rename event carries both
    // paths; on other platforms we look for the first event touching src_path.
    const rename_idx: usize = if (builtin.os.tag == .linux)
        th.indexOfRename(src_path, dst_path) orelse return error.MissingRenameEvent
    else
        th.indexOfAnyPath(src_path) orelse return error.MissingSrcEvent;

    // The modify event on the new name must come strictly after the rename.
    const modify_idx = th.indexOfChange(dst_path, .modified) orelse
        return error.MissingModifyEvent;

    try std.testing.expect(rename_idx < modify_idx);
}
