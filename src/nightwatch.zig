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
    /// Only produced on macOS and Windows where the OS gives no pairing info.
    /// On Linux, paired renames are emitted as a { "FW", "rename", from, to } message instead.
    renamed,
};

pub const Error = FileWatcherError;
pub const FileWatcherError = error{
    FileWatcherSendFailed,
    ThespianSpawnFailed,
    OutOfMemory,
};
const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

/// Watch a path (file or directory) for changes. The caller will receive:
///   .{ "FW", "change", path, event_type }
/// where event_type is a file_watcher.EventType tag string: "created", "modified", "deleted", "renamed"
/// On Linux, paired renames produce: .{ "FW", "rename", from_path, to_path }
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
    return (try get()).pid.send(message) catch error.FileWatcherSendFailed;
}

fn create() SpawnError!Self {
    const pid = try Process.create();
    defer pid.deinit();
    tp.env.get().proc_set(module_name, pid.ref());
    return .{ .pid = tp.env.get().proc(module_name) };
}

const Backend = switch (builtin.os.tag) {
    .linux => INotifyBackend,
    .macos, .freebsd => KQueueBackend,
    .windows => WindowsBackend,
    else => @compileError("file_watcher: unsupported OS"),
};

const INotifyBackend = struct {
    inotify_fd: std.posix.fd_t,
    fd_watcher: tp.file_descriptor,
    watches: std.AutoHashMapUnmanaged(i32, []u8), // wd -> owned path

    const threaded = false;

    const IN = std.os.linux.IN;

    const watch_mask: u32 = IN.CREATE | IN.DELETE | IN.MODIFY |
        IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF |
        IN.MOVE_SELF | IN.CLOSE_WRITE;

    const in_flags: std.os.linux.O = .{ .NONBLOCK = true };

    fn init() error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, SystemResources, Unexpected, ThespianFileDescriptorInitFailed }!@This() {
        const ifd = try std.posix.inotify_init1(@bitCast(in_flags));
        errdefer std.posix.close(ifd);
        const fwd = try tp.file_descriptor.init(module_name, ifd);
        return .{ .inotify_fd = ifd, .fd_watcher = fwd, .watches = .empty };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.fd_watcher.deinit();
        var it = self.watches.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        self.watches.deinit(allocator);
        std.posix.close(self.inotify_fd);
    }

    fn arm(self: *@This(), parent: tp.pid) error{ThespianFileDescriptorWaitReadFailed}!void {
        parent.deinit();
        try self.fd_watcher.wait_read();
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}!void {
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

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, path)) continue;
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
            self.watches.removeByPtr(entry.key_ptr);
            return;
        }
    }

    fn drain(self: *@This(), allocator: std.mem.Allocator, parent: tp.pid_ref) (std.posix.ReadError || error{ NoSpaceLeft, OutOfMemory, Exit })!void {
        const InotifyEvent = extern struct {
            wd: i32,
            mask: u32,
            cookie: u32,
            len: u32,
        };

        // A pending MOVED_FROM waiting to be paired with a MOVED_TO by cookie.
        const PendingRename = struct {
            cookie: u32,
            path: []u8, // owned by drain's allocator
        };

        var buf: [4096]u8 align(@alignOf(InotifyEvent)) = undefined;
        var pending_renames: std.ArrayListUnmanaged(PendingRename) = .empty;
        defer {
            // Any unpaired MOVED_FROM means the file was moved out of the watched tree.
            for (pending_renames.items) |r| {
                parent.send(.{ "FW", "change", r.path, EventType.deleted }) catch {}; // moved outside watched tree
                allocator.free(r.path);
            }
            pending_renames.deinit(allocator);
        }

        while (true) {
            const n = std.posix.read(self.inotify_fd, &buf) catch |e| switch (e) {
                error.WouldBlock => break,
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

                var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path: []const u8 = if (name.len > 0)
                    try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ watched_path, name })
                else
                    watched_path;

                if (ev.mask & IN.MOVED_FROM != 0) {
                    // Park it, we may receive a paired MOVED_TO with the same cookie.
                    try pending_renames.append(allocator, .{
                        .cookie = ev.cookie,
                        .path = try allocator.dupe(u8, full_path),
                    });
                } else if (ev.mask & IN.MOVED_TO != 0) {
                    // Look for a paired MOVED_FROM.
                    var found: ?usize = null;
                    for (pending_renames.items, 0..) |r, i| {
                        if (r.cookie == ev.cookie) {
                            found = i;
                            break;
                        }
                    }
                    if (found) |i| {
                        // Complete rename pair: emit a single atomic rename message.
                        const r = pending_renames.swapRemove(i);
                        defer allocator.free(r.path);
                        try parent.send(.{ "FW", "rename", r.path, full_path });
                    } else {
                        // No paired MOVED_FROM, file was moved in from outside the watched tree.
                        try parent.send(.{ "FW", "change", full_path, EventType.created });
                    }
                } else if (ev.mask & IN.MOVE_SELF != 0) {
                    // The watched directory itself was renamed/moved away.
                    try parent.send(.{ "FW", "change", full_path, EventType.deleted });
                } else {
                    const event_type: EventType = if (ev.mask & IN.CREATE != 0)
                        .created
                    else if (ev.mask & (IN.DELETE | IN.DELETE_SELF) != 0)
                        .deleted
                    else if (ev.mask & (IN.MODIFY | IN.CLOSE_WRITE) != 0)
                        .modified
                    else
                        continue;
                    try parent.send(.{ "FW", "change", full_path, event_type });
                }
            }
        }
    }
};

const KQueueBackend = struct {
    kq: std.posix.fd_t,
    shutdown_pipe: [2]std.posix.fd_t, // [0]=read [1]=write; write a byte to wake the thread
    thread: ?std.Thread,
    watches: std.StringHashMapUnmanaged(std.posix.fd_t), // owned path -> fd

    const threaded = true;

    const EVFILT_VNODE: i16 = -4;
    const EVFILT_READ: i16 = -1;
    const EV_ADD: u16 = 0x0001;
    const EV_ENABLE: u16 = 0x0004;
    const EV_CLEAR: u16 = 0x0020;
    const EV_DELETE: u16 = 0x0002;
    const NOTE_WRITE: u32 = 0x00000002;
    const NOTE_DELETE: u32 = 0x00000004;
    const NOTE_RENAME: u32 = 0x00000020;
    const NOTE_ATTRIB: u32 = 0x00000008;
    const NOTE_EXTEND: u32 = 0x00000004;

    fn init() (std.posix.KQueueError || std.posix.KEventError)!@This() {
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
        return .{ .kq = kq, .shutdown_pipe = pipe, .thread = null, .watches = .empty };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Signal the thread to exit by writing to the shutdown pipe.
        _ = std.posix.write(self.shutdown_pipe[1], &[_]u8{0}) catch {};
        if (self.thread) |t| t.join();
        std.posix.close(self.shutdown_pipe[0]);
        std.posix.close(self.shutdown_pipe[1]);
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            std.posix.close(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.watches.deinit(allocator);
        std.posix.close(self.kq);
    }

    fn arm(self: *@This(), parent: tp.pid) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
        errdefer parent.deinit();
        if (self.thread != null) return error.AlreadyArmed;
        self.thread = try std.Thread.spawn(.{}, thread_fn, .{ self.kq, parent });
    }

    fn thread_fn(kq: std.posix.fd_t, parent: tp.pid) void {
        defer parent.deinit();
        var events: [64]std.posix.Kevent = undefined;
        while (true) {
            // Block indefinitely until kqueue has events.
            const n = std.posix.kevent(kq, &.{}, &events, null) catch break;
            var has_vnode_events = false;
            for (events[0..n]) |ev| {
                if (ev.filter == EVFILT_READ) return; // shutdown pipe readable, exit
                if (ev.filter == EVFILT_VNODE) has_vnode_events = true;
            }
            if (has_vnode_events)
                parent.send(.{"FW_event"}) catch break;
        }
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) (std.posix.OpenError || std.posix.KEventError || error{OutOfMemory})!void {
        if (self.watches.contains(path)) return;
        const path_fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.posix.close(path_fd);
        const kev = std.posix.Kevent{
            .ident = @intCast(path_fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND,
            .data = 0,
            .udata = 0,
        };
        _ = try std.posix.kevent(self.kq, &.{kev}, &.{}, null);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try self.watches.put(allocator, owned_path, path_fd);
    }

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        if (self.watches.fetchRemove(path)) |entry| {
            std.posix.close(entry.value);
            allocator.free(entry.key);
        }
    }

    fn drain(self: *@This(), allocator: std.mem.Allocator, parent: tp.pid_ref) tp.result {
        _ = allocator;
        var events: [64]std.posix.Kevent = undefined;
        const immediate: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
        const n = std.posix.kevent(self.kq, &.{}, &events, &immediate) catch return;
        for (events[0..n]) |ev| {
            if (ev.filter != EVFILT_VNODE) continue;
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
    const threaded = true;
    const windows = std.os.windows;

    const win32 = struct {
        pub extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn ReadDirectoryChangesW(
            hDirectory: windows.HANDLE,
            lpBuffer: *anyopaque,
            nBufferLength: windows.DWORD,
            bWatchSubtree: windows.BOOL,
            dwNotifyFilter: windows.DWORD,
            lpBytesReturned: ?*windows.DWORD,
            lpOverlapped: ?*windows.OVERLAPPED,
            lpCompletionRoutine: ?*anyopaque,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn GetQueuedCompletionStatus(
            CompletionPort: windows.HANDLE,
            lpNumberOfBytesTransferred: *windows.DWORD,
            lpCompletionKey: *windows.ULONG_PTR,
            lpOverlapped: *?*windows.OVERLAPPED,
            dwMilliseconds: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: [*:0]const windows.WCHAR,
            dwDesiredAccess: windows.DWORD,
            dwShareMode: windows.DWORD,
            lpSecurityAttributes: ?*anyopaque,
            dwCreationDisposition: windows.DWORD,
            dwFlagsAndAttributes: windows.DWORD,
            hTemplateFile: ?windows.HANDLE,
        ) callconv(.winapi) windows.HANDLE;
        pub extern "kernel32" fn PostQueuedCompletionStatus(
            CompletionPort: windows.HANDLE,
            dwNumberOfBytesTransferred: windows.DWORD,
            dwCompletionKey: windows.ULONG_PTR,
            lpOverlapped: ?*windows.OVERLAPPED,
        ) callconv(.winapi) windows.BOOL;
    };

    iocp: windows.HANDLE,
    thread: ?std.Thread,
    watches: std.StringHashMapUnmanaged(Watch),

    // A completion key of zero is used to signal the background thread to exit.
    const SHUTDOWN_KEY: windows.ULONG_PTR = 0;

    const Watch = struct {
        handle: windows.HANDLE,
        buf: Buf,
        overlapped: windows.OVERLAPPED,
        path: []u8, // owned
    };

    const buf_size = 65536;
    const Buf = []align(4) u8;

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

    fn init() windows.CreateIoCompletionPortError!@This() {
        const iocp = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 1);
        return .{ .iocp = iocp, .thread = null, .watches = .empty };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Wake the background thread with a shutdown key, then wait for it.
        _ = win32.PostQueuedCompletionStatus(self.iocp, 0, SHUTDOWN_KEY, null);
        if (self.thread) |t| t.join();
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            _ = win32.CloseHandle(entry.value_ptr.*.handle);
            allocator.free(entry.value_ptr.*.path);
            allocator.free(entry.value_ptr.*.buf);
        }
        self.watches.deinit(allocator);
        _ = win32.CloseHandle(self.iocp);
    }

    fn arm(self: *@This(), parent: tp.pid) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
        errdefer parent.deinit();
        if (self.thread != null) return error.AlreadyArmed;
        self.thread = try std.Thread.spawn(.{}, thread_fn, .{ self.iocp, parent });
    }

    fn thread_fn(iocp: windows.HANDLE, parent: tp.pid) void {
        defer parent.deinit();
        var bytes: windows.DWORD = 0;
        var key: windows.ULONG_PTR = 0;
        var overlapped_ptr: ?*windows.OVERLAPPED = null;
        while (true) {
            // Block indefinitely until IOCP has a completion or shutdown signal.
            const ok = win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_ptr, windows.INFINITE);
            if (ok == 0 or key == SHUTDOWN_KEY) return;
            parent.send(.{"FW_event"}) catch return;
        }
    }

    fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) (windows.CreateIoCompletionPortError || error{
        InvalidUtf8,
        OutOfMemory,
        FileWatcherInvalidHandle,
        FileWatcherReadDirectoryChangesFailed,
    })!void {
        if (self.watches.contains(path)) return;
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);
        const handle = win32.CreateFileW(
            path_w,
            windows.GENERIC_READ,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            0x02000000 | 0x40000000, // FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.FileWatcherInvalidHandle;
        errdefer _ = win32.CloseHandle(handle);
        _ = try windows.CreateIoCompletionPort(handle, self.iocp, @intFromPtr(handle), 0);
        const buf = try allocator.alignedAlloc(u8, .fromByteUnits(4), buf_size);
        errdefer allocator.free(buf);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        if (win32.ReadDirectoryChangesW(handle, buf.ptr, buf_size, 1, notify_filter, null, &overlapped, null) == 0)
            return error.FileWatcherReadDirectoryChangesFailed;
        try self.watches.put(allocator, owned_path, .{
            .handle = handle,
            .buf = buf,
            .overlapped = overlapped,
            .path = owned_path,
        });
    }

    fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
        if (self.watches.fetchRemove(path)) |entry| {
            _ = win32.CloseHandle(entry.value.handle);
            allocator.free(entry.value.path);
            allocator.free(entry.value.buf);
        }
    }

    fn drain(self: *@This(), allocator: std.mem.Allocator, parent: tp.pid_ref) !void {
        _ = allocator;
        var bytes: windows.DWORD = 0;
        var key: windows.ULONG_PTR = 0;
        var overlapped_ptr: ?*windows.OVERLAPPED = null;
        while (true) {
            // Non-blocking drain, the blocking wait is done in the background thread.
            const ok = win32.GetQueuedCompletionStatus(self.iocp, &bytes, &key, &overlapped_ptr, 0);
            if (ok == 0 or overlapped_ptr == null or key == SHUTDOWN_KEY) break;
            const triggered_handle: windows.HANDLE = @ptrFromInt(key);
            var it = self.watches.iterator();
            while (it.next()) |entry| {
                const w = entry.value_ptr;
                if (w.handle != triggered_handle) continue;
                if (bytes > 0) {
                    var offset: usize = 0;
                    while (offset < bytes) {
                        const info: *FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(w.buf[offset..].ptr));
                        const name_wchars = (&info.FileName).ptr[0 .. info.FileNameLength / 2];
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
                _ = win32.ReadDirectoryChangesW(w.handle, w.buf.ptr, buf_size, 1, notify_filter, null, &w.overlapped, null);
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

    const Receiver = tp.Receiver(*@This());

    fn create() SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .parent = tp.self_pid().clone(),
            .logger = log.logger(module_name),
            .receiver = Receiver.init(@This().receive, self),
            .backend = undefined,
        };
        return tp.spawn_link(self.allocator, self, @This().start, module_name);
    }

    fn deinit(self: *@This()) void {
        self.backend.deinit(self.allocator);
        self.parent.deinit();
        self.logger.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *@This()) tp.result {
        errdefer self.deinit();
        _ = tp.set_trap(true);
        self.backend = Backend.init() catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.backend.arm(tp.self_pid().clone()) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
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

    fn receive_safe(self: *@This(), _: tp.pid_ref, m: tp.message) (error{ExitNormal} || cbor.Error)!void {
        var path: []const u8 = undefined;
        var tag: []const u8 = undefined;
        var err_code: i64 = 0;
        var err_msg: []const u8 = undefined;

        if (!Backend.threaded and try cbor.match(m.buf, .{ "fd", tp.extract(&tag), "read_ready" })) {
            self.backend.drain(self.allocator, self.parent.ref()) catch |e| self.logger.err("drain", e);
        } else if (!Backend.threaded and try cbor.match(m.buf, .{ "fd", tp.extract(&tag), "read_error", tp.extract(&err_code), tp.extract(&err_msg) })) {
            self.logger.print("fd read error on {s}: ({d}) {s}", .{ tag, err_code, err_msg });
        } else if (Backend.threaded and try cbor.match(m.buf, .{"FW_event"})) {
            self.backend.drain(self.allocator, self.parent.ref()) catch |e| self.logger.err("drain", e);
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
