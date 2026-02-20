const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const builtin = @import("builtin");

pid: tp.pid_ref,

const Self = @This();
const module_name = @typeName(Self);

pub const EventType = enum {
    created,
    modified,
    deleted,
    renamed,
};

pub const Error = FileWatcherError;
pub const FileWatcherError = error{ FileWatcherFailed, ThespianSpawnFailed, OutOfMemory };
const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

/// Watch a path (file or directory) for changes. The caller will receive:
///   .{ "FW", "change", path, event_type }
/// where event_type is a file_watcher.EventType tag string: "created", "modified", "deleted", "renamed"
pub fn watch(path: []const u8) FileWatcherError!void {
    return send(.{ "watch", path });
}

/// Stop watching a previously watched path.
pub fn unwatch(path: []const u8) FileWatcherError!void {
    return send(.{ "unwatch", path });
}

pub fn start() SpawnError!void {
    _ = try get();
}

pub fn shutdown() void {
    const pid = tp.env.get().proc(module_name);
    if (pid.expired()) return;
    pid.send(.{"shutdown"}) catch {};
}

fn get() SpawnError!Self {
    const pid = tp.env.get().proc(module_name);
    return if (pid.expired()) create() else .{ .pid = pid };
}

fn send(message: anytype) FileWatcherError!void {
    return (try get()).pid.send(message) catch error.FileWatcherFailed;
}

fn create() SpawnError!Self {
    const pid = try Process.create();
    defer pid.deinit();
    tp.env.get().proc_set(module_name, pid.ref());
    return .{ .pid = tp.env.get().proc(module_name) };
}

const Backend = switch (builtin.os.tag) {
    .linux => LinuxBackend,
    .macos => MacosBackend,
    .windows => WindowsBackend,
    else => @compileError("file_watcher: unsupported OS"),
};

const LinuxBackend = struct {
    inotify_fd: std.posix.fd_t,
    fd_watcher: tp.file_descriptor,
    watches: std.AutoHashMapUnmanaged(i32, []u8), // wd -> owned path

    const IN = std.os.linux.IN;

    const watch_mask: u32 = IN.CREATE | IN.DELETE | IN.MODIFY |
        IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF |
        IN.MOVE_SELF | IN.CLOSE_WRITE;

    const in_flags: std.os.linux.O = .{ .NONBLOCK = true };

    fn init() !LinuxBackend {
        const ifd = std.posix.inotify_init1(@bitCast(in_flags)) catch return error.FileWatcherFailed;
        errdefer std.posix.close(ifd);
        const fwd = tp.file_descriptor.init(module_name, ifd) catch return error.FileWatcherFailed;
        return .{ .inotify_fd = ifd, .fd_watcher = fwd, .watches = .empty };
    }

    fn deinit(self: *LinuxBackend, allocator: std.mem.Allocator) void {
        self.fd_watcher.deinit();
        var it = self.watches.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        self.watches.deinit(allocator);
        std.posix.close(self.inotify_fd);
    }

    fn arm(self: *LinuxBackend) void {
        self.fd_watcher.wait_read() catch {};
    }

    fn add_watch(self: *LinuxBackend, allocator: std.mem.Allocator, path: []const u8) !void {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const wd = std.os.linux.inotify_add_watch(self.inotify_fd, path_z, watch_mask);
        if (wd < 0) return error.FileWatcherFailed;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const result = try self.watches.getOrPut(allocator, @intCast(wd));
        if (result.found_existing) allocator.free(result.value_ptr.*);
        result.value_ptr.* = owned_path;
    }

    fn remove_watch(self: *LinuxBackend, allocator: std.mem.Allocator, path: []const u8) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, path)) continue;
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
            self.watches.removeByPtr(entry.key_ptr);
            return;
        }
    }

    fn drain(self: *LinuxBackend, parent: tp.pid_ref) !void {
        const InotifyEvent = extern struct {
            wd: i32,
            mask: u32,
            cookie: u32,
            len: u32,
        };
        var buf: [4096]u8 align(@alignOf(InotifyEvent)) = undefined;
        while (true) {
            const n = std.posix.read(self.inotify_fd, &buf) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return e,
            };
            var offset: usize = 0;
            while (offset + @sizeOf(InotifyEvent) <= n) {
                const ev: *const InotifyEvent = @ptrCast(@alignCast(buf[offset..].ptr));
                const name_offset = offset + @sizeOf(InotifyEvent);
                offset = name_offset + ev.len;
                const watched_path = self.watches.get(ev.wd) orelse continue;
                const name: []const u8 = if (ev.len > 0)
                    std.mem.sliceTo(buf[name_offset..][0..ev.len], 0)
                else
                    "";
                const event_type: EventType = if (ev.mask & IN.CREATE != 0)
                    .created
                else if (ev.mask & (IN.DELETE | IN.DELETE_SELF) != 0)
                    .deleted
                else if (ev.mask & (IN.MODIFY | IN.CLOSE_WRITE) != 0)
                    .modified
                else if (ev.mask & (IN.MOVED_FROM | IN.MOVED_TO | IN.MOVE_SELF) != 0)
                    .renamed
                else
                    continue;
                if (name.len > 0) {
                    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ watched_path, name });
                    try parent.send(.{ "FW", "change", full_path, event_type });
                } else {
                    try parent.send(.{ "FW", "change", watched_path, event_type });
                }
            }
        }
    }
};

const MacosBackend = struct {
    kq: std.posix.fd_t,
    fd_watcher: tp.file_descriptor,
    watches: std.StringHashMapUnmanaged(std.posix.fd_t), // owned path -> fd

    const EVFILT_VNODE: i16 = -4;
    const EV_ADD: u16 = 0x0001;
    const EV_ENABLE: u16 = 0x0004;
    const EV_CLEAR: u16 = 0x0020;
    const NOTE_WRITE: u32 = 0x00000002;
    const NOTE_DELETE: u32 = 0x00000004;
    const NOTE_RENAME: u32 = 0x00000020;
    const NOTE_ATTRIB: u32 = 0x00000008;
    const NOTE_EXTEND: u32 = 0x00000004;

    fn init() !MacosBackend {
        const kq = std.posix.kqueue() catch return error.FileWatcherFailed;
        errdefer std.posix.close(kq);
        const fwd = tp.file_descriptor.init(module_name, kq) catch return error.FileWatcherFailed;
        return .{ .kq = kq, .fd_watcher = fwd, .watches = .empty };
    }

    fn deinit(self: *MacosBackend, allocator: std.mem.Allocator) void {
        self.fd_watcher.deinit();
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            std.posix.close(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.watches.deinit(allocator);
        std.posix.close(self.kq);
    }

    fn arm(self: *MacosBackend) void {
        self.fd_watcher.wait_read() catch {};
    }

    fn add_watch(self: *MacosBackend, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.watches.contains(path)) return;
        const path_fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileWatcherFailed;
        errdefer std.posix.close(path_fd);
        const kev = std.posix.Kevent{
            .ident = @intCast(path_fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND,
            .data = 0,
            .udata = 0,
        };
        _ = std.posix.kevent(self.kq, &.{kev}, &.{}, null) catch return error.FileWatcherFailed;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try self.watches.put(allocator, owned_path, path_fd);
    }

    fn remove_watch(self: *MacosBackend, allocator: std.mem.Allocator, path: []const u8) void {
        if (self.watches.fetchRemove(path)) |entry| {
            std.posix.close(entry.value);
            allocator.free(entry.key);
        }
    }

    fn drain(self: *MacosBackend, parent: tp.pid_ref) !void {
        var events: [64]std.posix.Kevent = undefined;
        const immediate: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
        const n = std.posix.kevent(self.kq, &.{}, &events, &immediate) catch return;
        for (events[0..n]) |ev| {
            var it = self.watches.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != @as(std.posix.fd_t, @intCast(ev.ident))) continue;
                const event_type: EventType = if (ev.fflags & NOTE_DELETE != 0)
                    .deleted
                else if (ev.fflags & NOTE_RENAME != 0)
                    .renamed
                else if (ev.fflags & (NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB) != 0)
                    .modified
                else
                    continue;
                try parent.send(.{ "FW", "change", entry.key_ptr.*, event_type });
                break;
            }
        }
    }
};

const WindowsBackend = struct {
    const windows = std.os.windows;

    iocp: windows.HANDLE,
    poll_timer: ?tp.timeout,
    watches: std.StringHashMapUnmanaged(Watch),

    const poll_interval_ms: u64 = 50;

    const Watch = struct {
        handle: windows.HANDLE,
        buf: *align(4) [buf_size]u8,
        overlapped: windows.OVERLAPPED,
        path: []u8, // owned
    };

    const buf_size = 65536;

    const FILE_NOTIFY_INFORMATION = extern struct {
        NextEntryOffset: windows.DWORD,
        Action: windows.DWORD,
        FileNameLength: windows.DWORD,
        FileName: [1]windows.WCHAR,
    };

    const FILE_ACTION_ADDED: windows.DWORD = 1;
    const FILE_ACTION_REMOVED: windows.DWORD = 2;
    const FILE_ACTION_MODIFIED: windows.DWORD = 3;
    const FILE_ACTION_RENAMED_OLD_NAME: windows.DWORD = 4;
    const FILE_ACTION_RENAMED_NEW_NAME: windows.DWORD = 5;

    const notify_filter: windows.DWORD =
        0x00000001 | // FILE_NOTIFY_CHANGE_FILE_NAME
        0x00000002 | // FILE_NOTIFY_CHANGE_DIR_NAME
        0x00000008 | // FILE_NOTIFY_CHANGE_SIZE
        0x00000010 | // FILE_NOTIFY_CHANGE_LAST_WRITE
        0x00000040; //  FILE_NOTIFY_CHANGE_CREATION

    fn init() !WindowsBackend {
        const iocp = windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 1) catch
            return error.FileWatcherFailed;
        return .{ .iocp = iocp, .poll_timer = null, .watches = .empty };
    }

    fn deinit(self: *WindowsBackend, allocator: std.mem.Allocator) void {
        if (self.poll_timer) |*t| t.deinit();
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            _ = windows.kernel32.CloseHandle(entry.value_ptr.*.handle);
            allocator.free(entry.value_ptr.*.path);
            allocator.destroy(entry.value_ptr.*.buf);
        }
        self.watches.deinit(allocator);
        _ = windows.kernel32.CloseHandle(self.iocp);
    }

    fn arm(self: *WindowsBackend) void {
        if (self.poll_timer) |*t| t.deinit();
        self.poll_timer = tp.timeout.init_ms(poll_interval_ms, tp.message.fmt(.{"FW_poll"})) catch null;
    }

    fn add_watch(self: *WindowsBackend, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.watches.contains(path)) return;
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);
        const handle = windows.kernel32.CreateFileW(
            path_w,
            windows.GENERIC_READ,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            0x02000000 | 0x40000000, // FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.FileWatcherFailed;
        errdefer _ = windows.kernel32.CloseHandle(handle);
        _ = windows.CreateIoCompletionPort(handle, self.iocp, @intFromPtr(handle), 0) catch return error.FileWatcherFailed;
        const buf = try allocator.create([buf_size]u8);
        errdefer allocator.destroy(buf);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        if (windows.kernel32.ReadDirectoryChangesW(handle, buf, buf_size, 1, notify_filter, null, &overlapped, null) == 0)
            return error.FileWatcherFailed;
        try self.watches.put(allocator, owned_path, .{
            .handle = handle,
            .buf = buf,
            .overlapped = overlapped,
            .path = owned_path,
        });
    }

    fn remove_watch(self: *WindowsBackend, allocator: std.mem.Allocator, path: []const u8) void {
        if (self.watches.fetchRemove(path)) |entry| {
            _ = windows.kernel32.CloseHandle(entry.value.handle);
            allocator.free(entry.value.path);
            allocator.destroy(entry.value.buf);
        }
    }

    fn drain(self: *WindowsBackend, parent: tp.pid_ref) !void {
        var bytes: windows.DWORD = 0;
        var key: windows.ULONG_PTR = 0;
        var overlapped_ptr: ?*windows.OVERLAPPED = null;
        while (true) {
            const ok = windows.kernel32.GetQueuedCompletionStatus(self.iocp, &bytes, &key, &overlapped_ptr, 0);
            if (ok == 0 or overlapped_ptr == null) break;
            const triggered_handle: windows.HANDLE = @ptrFromInt(key);
            var it = self.watches.iterator();
            while (it.next()) |entry| {
                const w = entry.value_ptr;
                if (w.handle != triggered_handle) continue;
                if (bytes > 0) {
                    var offset: usize = 0;
                    while (offset < bytes) {
                        const info: *FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(w.buf[offset..].ptr));
                        const name_wchars = info.FileName[0 .. info.FileNameLength / 2];
                        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const name_len = std.unicode.utf16LeToUtf8(&name_buf, name_wchars) catch 0;
                        const event_type: EventType = switch (info.Action) {
                            FILE_ACTION_ADDED => .created,
                            FILE_ACTION_REMOVED => .deleted,
                            FILE_ACTION_MODIFIED => .modified,
                            FILE_ACTION_RENAMED_OLD_NAME, FILE_ACTION_RENAMED_NEW_NAME => .renamed,
                            else => {
                                if (info.NextEntryOffset == 0) break;
                                offset += info.NextEntryOffset;
                                continue;
                            },
                        };
                        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const full_path = std.fmt.bufPrint(&full_buf, "{s}\\{s}", .{ w.path, name_buf[0..name_len] }) catch continue;
                        try parent.send(.{ "FW", "change", full_path, event_type });
                        if (info.NextEntryOffset == 0) break;
                        offset += info.NextEntryOffset;
                    }
                }
                // Re-arm ReadDirectoryChangesW for the next batch.
                w.overlapped = std.mem.zeroes(windows.OVERLAPPED);
                _ = windows.kernel32.ReadDirectoryChangesW(w.handle, w.buf, buf_size, 1, notify_filter, null, &w.overlapped, null);
                break;
            }
        }
    }
};

const Process = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    logger: log.Logger,
    receiver: Receiver,
    backend: Backend,

    const Receiver = tp.Receiver(*Process);

    fn create() SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(Process);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .parent = tp.self_pid().clone(),
            .logger = log.logger(module_name),
            .receiver = Receiver.init(Process.receive, self),
            .backend = undefined,
        };
        return tp.spawn_link(self.allocator, self, Process.start, module_name);
    }

    fn deinit(self: *Process) void {
        self.backend.deinit(self.allocator);
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *Process) tp.result {
        errdefer self.deinit();
        _ = tp.set_trap(true);
        self.backend = Backend.init() catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.backend.arm();
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            else => {
                const err = tp.exit_error(e, @errorReturnTrace());
                self.logger.err("receive", err);
                return err;
            },
        };
    }

    fn receive_safe(self: *Process, _: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        var path: []const u8 = undefined;
        var tag: []const u8 = undefined;
        var err_code: i64 = 0;
        var err_msg: []const u8 = undefined;

        if (try cbor.match(m.buf, .{ "fd", tp.extract(&tag), "read_ready" })) {
            self.backend.drain(self.parent.ref()) catch |e| self.logger.err("drain", e);
            self.backend.arm();
        } else if (try cbor.match(m.buf, .{ "fd", tp.extract(&tag), "read_error", tp.extract(&err_code), tp.extract(&err_msg) })) {
            self.logger.print("fd read error on {s}: ({d}) {s}", .{ tag, err_code, err_msg });
            self.backend.arm();
        } else if (builtin.os.tag == .windows and try cbor.match(m.buf, .{"FW_poll"})) {
            self.backend.drain(self.parent.ref()) catch |e| self.logger.err("drain", e);
            self.backend.arm();
        } else if (try cbor.match(m.buf, .{ "watch", tp.extract(&path) })) {
            self.backend.add_watch(self.allocator, path) catch |e| self.logger.err("watch", e);
        } else if (try cbor.match(m.buf, .{ "unwatch", tp.extract(&path) })) {
            self.backend.remove_watch(self.allocator, path);
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            return error.ExitNormal;
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }
};
