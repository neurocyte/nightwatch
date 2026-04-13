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
// MakeTestHandler - adapts to the Handler type required by the given Watcher.
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

fn makeTempDir(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
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
    try std.Io.Dir.createDirAbsolute(io, name, .default_dir);
    // On macOS /tmp is a symlink to /private/tmp; FSEvents always delivers
    // canonical paths, so resolve now so all test-constructed paths match.
    if (builtin.os.tag == .macos) {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.realPathFileAbsolute(io, name, &real_buf) catch return name;
        const real = real_buf[0..real_len];
        if (!std.mem.eql(u8, name, real)) {
            const canon = try allocator.dupe(u8, real);
            allocator.free(name);
            return canon;
        }
    }
    return name;
}

fn removeTempDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

/// Drive event delivery for any Watcher variant.
fn drainEvents(comptime Watcher: type, io: std.Io, watcher: *Watcher) !void {
    if (comptime Watcher.interface_type == .polling) {
        try watcher.handle_read_ready();
    } else {
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake);
    }
}

// ---------------------------------------------------------------------------
// Individual test case functions, each parametrized on the Watcher type.
// ---------------------------------------------------------------------------

fn testCreateFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "hello.txt" });
    defer allocator.free(file_path);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        f.close(io);
    }

    try drainEvents(Watcher, io, &watcher);
    try std.testing.expect(th.hasChange(file_path, .created, .file));
}

fn testModifyFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    if (comptime !Watcher.detects_file_modifications) return error.SkipZigTest;

    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "data.txt" });
    defer allocator.free(file_path);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        f.close(io);
    }

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);
    // Drain before writing: FSEvents may deliver a coalesced create+modify if the
    // file was created just before the stream started. A drain here separates any
    // stale creation event from the upcoming write, so the write arrives in its
    // own callback with only ItemModified set.
    try drainEvents(Watcher, io, &watcher);

    {
        const f = try std.Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .write_only });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello nightwatch\n");
    }

    try drainEvents(Watcher, io, &watcher);
    try std.testing.expect(th.hasChange(file_path, .modified, .file));
}

fn testCloseFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    if (comptime !Watcher.emits_close_events) return error.SkipZigTest;

    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "data.txt" });
    defer allocator.free(file_path);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        f.close(io);
    }

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    {
        const f = try std.Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .write_only });
        defer f.close(io);
        try f.writeStreamingAll(io, "hello nightwatch\n");
    }

    try drainEvents(Watcher, io, &watcher);
    try std.testing.expect(th.hasChange(file_path, .modified, .file));
    try std.testing.expect(th.hasChange(file_path, .closed, .file));
}

fn testDeleteFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const file_path = try std.fs.path.join(allocator, &.{ tmp, "gone.txt" });
    defer allocator.free(file_path);

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        f.close(io);
    }
    try drainEvents(Watcher, io, &watcher);

    try std.Io.Dir.deleteFileAbsolute(io, file_path);
    try drainEvents(Watcher, io, &watcher);

    try std.testing.expect(th.hasChange(file_path, .deleted, .file));
}

fn testCreateSubdir(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const dir_path = try std.fs.path.join(allocator, &.{ tmp, "subdir" });
    defer allocator.free(dir_path);
    try std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir);

    try drainEvents(Watcher, io, &watcher);
    try std.testing.expect(th.hasChange(dir_path, .created, .dir));
}

fn testDeleteSubdir(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const dir_path = try std.fs.path.join(allocator, &.{ tmp, "subdir" });
    defer allocator.free(dir_path);
    try std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir);

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try drainEvents(Watcher, io, &watcher);

    try std.Io.Dir.deleteDirAbsolute(io, dir_path);
    try drainEvents(Watcher, io, &watcher);

    try std.testing.expect(th.hasChange(dir_path, .deleted, .dir));
}

fn testRenameFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "before.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "after.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, src_path, .{});
        f.close(io);
    }

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.Io.Dir.renameAbsolute(src_path, dst_path, io);
    try drainEvents(Watcher, io, &watcher);

    if (comptime Watcher.emits_rename_for_files) {
        // INotify/Windows: paired atomic rename callback.
        try std.testing.expect(th.hasRename(src_path, dst_path));
    } else {
        // kqueue/FSEvents: file rename appears as deleted + created.
        try std.testing.expect(th.hasChange(src_path, .deleted, .file));
        try std.testing.expect(th.hasChange(dst_path, .created, .file));
    }
}

fn testRenameDir(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "before" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "after" });
    defer allocator.free(dst_path);

    try std.Io.Dir.createDirAbsolute(io, src_path, .default_dir);

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.Io.Dir.renameAbsolute(src_path, dst_path, io);
    try drainEvents(Watcher, io, &watcher);

    if (comptime Watcher.emits_rename_for_dirs) {
        // INotify/Windows: paired rename callback.
        try std.testing.expect(th.hasRename(src_path, dst_path));
    } else {
        // kqueue/FSEvents: old path appears as deleted.
        try std.testing.expect(th.hasChange(src_path, .deleted, .dir));
    }
}

fn testUnwatchedDir(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const watched = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, watched);
        allocator.free(watched);
    }
    const unwatched = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, unwatched);
        allocator.free(unwatched);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(watched);

    const file_path = try std.fs.path.join(allocator, &.{ unwatched, "silent.txt" });
    defer allocator.free(file_path);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        f.close(io);
    }

    try drainEvents(Watcher, io, &watcher);
    try std.testing.expectEqual(@as(usize, 0), th.events.items.len);
}

fn testUnwatch(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const file1 = try std.fs.path.join(allocator, &.{ tmp, "watched.txt" });
    defer allocator.free(file1);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        f.close(io);
    }
    try drainEvents(Watcher, io, &watcher);
    try std.testing.expect(th.hasChange(file1, .created, .file));

    watcher.unwatch(tmp) catch return error.TestUnexpectedResult;
    const count_before = th.events.items.len;

    const file2 = try std.fs.path.join(allocator, &.{ tmp, "after_unwatch.txt" });
    defer allocator.free(file2);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        f.close(io);
    }
    try drainEvents(Watcher, io, &watcher);

    try std.testing.expectEqual(count_before, th.events.items.len);
}

fn testMultipleFiles(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    const N = 5;
    var paths: [N][]u8 = undefined;
    for (&paths, 0..) |*p, i| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(name);
        p.* = try std.fs.path.join(allocator, &.{ tmp, name });
        const f = try std.Io.Dir.createFileAbsolute(io, p.*, .{});
        f.close(io);
    }
    defer for (paths) |p| allocator.free(p);

    try drainEvents(Watcher, io, &watcher);

    for (paths) |p| {
        try std.testing.expect(th.hasChange(p, .created, .file));
    }
}

fn testRenameOrder(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "old.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "new.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, src_path, .{});
        f.close(io);
    }

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.Io.Dir.renameAbsolute(src_path, dst_path, io);
    try drainEvents(Watcher, io, &watcher);

    // Backends that deliver a paired rename() callback (INotify, Windows) have
    // no two-event ordering to verify - the pair is a single atomic event.
    if (th.hasRename(src_path, dst_path)) return;

    const src_idx = th.indexOfAnyPath(src_path) orelse
        return error.MissingSrcEvent;
    const dst_idx = th.indexOfChange(dst_path, .created, .file) orelse
        return error.MissingDstEvent;

    try std.testing.expect(src_idx < dst_idx);
}

fn testRenameThenModify(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    if (comptime !Watcher.detects_file_modifications) return error.SkipZigTest;

    const TH = MakeTestHandler(Watcher);

    const tmp = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, tmp);
        allocator.free(tmp);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    const src_path = try std.fs.path.join(allocator, &.{ tmp, "original.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ tmp, "renamed.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, src_path, .{});
        f.close(io);
    }

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(tmp);

    try std.Io.Dir.renameAbsolute(src_path, dst_path, io);
    try drainEvents(Watcher, io, &watcher);

    {
        const f = try std.Io.Dir.openFileAbsolute(io, dst_path, .{ .mode = .write_only });
        defer f.close(io);
        try f.writeStreamingAll(io, "post-rename content\n");
    }
    try drainEvents(Watcher, io, &watcher);

    // Prefer the paired rename event (INotify, Windows); fall back to any
    // event touching src_path for backends that emit separate events.
    const rename_idx: usize =
        th.indexOfRename(src_path, dst_path) orelse
        th.indexOfAnyPath(src_path) orelse
        return error.MissingSrcEvent;

    const modify_idx = th.indexOfChange(dst_path, .modified, .file) orelse
        return error.MissingModifyEvent;

    try std.testing.expect(rename_idx < modify_idx);
}

fn testMoveOutFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const watched = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, watched);
        allocator.free(watched);
    }
    const other = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, other);
        allocator.free(other);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(watched);

    const src_path = try std.fs.path.join(allocator, &.{ watched, "moveme.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ other, "moveme.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, src_path, .{});
        f.close(io);
    }
    try drainEvents(Watcher, io, &watcher);

    try std.Io.Dir.renameAbsolute(src_path, dst_path, io);
    try drainEvents(Watcher, io, &watcher);

    // File moved out of the watched tree: appears as deleted on all platforms.
    try std.testing.expect(th.hasChange(src_path, .deleted, .file));
    // No event for the destination - it is in an unwatched directory.
    try std.testing.expect(!th.hasChange(dst_path, .created, .file));
}

fn testMoveInFile(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const watched = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, watched);
        allocator.free(watched);
    }
    const other = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, other);
        allocator.free(other);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(watched);

    const src_path = try std.fs.path.join(allocator, &.{ other, "moveme.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ watched, "moveme.txt" });
    defer allocator.free(dst_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, src_path, .{});
        f.close(io);
    }

    try std.Io.Dir.renameAbsolute(src_path, dst_path, io);
    try drainEvents(Watcher, io, &watcher);

    // File moved into the watched tree: appears as created.
    try std.testing.expect(th.hasChange(dst_path, .created, .file));
    // No event for the source - it was in an unwatched directory.
    try std.testing.expect(!th.hasChange(src_path, .deleted, .file));
}

fn testMoveInSubdir(comptime Watcher: type, io: std.Io, allocator: std.mem.Allocator) !void {
    const TH = MakeTestHandler(Watcher);

    const watched = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, watched);
        allocator.free(watched);
    }
    const other = try makeTempDir(io, allocator);
    defer {
        removeTempDir(io, other);
        allocator.free(other);
    }

    const th = try TH.init(allocator);
    defer th.deinit();

    var watcher = try Watcher.init(allocator, io, &th.handler);
    defer watcher.deinit();
    try watcher.watch(watched);

    const src_sub = try std.fs.path.join(allocator, &.{ other, "sub" });
    defer allocator.free(src_sub);
    const dst_sub = try std.fs.path.join(allocator, &.{ watched, "sub" });
    defer allocator.free(dst_sub);
    const src_file = try std.fs.path.join(allocator, &.{ src_sub, "f.txt" });
    defer allocator.free(src_file);
    const dst_file = try std.fs.path.join(allocator, &.{ dst_sub, "f.txt" });
    defer allocator.free(dst_file);

    // Create subdir with a file in the unwatched root, then move it in.
    try std.Io.Dir.createDirAbsolute(io, src_sub, .default_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
        f.close(io);
    }
    try std.Io.Dir.renameAbsolute(src_sub, dst_sub, io);
    try drainEvents(Watcher, io, &watcher);

    try std.testing.expect(th.hasChange(dst_sub, .created, .dir));
    if (comptime Watcher.emits_subtree_created_on_movein)
        try std.testing.expect(th.hasChange(dst_file, .created, .file));

    // Delete the file inside the moved-in subdir.
    try std.Io.Dir.deleteFileAbsolute(io, dst_file);
    try drainEvents(Watcher, io, &watcher);

    // Object type must be .file, not .unknown - backend must have seeded
    // the path_types cache when the subdir was moved in.
    try std.testing.expect(th.hasChange(dst_file, .deleted, .file));

    // Delete the now-empty subdir.
    try std.Io.Dir.deleteDirAbsolute(io, dst_sub);
    try drainEvents(Watcher, io, &watcher);

    try std.testing.expect(th.hasChange(dst_sub, .deleted, .dir));
}

// ---------------------------------------------------------------------------
// Test blocks - each runs its case across all available variants.
// ---------------------------------------------------------------------------

test "creating a file emits a 'created' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testCreateFile(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "writing to a file emits a 'modified' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        testModifyFile(nw.Create(variant), std.testing.io, std.testing.allocator) catch |e| {
            if (e != error.SkipZigTest) return e;
        };
    }
}

test "closing a file after writing emits a 'closed' event (inotify only)" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testCloseFile(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "deleting a file emits a 'deleted' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testDeleteFile(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "deleting a dir emits a 'deleted' event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testDeleteSubdir(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "creating a sub-directory emits a 'created' event with object_type dir" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testCreateSubdir(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "renaming a file is reported correctly per-platform" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testRenameFile(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "renaming a directory emits a deleted event for the old path" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testRenameDir(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "an unwatched directory produces no events" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testUnwatchedDir(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "unwatch stops delivering events for that directory" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testUnwatch(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "multiple files created sequentially all appear in the event list" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testMultipleFiles(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "rename: old-name event precedes new-name event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testRenameOrder(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "rename-then-modify: rename event precedes the subsequent modify event" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        testRenameThenModify(nw.Create(variant), std.testing.io, std.testing.allocator) catch |e| {
            if (e != error.SkipZigTest) return e;
        };
    }
}

test "moving a file out of the watched tree appears as deleted or renamed" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testMoveOutFile(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "moving a file into the watched tree appears as created" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testMoveInFile(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}

test "moving a subdir into the watched tree: contents can be deleted with correct types" {
    inline for (comptime std.enums.values(nw.Variant)) |variant| {
        try testMoveInSubdir(nw.Create(variant), std.testing.io, std.testing.allocator);
    }
}
