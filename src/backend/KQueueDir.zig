const std = @import("std");
const types = @import("../types.zig");
const Handler = types.Handler;
const EventType = types.EventType;
const ObjectType = types.ObjectType;

pub const watches_recursively = false;
pub const detects_file_modifications = false;
pub const WatchEntry = struct { fd: std.posix.fd_t, is_file: bool };

handler: *Handler,
kq: std.posix.fd_t,
shutdown_pipe: [2]std.posix.fd_t, // [0]=read [1]=write; write a byte to wake the thread
thread: ?std.Thread,
watches: std.StringHashMapUnmanaged(WatchEntry), // owned path -> {fd, is_file}
watches_mutex: std.Thread.Mutex,
// Per-directory snapshots: owned filename -> mtime_ns.
// Used to diff on NOTE_WRITE: detects creates, deletes, and (opportunistically)
// modifications when the same directory fires another event later.
// Key: owned dir path (same as watches key), value: map of owned filename -> mtime_ns.
snapshots: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(i128)),
snapshots_mutex: std.Thread.Mutex,

const EVFILT_VNODE: i16 = -4;
const EVFILT_READ: i16 = -1;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const EV_CLEAR: u16 = 0x0020;
const EV_DELETE: u16 = 0x0002;
const NOTE_DELETE: u32 = 0x00000001;
const NOTE_WRITE: u32 = 0x00000002;
const NOTE_EXTEND: u32 = 0x00000004;
const NOTE_ATTRIB: u32 = 0x00000008;
const NOTE_RENAME: u32 = 0x00000020;

pub fn init(handler: *Handler) (std.posix.KQueueError || std.posix.KEventError)!@This() {
    const kq = try std.posix.kqueue();
    errdefer std.posix.close(kq);
    const pipe = try std.posix.pipe();
    errdefer {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }
    // Register the read end of the shutdown pipe with kqueue so the thread
    // wakes up when we want to shut down.
    const shutdown_kev = std.posix.Kevent{
        .ident = @intCast(pipe[0]),
        .filter = EVFILT_READ,
        .flags = EV_ADD | EV_ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = try std.posix.kevent(kq, &.{shutdown_kev}, &.{}, null);
    return .{
        .handler = handler,
        .kq = kq,
        .shutdown_pipe = pipe,
        .thread = null,
        .watches = .empty,
        .watches_mutex = .{},
        .snapshots = .empty,
        .snapshots_mutex = .{},
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    // Signal the thread to exit by writing to the shutdown pipe.
    _ = std.posix.write(self.shutdown_pipe[1], &[_]u8{0}) catch {};
    if (self.thread) |t| t.join();
    std.posix.close(self.shutdown_pipe[0]);
    std.posix.close(self.shutdown_pipe[1]);
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        std.posix.close(entry.value_ptr.*.fd);
        allocator.free(entry.key_ptr.*);
    }
    self.watches.deinit(allocator);
    var sit = self.snapshots.iterator();
    while (sit.next()) |entry| {
        // Keys are borrowed from self.watches and freed in the watches loop above.
        var snap = entry.value_ptr.*;
        var nit = snap.iterator();
        while (nit.next()) |ne| allocator.free(ne.key_ptr.*);
        snap.deinit(allocator);
    }
    self.snapshots.deinit(allocator);
    std.posix.close(self.kq);
}

pub fn arm(self: *@This(), allocator: std.mem.Allocator) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
    if (self.thread != null) return error.AlreadyArmed;
    self.thread = try std.Thread.spawn(.{}, thread_fn, .{ self, allocator });
}

fn thread_fn(self: *@This(), allocator: std.mem.Allocator) void {
    var events: [64]std.posix.Kevent = undefined;
    while (true) {
        // Block indefinitely until kqueue has events.
        const n = std.posix.kevent(self.kq, &.{}, &events, null) catch break;
        for (events[0..n]) |ev| {
            if (ev.filter == EVFILT_READ) return; // shutdown pipe readable, exit
            if (ev.filter != EVFILT_VNODE) continue;
            const fd: std.posix.fd_t = @intCast(ev.ident);

            self.watches_mutex.lock();
            var wit = self.watches.iterator();
            var watch_path: ?[]const u8 = null;
            var is_file: bool = false;
            while (wit.next()) |entry| {
                if (entry.value_ptr.*.fd == fd) {
                    watch_path = entry.key_ptr.*;
                    is_file = entry.value_ptr.*.is_file;
                    break;
                }
            }
            self.watches_mutex.unlock();
            if (watch_path == null) continue;
            if (is_file) {
                // Explicit file watch: emit events with .file type directly.
                if (ev.fflags & NOTE_DELETE != 0) {
                    self.handler.change(watch_path.?, EventType.deleted, .file) catch return;
                } else if (ev.fflags & NOTE_RENAME != 0) {
                    self.handler.change(watch_path.?, EventType.renamed, .file) catch return;
                } else if (ev.fflags & (NOTE_WRITE | NOTE_EXTEND) != 0) {
                    self.handler.change(watch_path.?, EventType.modified, .file) catch return;
                }
            } else {
                if (ev.fflags & NOTE_DELETE != 0) {
                    self.handler.change(watch_path.?, EventType.deleted, .dir) catch return;
                } else if (ev.fflags & NOTE_RENAME != 0) {
                    self.handler.change(watch_path.?, EventType.renamed, .dir) catch return;
                } else if (ev.fflags & NOTE_WRITE != 0) {
                    self.scan_dir(allocator, watch_path.?) catch {};
                }
            }
        }
    }
}

// Scan a directory and diff against the snapshot, emitting created/deleted/modified events.
// File modifications are detected opportunistically via mtime changes: if a file was
// written before a NOTE_WRITE fires for another reason (create/delete/rename of a sibling),
// the mtime diff will catch it.
fn scan_dir(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Arena for all temporaries — freed in one shot at the end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    // Collect current files (name → mtime_ns) and subdirectories.
    // No lock held while doing filesystem I/O.
    var current_files: std.StringHashMapUnmanaged(i128) = .empty;
    var current_dirs: std.ArrayListUnmanaged([]u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const mtime = (dir.statFile(entry.name) catch continue).mtime;
                const name = try tmp.dupe(u8, entry.name);
                try current_files.put(tmp, name, mtime);
            },
            .directory => {
                const name = try tmp.dupe(u8, entry.name);
                try current_dirs.append(tmp, name);
            },
            else => {},
        }
    }

    // Diff against snapshot under the lock; collect events to emit after releasing it.
    // to_create / to_delete / to_modify borrow pointers from the snapshot (allocator),
    // only list metadata uses tmp.
    var to_create: std.ArrayListUnmanaged([]const u8) = .empty;
    var to_delete: std.ArrayListUnmanaged([]const u8) = .empty;
    var to_modify: std.ArrayListUnmanaged([]const u8) = .empty;
    var new_dirs: std.ArrayListUnmanaged([]const u8) = .empty;

    self.snapshots_mutex.lock();
    errdefer self.snapshots_mutex.unlock();
    {
        for (current_dirs.items) |name| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            if (!self.snapshots.contains(full_path)) {
                const owned = tmp.dupe(u8, full_path) catch continue;
                new_dirs.append(tmp, owned) catch continue;
            }
        }

        const gop = self.snapshots.getOrPut(allocator, dir_path) catch |e| {
            return e;
        };
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const snapshot = gop.value_ptr;

        var cit = current_files.iterator();
        while (cit.next()) |entry| {
            if (snapshot.getPtr(entry.key_ptr.*)) |stored_mtime| {
                // File exists in both — check for modification via mtime change.
                if (stored_mtime.* != entry.value_ptr.*) {
                    stored_mtime.* = entry.value_ptr.*;
                    try to_modify.append(tmp, entry.key_ptr.*); // borrow from current (tmp)
                }
            } else {
                // New file — add to snapshot and to_create list.
                const owned = allocator.dupe(u8, entry.key_ptr.*) catch |e| {
                    return e;
                };
                snapshot.put(allocator, owned, entry.value_ptr.*) catch |e| {
                    allocator.free(owned);
                    return e;
                };
                try to_create.append(tmp, owned); // borrow from snapshot
            }
        }

        var sit = snapshot.iterator();
        while (sit.next()) |entry| {
            if (current_files.contains(entry.key_ptr.*)) continue;
            try to_delete.append(tmp, entry.key_ptr.*); // borrow from snapshot
        }
        for (to_delete.items) |name| _ = snapshot.fetchRemove(name);
    }
    self.snapshots_mutex.unlock();

    // Emit all events outside the lock so handlers may safely call watch()/unwatch().
    // Order: new dirs, deletions (source before dest for renames), creations, modifications.
    for (new_dirs.items) |full_path|
        try self.handler.change(full_path, EventType.created, .dir);
    for (to_delete.items) |name| {
        defer allocator.free(name); // snapshot key, owned by allocator
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        try self.handler.change(full_path, EventType.deleted, .file);
    }
    for (to_create.items) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        try self.handler.change(full_path, EventType.created, .file);
    }
    for (to_modify.items) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        try self.handler.change(full_path, EventType.modified, .file);
    }
    // arena.deinit() frees current_files, current_dirs, new_dirs, and list metadata
}

pub fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ WatchFailed, OutOfMemory }!void {
    self.watches_mutex.lock();
    const already = self.watches.contains(path);
    self.watches_mutex.unlock();
    if (already) return;
    const path_fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch |e| switch (e) {
        error.AccessDenied,
        error.PermissionDenied,
        error.PathAlreadyExists,
        error.SymLinkLoop,
        error.NameTooLong,
        error.FileNotFound,
        error.SystemResources,
        error.NoSpaceLeft,
        error.NotDir,
        error.InvalidUtf8,
        error.InvalidWtf8,
        error.BadPathName,
        error.NoDevice,
        error.NetworkNotFound,
        error.Unexpected,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ProcessNotFound,
        error.FileTooBig,
        error.IsDir,
        error.DeviceBusy,
        error.FileLocksNotSupported,
        error.FileBusy,
        error.WouldBlock,
        => |e_| {
            std.log.err("{s} failed: {t}", .{ @src().fn_name, e_ });
            return error.WatchFailed;
        },
    };
    errdefer std.posix.close(path_fd);
    const kev = std.posix.Kevent{
        .ident = @intCast(path_fd),
        .filter = EVFILT_VNODE,
        .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
        .fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND,
        .data = 0,
        .udata = 0,
    };
    _ = std.posix.kevent(self.kq, &.{kev}, &.{}, null) catch |e| switch (e) {
        error.AccessDenied,
        error.SystemResources,
        error.EventNotFound,
        error.ProcessNotFound,
        error.Overflow,
        => |e_| {
            std.log.err("{s} failed: {t}", .{ @src().fn_name, e_ });
            return error.WatchFailed;
        },
    };
    // Determine if the path is a regular file or a directory.
    const stat = std.posix.fstat(path_fd) catch null;
    const is_file = if (stat) |s| std.posix.S.ISREG(s.mode) else false;
    const owned_path = try allocator.dupe(u8, path);
    self.watches_mutex.lock();
    if (self.watches.contains(path)) {
        self.watches_mutex.unlock();
        std.posix.close(path_fd);
        allocator.free(owned_path);
        return;
    }
    self.watches.put(allocator, owned_path, .{ .fd = path_fd, .is_file = is_file }) catch |e| {
        self.watches_mutex.unlock();
        allocator.free(owned_path);
        return e;
    };
    self.watches_mutex.unlock();
    // For directory watches only: take initial snapshot so first NOTE_WRITE has a baseline.
    if (!is_file) {
        self.take_snapshot(allocator, owned_path) catch return error.OutOfMemory;
    }
}

fn take_snapshot(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    self.snapshots_mutex.lock();
    errdefer self.snapshots_mutex.unlock();
    const gop = try self.snapshots.getOrPut(allocator, dir_path);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    const snapshot = gop.value_ptr;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (snapshot.contains(entry.name)) continue;
        const mtime = (dir.statFile(entry.name) catch continue).mtime;
        const owned = allocator.dupe(u8, entry.name) catch continue;
        snapshot.put(allocator, owned, mtime) catch allocator.free(owned);
    }
    self.snapshots_mutex.unlock();
}

pub fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    self.watches_mutex.lock();
    const watches_entry = self.watches.fetchRemove(path);
    self.watches_mutex.unlock();
    if (watches_entry) |entry| {
        std.posix.close(entry.value.fd);
        allocator.free(entry.key);
    }
    self.snapshots_mutex.lock();
    const snap_entry = self.snapshots.fetchRemove(path);
    self.snapshots_mutex.unlock();
    if (snap_entry) |entry| {
        var snap = entry.value;
        var it = snap.iterator();
        while (it.next()) |ne| allocator.free(ne.key_ptr.*);
        snap.deinit(allocator);
    }
}
