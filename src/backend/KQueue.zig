const std = @import("std");
const types = @import("../types.zig");
const Handler = types.Handler;
const EventType = types.EventType;
const ObjectType = types.ObjectType;

pub const watches_recursively = false;
pub const detects_file_modifications = true;
pub const emits_close_events = false;
pub const emits_rename_for_files = false;
pub const emits_rename_for_dirs = false;
pub const emits_subtree_created_on_movein = true;

handler: *Handler,
kq: std.posix.fd_t,
shutdown_pipe: [2]std.posix.fd_t, // [0]=read [1]=write; write a byte to wake the thread
thread: ?std.Thread,
watches: std.StringHashMapUnmanaged(std.posix.fd_t), // owned dir path -> fd
watches_mutex: std.Io.Mutex,
file_watches: std.StringHashMapUnmanaged(std.posix.fd_t), // owned file path -> fd
file_watches_mutex: std.Io.Mutex,
// Per-directory snapshots of filenames, used to diff on NOTE_WRITE.
// Key: independently owned dir path, value: set of owned filenames.
// Accessed from both the main thread (add_watch) and the background thread (scan_dir).
snapshots: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
snapshots_mutex: std.Io.Mutex,
io: std.Io,

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

pub fn init(io: std.Io, handler: *Handler) (std.posix.KQueueError || std.posix.KEventError)!@This() {
    // Per-file kqueue watches require one open fd per watched file.  Bump
    // the soft NOFILE limit to the hard limit so large directory trees don't
    // exhaust the default quota (256 on macOS, 1024 on many FreeBSD installs).
    if (std.posix.getrlimit(.NOFILE)) |rl| {
        if (rl.cur < rl.max)
            std.posix.setrlimit(.NOFILE, .{ .cur = rl.max, .max = rl.max }) catch {};
    } else |_| {}
    const kq = try std.posix.kqueue();
    errdefer std.Io.Threaded.closeFd(kq);
    const pipe = try std.Io.Threaded.pipe2(.{});
    errdefer {
        std.Io.Threaded.closeFd(pipe[0]);
        std.Io.Threaded.closeFd(pipe[1]);
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
        .watches_mutex = std.Io.Mutex.init,
        .file_watches = .empty,
        .file_watches_mutex = std.Io.Mutex.init,
        .snapshots = .empty,
        .snapshots_mutex = std.Io.Mutex.init,
        .io = io,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    // Signal the thread to exit by writing to the shutdown pipe.
    _ = std.posix.system.write(self.shutdown_pipe[1], &[_]u8{0}, 1);
    if (self.thread) |t| t.join();
    std.Io.Threaded.closeFd(self.shutdown_pipe[0]);
    std.Io.Threaded.closeFd(self.shutdown_pipe[1]);
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        std.Io.Threaded.closeFd(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    self.watches.deinit(allocator);
    var fit = self.file_watches.iterator();
    while (fit.next()) |entry| {
        std.Io.Threaded.closeFd(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    self.file_watches.deinit(allocator);
    var sit = self.snapshots.iterator();
    while (sit.next()) |entry| {
        allocator.free(entry.key_ptr.*); // independently owned; see take_snapshot/scan_dir
        var names = entry.value_ptr.*;
        var nit = names.iterator();
        while (nit.next()) |ne| allocator.free(ne.key_ptr.*);
        names.deinit(allocator);
    }
    self.snapshots.deinit(allocator);
    std.Io.Threaded.closeFd(self.kq);
}

pub fn arm(self: *@This(), allocator: std.mem.Allocator) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
    if (self.thread != null) return error.AlreadyArmed;
    self.thread = try std.Thread.spawn(.{}, thread_fn, .{ self, self.io, allocator });
}

fn thread_fn(self: *@This(), io: std.Io, allocator: std.mem.Allocator) void {
    var events: [64]std.posix.Kevent = undefined;
    while (true) {
        // Block indefinitely until kqueue has events.
        const n = std.posix.kevent(self.kq, &.{}, &events, null) catch |e| {
            std.log.err("nightwatch: kevent failed: {s}, stopping watch thread", .{@errorName(e)});
            break;
        };
        for (events[0..n]) |ev| {
            if (ev.filter == EVFILT_READ) return; // shutdown pipe readable, exit
            if (ev.filter != EVFILT_VNODE) continue;
            const fd: std.posix.fd_t = @intCast(ev.ident);

            // Check if this is a file watch: NOTE_WRITE/NOTE_EXTEND → modified.
            // Copy the path under the lock so a concurrent remove_watch cannot
            // free it before we finish using it.
            var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var file_path_len: usize = 0;
            self.file_watches_mutex.lockUncancelable(io);
            var fwit = self.file_watches.iterator();
            while (fwit.next()) |entry| {
                if (entry.value_ptr.* == fd) {
                    @memcpy(file_path_buf[0..entry.key_ptr.*.len], entry.key_ptr.*);
                    file_path_len = entry.key_ptr.*.len;
                    break;
                }
            }
            self.file_watches_mutex.unlock(io);
            if (file_path_len > 0) {
                const fp = file_path_buf[0..file_path_len];
                if (ev.fflags & (NOTE_WRITE | NOTE_EXTEND) != 0)
                    self.handler.change(fp, EventType.modified, .file) catch |e| {
                        std.log.err("nightwatch: handler returned {s}, stopping watch thread", .{@errorName(e)});
                        return;
                    };
                continue;
            }

            // Otherwise look up the directory path for this fd.
            // Same copy-under-lock pattern.
            var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var dir_path_len: usize = 0;
            self.watches_mutex.lockUncancelable(io);
            var wit = self.watches.iterator();
            while (wit.next()) |entry| {
                if (entry.value_ptr.* == fd) {
                    @memcpy(dir_path_buf[0..entry.key_ptr.*.len], entry.key_ptr.*);
                    dir_path_len = entry.key_ptr.*.len;
                    break;
                }
            }
            self.watches_mutex.unlock(io);
            if (dir_path_len == 0) continue;
            const dir_path = dir_path_buf[0..dir_path_len];
            if (ev.fflags & NOTE_DELETE != 0) {
                self.handler.change(dir_path, EventType.deleted, .dir) catch |e| {
                    std.log.err("nightwatch: handler returned {s}, stopping watch thread", .{@errorName(e)});
                    return;
                };
                // Clean up snapshot so that a new dir at the same path is not
                // skipped by scan_dir's snapshots.contains() check.
                self.remove_watch(allocator, dir_path);
            } else if (ev.fflags & NOTE_RENAME != 0) {
                self.handler.change(dir_path, EventType.deleted, .dir) catch |e| {
                    std.log.err("nightwatch: handler returned {s}, stopping watch thread", .{@errorName(e)});
                    return;
                };
                self.remove_watch(allocator, dir_path);
            } else if (ev.fflags & NOTE_WRITE != 0) {
                self.scan_dir(allocator, dir_path) catch |e|
                    std.log.err("nightwatch: scan_dir failed: {s}", .{@errorName(e)});
            }
        }
    }
}

// Scan a directory and diff against the snapshot, emitting created/deleted events.
fn scan_dir(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);

    // Arena for all temporaries - freed in one shot at the end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    // Collect current files and subdirectories (no lock, reading filesystem only).
    var current_files: std.StringHashMapUnmanaged(void) = .empty;
    var current_dirs: std.ArrayListUnmanaged([]u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(self.io)) |entry| {
        switch (entry.kind) {
            .file => {
                const name = try tmp.dupe(u8, entry.name);
                try current_files.put(tmp, name, {});
            },
            .directory => {
                const name = try tmp.dupe(u8, entry.name);
                try current_dirs.append(tmp, name);
            },
            else => {},
        }
    }

    // Diff against snapshot under the lock; collect events to emit after releasing it.
    // to_create / to_delete / new_dirs all use tmp (arena) so they are independent
    // of the snapshot and remain valid after the mutex is released.
    var to_create: std.ArrayListUnmanaged([]const u8) = .empty;
    var to_delete: std.ArrayListUnmanaged([]const u8) = .empty;
    var new_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    // to_delete items are owned (removed from snapshot) only after the fetchRemove
    // loop inside the mutex block.  Track this so the defer below only frees them
    // once ownership has actually been transferred.
    var to_delete_owned = false;
    defer if (to_delete_owned) for (to_delete.items) |name| allocator.free(name);

    // Use a boolean flag rather than errdefer to unlock the mutex.  An errdefer
    // scoped to the whole function would fire again after the explicit unlock below,
    // double-unlocking the mutex (UB) if handler.change() later returns an error.
    self.snapshots_mutex.lockUncancelable(self.io);
    var snapshots_locked = true;
    defer if (snapshots_locked) self.snapshots_mutex.unlock(self.io);
    {
        for (current_dirs.items) |name| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            if (!self.snapshots.contains(full_path)) {
                const owned = tmp.dupe(u8, full_path) catch continue;
                new_dirs.append(tmp, owned) catch continue;
            }
        }

        const gop = self.snapshots.getOrPut(allocator, dir_path) catch |e| return e;
        if (!gop.found_existing) {
            // dir_path points into a stack buffer; dupe it into allocator memory
            // so the snapshot key outlives the current thread_fn iteration.
            gop.key_ptr.* = allocator.dupe(u8, dir_path) catch |e| {
                _ = self.snapshots.remove(dir_path);
                return e;
            };
            gop.value_ptr.* = .empty;
        }
        const snapshot = gop.value_ptr;

        var cit = current_files.iterator();
        while (cit.next()) |entry| {
            if (snapshot.contains(entry.key_ptr.*)) continue;
            const owned = allocator.dupe(u8, entry.key_ptr.*) catch |e| {
                return e;
            };
            snapshot.put(allocator, owned, {}) catch |e| {
                allocator.free(owned);
                return e;
            };
            // Dupe into tmp so to_create holds arena-owned strings that remain
            // valid after the mutex is released, even if remove_watch() frees
            // the snapshot entry concurrently.
            try to_create.append(tmp, try tmp.dupe(u8, owned));
        }

        var sit = snapshot.iterator();
        while (sit.next()) |entry| {
            if (current_files.contains(entry.key_ptr.*)) continue;
            try to_delete.append(tmp, entry.key_ptr.*);
        }
        for (to_delete.items) |name| _ = snapshot.fetchRemove(name);
        to_delete_owned = true; // ownership transferred; defer will free all items
    }
    snapshots_locked = false;
    self.snapshots_mutex.unlock(self.io);

    // Emit all events outside the lock so handlers may safely call watch()/unwatch().
    // Emit created dirs, then deletions, then creations. Deletions first ensures that
    // a rename (old disappears, new appears) reports the source path before the dest.
    for (new_dirs.items) |full_path| {
        try self.handler.change(full_path, EventType.created, .dir);
        // Start watching the moved-in dir so future changes inside it are detected
        // and so its deletion fires NOTE_DELETE rather than being silently missed.
        self.add_watch(allocator, full_path) catch |e|
            std.log.err("nightwatch: add_watch on moved-in dir failed: {s}", .{@errorName(e)});
        try self.emit_subtree_created(allocator, full_path);
    }
    for (to_delete.items) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        self.deregister_file_watch(allocator, full_path);
        try self.handler.change(full_path, EventType.deleted, .file);
    }
    for (to_create.items) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        self.register_file_watch(allocator, full_path);
        try self.handler.change(full_path, EventType.created, .file);
    }
    // arena.deinit() frees current_files, current_dirs, new_dirs, and list metadata
}

// Walk dir_path recursively, emitting 'created' events and registering per-file
// vnode watches for modification tracking.  Called after a new dir appears in
// scan_dir (e.g. a directory moved into the watched tree) so callers see
// individual 'created' events for all pre-existing contents.
fn emit_subtree_created(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);
    var iter = dir.iterate();
    while (iter.next(self.io) catch return) |entry| {
        const ot: ObjectType = switch (entry.kind) {
            .file => .file,
            .directory => .dir,
            else => continue,
        };
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        try self.handler.change(full_path, EventType.created, ot);
        if (ot == .file) {
            self.register_file_watch(allocator, full_path);
        } else {
            // Watch nested subdirs so changes inside them are detected after move-in.
            self.add_watch(allocator, full_path) catch |e|
                std.log.err("nightwatch: add_watch on moved-in subdir failed: {s}", .{@errorName(e)});
            try self.emit_subtree_created(allocator, full_path);
        }
    }
}

fn register_file_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    self.file_watches_mutex.lockUncancelable(self.io);
    const already = self.file_watches.contains(path);
    self.file_watches_mutex.unlock(self.io);
    if (already) return;
    const fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return;
    const kev = std.posix.Kevent{
        .ident = @intCast(fd),
        .filter = EVFILT_VNODE,
        .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
        .fflags = NOTE_WRITE | NOTE_EXTEND,
        .data = 0,
        .udata = 0,
    };
    _ = std.posix.kevent(self.kq, &.{kev}, &.{}, null) catch {
        std.Io.Threaded.closeFd(fd);
        return;
    };
    const owned = allocator.dupe(u8, path) catch {
        std.Io.Threaded.closeFd(fd);
        return;
    };
    self.file_watches_mutex.lockUncancelable(self.io);
    if (self.file_watches.contains(path)) {
        self.file_watches_mutex.unlock(self.io);
        std.Io.Threaded.closeFd(fd);
        allocator.free(owned);
        return;
    }
    self.file_watches.put(allocator, owned, fd) catch {
        self.file_watches_mutex.unlock(self.io);
        std.Io.Threaded.closeFd(fd);
        allocator.free(owned);
        return;
    };
    self.file_watches_mutex.unlock(self.io);
}

fn deregister_file_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    self.file_watches_mutex.lockUncancelable(self.io);
    const kv = self.file_watches.fetchRemove(path);
    self.file_watches_mutex.unlock(self.io);
    if (kv) |entry| {
        std.Io.Threaded.closeFd(entry.value);
        allocator.free(entry.key);
    }
}

pub fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ WatchFailed, OutOfMemory }!void {
    self.watches_mutex.lockUncancelable(self.io);
    const already = self.watches.contains(path);
    self.watches_mutex.unlock(self.io);
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
    errdefer std.Io.Threaded.closeFd(path_fd);
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
    const owned_path = try allocator.dupe(u8, path);
    self.watches_mutex.lockUncancelable(self.io);
    if (self.watches.contains(path)) {
        self.watches_mutex.unlock(self.io);
        std.Io.Threaded.closeFd(path_fd);
        allocator.free(owned_path);
        return;
    }
    self.watches.put(allocator, owned_path, path_fd) catch |e| {
        self.watches_mutex.unlock(self.io);
        allocator.free(owned_path);
        return e;
    };
    self.watches_mutex.unlock(self.io);
    // Take initial snapshot so first NOTE_WRITE has a baseline to diff against.
    self.take_snapshot(allocator, owned_path) catch |e| switch (e) {
        error.AccessDenied,
        error.PermissionDenied,
        error.SystemResources,
        error.InvalidUtf8,
        error.Unexpected,
        => |e_| {
            std.log.err("{s} failed: {t}", .{ @src().fn_name, e_ });
            return error.WatchFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn take_snapshot(self: *@This(), allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);
    // Collect file names first so we can register file watches without holding the lock.
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var iter = dir.iterate();
    while (try iter.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    self.snapshots_mutex.lockUncancelable(self.io);
    errdefer self.snapshots_mutex.unlock(self.io);
    const gop = try self.snapshots.getOrPut(allocator, dir_path);
    if (!gop.found_existing) {
        // Snapshot outer keys are independently owned so they can be safely
        // freed in deinit/remove_watch regardless of how the entry was created.
        gop.key_ptr.* = allocator.dupe(u8, dir_path) catch |e| {
            _ = self.snapshots.remove(dir_path);
            return e;
        };
        gop.value_ptr.* = .empty;
    }
    var snapshot = gop.value_ptr;
    for (names.items) |name| {
        if (snapshot.contains(name)) continue;
        const owned = try allocator.dupe(u8, name);
        snapshot.put(allocator, owned, {}) catch |e| {
            allocator.free(owned);
            return e;
        };
    }
    self.snapshots_mutex.unlock(self.io);
    // Register a kqueue watch for each existing file so writes are detected.
    for (names.items) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        self.register_file_watch(allocator, full_path);
    }
}

pub fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    self.watches_mutex.lockUncancelable(self.io);
    const watches_entry = self.watches.fetchRemove(path);
    self.watches_mutex.unlock(self.io);
    if (watches_entry) |entry| {
        std.Io.Threaded.closeFd(entry.value);
        allocator.free(entry.key);
    }
    self.snapshots_mutex.lockUncancelable(self.io);
    const snap_entry = self.snapshots.fetchRemove(path);
    self.snapshots_mutex.unlock(self.io);
    if (snap_entry) |entry| {
        allocator.free(entry.key); // independently owned; see take_snapshot/scan_dir
        var names = entry.value;
        var it = names.iterator();
        while (it.next()) |ne| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, ne.key_ptr.* }) catch {
                allocator.free(ne.key_ptr.*);
                continue;
            };
            self.deregister_file_watch(allocator, full_path);
            allocator.free(ne.key_ptr.*);
        }
        names.deinit(allocator);
    }
}
