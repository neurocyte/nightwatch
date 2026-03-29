const std = @import("std");
const types = @import("../types.zig");
const Handler = types.Handler;
const EventType = types.EventType;
const ObjectType = types.ObjectType;

pub const watches_recursively = true; // ReadDirectoryChangesW with bWatchSubtree=1
pub const detects_file_modifications = true;
pub const emits_close_events = false;
pub const emits_rename_for_files = true;
pub const emits_rename_for_dirs = true;

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
    pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const windows.WCHAR) callconv(.winapi) windows.DWORD;
};

handler: *Handler,
iocp: windows.HANDLE,
thread: ?std.Thread,
watches: std.StringHashMapUnmanaged(*Watch),
watches_mutex: std.Thread.Mutex,
path_types: std.StringHashMapUnmanaged(ObjectType),

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

pub fn init(handler: *Handler) windows.CreateIoCompletionPortError!@This() {
    const iocp = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 1);
    return .{ .handler = handler, .iocp = iocp, .thread = null, .watches = .empty, .watches_mutex = .{}, .path_types = .empty };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    // Wake the background thread with a shutdown key, then wait for it.
    _ = win32.PostQueuedCompletionStatus(self.iocp, 0, SHUTDOWN_KEY, null);
    if (self.thread) |t| t.join();
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        const w = entry.value_ptr.*;
        _ = win32.CloseHandle(w.handle);
        allocator.free(w.path);
        allocator.free(w.buf);
        allocator.destroy(w);
    }
    self.watches.deinit(allocator);
    var pt_it = self.path_types.iterator();
    while (pt_it.next()) |entry| allocator.free(entry.key_ptr.*);
    self.path_types.deinit(allocator);
    _ = win32.CloseHandle(self.iocp);
}

pub fn arm(self: *@This(), allocator: std.mem.Allocator) (error{AlreadyArmed} || std.Thread.SpawnError)!void {
    if (self.thread != null) return error.AlreadyArmed;
    self.thread = try std.Thread.spawn(.{}, thread_fn, .{ allocator, self.iocp, &self.watches, &self.watches_mutex, &self.path_types, self.handler });
}

fn thread_fn(
    allocator: std.mem.Allocator,
    iocp: windows.HANDLE,
    watches: *std.StringHashMapUnmanaged(*Watch),
    watches_mutex: *std.Thread.Mutex,
    path_types: *std.StringHashMapUnmanaged(ObjectType),
    handler: *Handler,
) void {
    var bytes: windows.DWORD = 0;
    var key: windows.ULONG_PTR = 0;
    var overlapped_ptr: ?*windows.OVERLAPPED = null;
    while (true) {
        // Block indefinitely until IOCP has a completion or shutdown signal.
        const ok = win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_ptr, windows.INFINITE);
        if (ok == 0 or key == SHUTDOWN_KEY) return;
        const triggered_handle: windows.HANDLE = @ptrFromInt(key);
        watches_mutex.lock();
        var it = watches.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr.*;
            if (w.handle != triggered_handle) continue;
            if (bytes > 0) {
                var offset: usize = 0;
                while (offset < bytes) {
                    const info: *FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(w.buf[offset..].ptr));
                    const name_wchars = (&info.FileName).ptr[0 .. info.FileNameLength / 2];
                    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const name_len = std.unicode.utf16LeToUtf8(&name_buf, name_wchars) catch {
                        if (info.NextEntryOffset == 0) break;
                        offset += info.NextEntryOffset;
                        continue;
                    };
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
                    const full_path = std.fmt.bufPrint(&full_buf, "{s}\\{s}", .{ w.path, name_buf[0..name_len] }) catch {
                        if (info.NextEntryOffset == 0) break;
                        offset += info.NextEntryOffset;
                        continue;
                    };
                    // Determine object_type: try GetFileAttributesW; cache result.
                    // For deleted paths and the old name in a rename, the path no
                    // longer exists at event time so GetFileAttributesW would fail;
                    // use the cached type instead.
                    const object_type: ObjectType = if (event_type == .deleted or
                        info.Action == FILE_ACTION_RENAMED_OLD_NAME) blk: {
                        const cached = path_types.fetchRemove(full_path);
                        break :blk if (cached) |kv| blk2: {
                            allocator.free(kv.key);
                            break :blk2 kv.value;
                        } else .unknown;
                    } else blk: {
                        var full_path_w: [std.fs.max_path_bytes]windows.WCHAR = undefined;
                        const len = std.unicode.utf8ToUtf16Le(&full_path_w, full_path) catch break :blk .unknown;
                        full_path_w[len] = 0;
                        const attrs = win32.GetFileAttributesW(full_path_w[0..len :0]);
                        const INVALID: windows.DWORD = 0xFFFFFFFF;
                        const FILE_ATTRIBUTE_DIRECTORY: windows.DWORD = 0x10;
                        const ot: ObjectType = if (attrs == INVALID) .unknown else if (attrs & FILE_ATTRIBUTE_DIRECTORY != 0) .dir else .file;
                        // Cache the determined type.
                        if (ot != .unknown) {
                            const gop = path_types.getOrPut(allocator, full_path) catch break :blk ot;
                            if (!gop.found_existing) {
                                gop.key_ptr.* = allocator.dupe(u8, full_path) catch {
                                    _ = path_types.remove(full_path);
                                    break :blk ot;
                                };
                            }
                            gop.value_ptr.* = ot;
                        }
                        break :blk ot;
                    };
                    // Capture next_entry_offset before releasing the mutex: after unlock,
                    // the main thread may call remove_watch() which frees w.buf, making
                    // the `info` pointer (which points into w.buf) a dangling reference.
                    const next_entry_offset = info.NextEntryOffset;
                    watches_mutex.unlock();
                    handler.change(full_path, event_type, object_type) catch |e| {
                        std.log.err("nightwatch: handler returned {s}, stopping watch thread", .{@errorName(e)});
                        watches_mutex.lock();
                        break;
                    };
                    watches_mutex.lock();
                    if (next_entry_offset == 0) break;
                    offset += next_entry_offset;
                }
            }
            // Re-arm ReadDirectoryChangesW for the next batch.
            w.overlapped = std.mem.zeroes(windows.OVERLAPPED);
            if (win32.ReadDirectoryChangesW(w.handle, w.buf.ptr, buf_size, 1, notify_filter, null, &w.overlapped, null) == 0)
                std.log.err("nightwatch: ReadDirectoryChangesW re-arm failed for {s}, future events lost", .{entry.key_ptr.*});
            break;
        }
        watches_mutex.unlock();
    }
}

pub fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, WatchFailed }!void {
    self.watches_mutex.lock();
    defer self.watches_mutex.unlock();
    if (self.watches.contains(path)) return;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return error.WatchFailed;
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
    if (handle == windows.INVALID_HANDLE_VALUE) return error.WatchFailed;
    errdefer _ = win32.CloseHandle(handle);
    _ = windows.CreateIoCompletionPort(handle, self.iocp, @intFromPtr(handle), 0) catch return error.WatchFailed;
    const buf = try allocator.alignedAlloc(u8, .fromByteUnits(4), buf_size);
    errdefer allocator.free(buf);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    // Heap-allocate Watch so its address (and &w.overlapped) is stable even
    // if the watches map is resized by a concurrent add_watch call.
    const w = try allocator.create(Watch);
    errdefer allocator.destroy(w);
    w.* = .{ .handle = handle, .buf = buf, .overlapped = std.mem.zeroes(windows.OVERLAPPED), .path = owned_path };
    if (win32.ReadDirectoryChangesW(handle, buf.ptr, buf_size, 1, notify_filter, null, &w.overlapped, null) == 0)
        return error.WatchFailed;
    try self.watches.put(allocator, owned_path, w);
    // Seed path_types with pre-existing entries so delete/rename events for
    // paths that existed before this watch started can resolve their ObjectType.
    self.scan_path_types(allocator, owned_path);
}

// Walk root recursively and seed path_types with the type of every entry.
// Called from add_watch (mutex already held) so pre-existing paths are
// known before any FILE_ACTION_REMOVED or FILE_ACTION_RENAMED_OLD_NAME fires.
fn scan_path_types(self: *@This(), allocator: std.mem.Allocator, root: []const u8) void {
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        const ot: ObjectType = switch (entry.kind) {
            .directory => .dir,
            .file => .file,
            else => continue,
        };
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ root, entry.name }) catch continue;
        const gop = self.path_types.getOrPut(allocator, full_path) catch continue;
        if (!gop.found_existing) {
            gop.key_ptr.* = allocator.dupe(u8, full_path) catch {
                _ = self.path_types.remove(full_path);
                continue;
            };
        }
        gop.value_ptr.* = ot;
        if (ot == .dir) self.scan_path_types(allocator, gop.key_ptr.*);
    }
}

pub fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    self.watches_mutex.lock();
    defer self.watches_mutex.unlock();
    if (self.watches.fetchRemove(path)) |entry| {
        const w = entry.value;
        _ = win32.CloseHandle(w.handle);
        allocator.free(w.path);
        allocator.free(w.buf);
        allocator.destroy(w);
    }
}
