const std = @import("std");
const builtin = @import("builtin");
const nw = @import("nightwatch");
const main = @import("main");

// ---------------------------------------------------------------------------
// RecordedEvent
// ---------------------------------------------------------------------------

const RecordedEvent = union(enum) {
    change: struct { path: []u8, event_type: nw.EventType, object_type: nw.ObjectType },
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

// ---------------------------------------------------------------------------
// MakeTestHandler — adapts to the Handler type required by the given Watcher.
// ---------------------------------------------------------------------------

fn MakeTestHandler(comptime Watcher: type) type {
    const H = Watcher.Handler;
    return struct {
        handler: H,
        allocator: std.mem.Allocator,
        events: std.ArrayListUnmanaged(RecordedEvent),

        fn init(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{
                .handler = .{ .vtable = &vtable },
                .allocator = allocator,
                .events = .empty,
            };
            return self;
        }

        fn deinit(self: *@This()) void {
            for (self.events.items) |e| e.deinit(self.allocator);
            self.events.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        // For the polling interface the vtable requires a wait_readable entry.
        // The inner anonymous struct keeps the ReadableStatus reference inside the
        // comptime-if so it is never analyzed for threaded variants where H (= Handler)
        // has no ReadableStatus member.
        const vtable: H.VTable = if (Watcher.interface_type == .polling) .{
            .change = change_cb,
            .rename = rename_cb,
            .wait_readable = struct {
                fn f(h: *H) error{HandlerFailed}!H.ReadableStatus {
                    _ = h;
                    return .will_notify;
                }
            }.f,
        } else .{
            .change = change_cb,
            .rename = rename_cb,
        };

        fn change_cb(h: *H, path: []const u8, event_type: nw.EventType, object_type: nw.ObjectType) error{HandlerFailed}!void {
            const self: *@This() = @fieldParentPtr("handler", h);
            const owned = self.allocator.dupe(u8, path) catch return error.HandlerFailed;
            self.events.append(self.allocator, .{
                .change = .{ .path = owned, .event_type = event_type, .object_type = object_type },
            }) catch {
                self.allocator.free(owned);
                return error.HandlerFailed;
            };
        }

        fn rename_cb(h: *H, src: []const u8, dst: []const u8, _: nw.ObjectType) error{HandlerFailed}!void {
            const self: *@This() = @fieldParentPtr("handler", h);
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

        fn hasChange(self: *const @This(), path: []const u8, event_type: nw.EventType, object_type: nw.ObjectType) bool {
            return self.indexOfChange(path, event_type, object_type) != null;
        }

        fn hasRename(self: *const @This(), src: []const u8, dst: []const u8) bool {
            return self.indexOfRename(src, dst) != null;
        }

        fn indexOfChange(self: *const @This(), path: []const u8, event_type: nw.EventType, object_type: nw.ObjectType) ?usize {
            for (self.events.items, 0..) |e, i| {
                if (e == .change and
                    e.change.event_type == event_type and
                    e.change.object_type == object_type and
                    std.mem.eql(u8, e.change.path, path)) return i;
            }
            return null;
        }

        fn indexOfRename(self: *const @This(), src: []const u8, dst: []const u8) ?usize {
            for (self.events.items, 0..) |e, i| {
                if (e == .rename and
                    std.mem.eql(u8, e.rename.src, src) and
                    std.mem.eql(u8, e.rename.dst, dst)) return i;
            }
            return null;
        }

        fn indexOfAnyPath(self: *const @This(), path: []const u8) ?usize {
            for (self.events.items, 0..) |e, i| {
                const p = switch (e) {
                    .change => |c| c.path,
                    .rename => |r| r.src,
                };
                if (std.mem.eql(u8, p, path)) return i;
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------------------
// Test utilities
// ---------------------------------------------------------------------------

var temp_dir_counter = std.atomic.Value(u32).init(0);

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const n = temp_dir_counter.fetchAdd(1, .monotonic);
    const pid = switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => std.c.getpid(),
    };
    const name = if (builtin.os.tag == .windows) blk: {
        const tmp_dir = std.process.getEnvVarOwned(allocator, "TEMP") catch
            try std.process.getEnvVarOwned(allocator, "TMP");
        defer allocator.free(tmp_dir);
        break :blk try std.fmt.allocPrint(allocator, "{s}\\nightwatch_test_{d}_{d}", .{ tmp_dir, pid, n });
    } else try std.fmt.allocPrint(allocator, "/tmp/nightwatch_test_{d}_{d}", .{ pid, n });
    errdefer allocator.free(name);
    try std.fs.makeDirAbsolute(name);
    // On macOS /tmp is a symlink to /private/tmp; FSEvents always delivers
    // canonical paths, so resolve now so all test-constructed paths match.
    if (builtin.os.tag == .macos) {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = std.fs.realpath(name, &real_buf) catch return name;
        if (!std.mem.eql(u8, name, real)) {
            const canon = try allocator.dupe(u8, real);
            allocator.free(name);
            return canon;
        }
    }
    return name;
}

fn removeTempDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

/// Drive event delivery for any Watcher variant.
fn drainEvents(comptime Watcher: type, watcher: *Watcher) !void {
    if (comptime Watcher.interface_type == .polling) {
        try watcher.handle_read_ready();
    } else {
        std.Thread.sleep(300 * std.time.ns_per_ms);
    }
}

// ---------------------------------------------------------------------------
// Individual test case functions, each parametrized on the Watcher type.
// ---------------------------------------------------------------------------

fn testCreateFile(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "hello.txt" });
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }

    try drainEvents(Watcher, &watcher);
    try std.testing.expect(th.hasChange(file_path, .created, .file));
}

fn testModifyFile(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    if (comptime !Watcher.detects_file_modifications) return error.SkipZigTest;

    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "data.txt" });
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

    try drainEvents(Watcher, &watcher);
    try std.testing.expect(th.hasChange(file_path, .modified, .file));
}

fn testDeleteFile(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "gone.txt" });
    defer allocator.free(file_path);

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }
    try drainEvents(Watcher, &watcher);

    try std.fs.deleteFileAbsolute(file_path);
    try drainEvents(Watcher, &watcher);

    try std.testing.expect(th.hasChange(file_path, .deleted, .file));
}

fn testCreateSubdir(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const dir_path = try std.fs.path.join(allocator, &.{ tmp, "subdir" });
    defer allocator.free(dir_path);
    try std.fs.makeDirAbsolute(dir_path);

    try drainEvents(Watcher, &watcher);
    try std.testing.expect(th.hasChange(dir_path, .created, .dir));
}

fn testRenameFile(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "before.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "after.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.fs.renameAbsolute(src_path, dst_path);
    try drainEvents(Watcher, &watcher);

    if (builtin.os.tag == .linux) {
        try std.testing.expect(th.hasRename(src_path, dst_path));
    } else {
        const has_old = th.hasChange(src_path, .renamed, .file) or th.hasChange(src_path, .deleted, .file);
        const has_new = th.hasChange(dst_path, .renamed, .file) or th.hasChange(dst_path, .created, .file);
        try std.testing.expect(has_old or has_new);
    }
}

fn testUnwatchedDir(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

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

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(watched);

    const file_path = try std.fs.path.join(allocator, &.{ unwatched, "silent.txt" });
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }

    try drainEvents(Watcher, &watcher);
    try std.testing.expectEqual(@as(usize, 0), th.events.items.len);
}

fn testUnwatch(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const file1 = try std.fs.path.join(allocator, &.{ tmp, "watched.txt" });
    defer allocator.free(file1);
    {
        const f = try std.fs.createFileAbsolute(file1, .{});
        f.close();
    }
    try drainEvents(Watcher, &watcher);
    try std.testing.expect(th.hasChange(file1, .created, .file));

    watcher.unwatch(tmp);
    const count_before = th.events.items.len;

    const file2 = try std.fs.path.join(allocator, &.{ tmp, "after_unwatch.txt" });
    defer allocator.free(file2);
    {
        const f = try std.fs.createFileAbsolute(file2, .{});
        f.close();
    }
    try drainEvents(Watcher, &watcher);

    try std.testing.expectEqual(count_before, th.events.items.len);
}

fn testMultipleFiles(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const N = 5;
    var paths: [N][]u8 = undefined;
    for (&paths, 0..) |*p, i| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(name);
        p.* = try std.fs.path.join(allocator, &.{ tmp, name });
        const f = try std.fs.createFileAbsolute(p.*, .{});
        f.close();
    }
    defer for (paths) |p| allocator.free(p);

    try drainEvents(Watcher, &watcher);

    for (paths) |p| {
        try std.testing.expect(th.hasChange(p, .created, .file));
    }
}

fn testRenameOrder(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    // inotify pairs MOVED_FROM + MOVED_TO into a single rename event; nothing to order.
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "old.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "new.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.fs.renameAbsolute(src_path, dst_path);
    try drainEvents(Watcher, &watcher);

    const src_idx = th.indexOfAnyPath(src_path) orelse
        return error.MissingSrcEvent;
    const dst_idx = th.indexOfChange(dst_path, .renamed, .file) orelse
        th.indexOfChange(dst_path, .created, .file) orelse
        return error.MissingDstEvent;

    try std.testing.expect(src_idx < dst_idx);
}

fn testRenameThenModify(comptime Watcher: type, allocator: std.mem.Allocator) !void {
    if (comptime !Watcher.detects_file_modifications) return error.SkipZigTest;

    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(allocator);
    defer {
        removeTempDir(tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "original.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "renamed.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        f.close();
    }

    var watcher = try Watcher.init(allocator, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.fs.renameAbsolute(src_path, dst_path);
    try drainEvents(Watcher, &watcher);

    {
        const f = try std.fs.openFileAbsolute(dst_path, .{ .mode = .write_only });
        defer f.close();
        try f.writeAll("post-rename content\n");
    }
    try drainEvents(Watcher, &watcher);

    const rename_idx: usize = if (builtin.os.tag == .linux)
        th.indexOfRename(src_path, dst_path) orelse return error.MissingRenameEvent
    else
        th.indexOfAnyPath(src_path) orelse return error.MissingSrcEvent;

    const modify_idx = th.indexOfChange(dst_path, .modified, .file) orelse
        return error.MissingModifyEvent;

    try std.testing.expect(rename_idx < modify_idx);
}

// ---------------------------------------------------------------------------
// Test blocks — each runs its case across all available variants.
// ---------------------------------------------------------------------------

test "creating a file emits a 'created' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testCreateFile(nw.Create(variant), std.testing.allocator);
    }
}

test "writing to a file emits a 'modified' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testModifyFile(nw.Create(variant), std.testing.allocator);
    }
}

test "deleting a file emits a 'deleted' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testDeleteFile(nw.Create(variant), std.testing.allocator);
    }
}

test "creating a sub-directory emits a 'created' event with object_type dir" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testCreateSubdir(nw.Create(variant), std.testing.allocator);
    }
}

test "renaming a file is reported correctly per-platform" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testRenameFile(nw.Create(variant), std.testing.allocator);
    }
}

test "an unwatched directory produces no events" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testUnwatchedDir(nw.Create(variant), std.testing.allocator);
    }
}

test "unwatch stops delivering events for that directory" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testUnwatch(nw.Create(variant), std.testing.allocator);
    }
}

test "multiple files created sequentially all appear in the event list" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testMultipleFiles(nw.Create(variant), std.testing.allocator);
    }
}

test "rename: old-name event precedes new-name event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testRenameOrder(nw.Create(variant), std.testing.allocator);
    }
}

test "rename-then-modify: rename event precedes the subsequent modify event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testRenameThenModify(nw.Create(variant), std.testing.allocator);
    }
}
