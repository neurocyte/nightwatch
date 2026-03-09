const std = @import("std");
const types = @import("../types.zig");
const Handler = types.Handler;
const EventType = types.EventType;
const ObjectType = types.ObjectType;

pub const watches_recursively = true; // FSEventStreamCreate watches the entire subtree
pub const detects_file_modifications = true;

handler: *Handler,
stream: ?*anyopaque, // FSEventStreamRef
queue: ?*anyopaque, // dispatch_queue_t
ctx: ?*CallbackContext, // heap-allocated, freed after stream is stopped
watches: std.StringArrayHashMapUnmanaged(void), // owned paths

const threaded = false; // callback fires on GCD thread; no FW_event needed

const kFSEventStreamCreateFlagNoDefer: u32 = 0x00000002;
const kFSEventStreamCreateFlagFileEvents: u32 = 0x00000010;
const kFSEventStreamEventFlagItemCreated: u32 = 0x00000100;
const kFSEventStreamEventFlagItemRemoved: u32 = 0x00000200;
const kFSEventStreamEventFlagItemRenamed: u32 = 0x00000800;
const kFSEventStreamEventFlagItemModified: u32 = 0x00001000;
const kFSEventStreamEventFlagItemIsDir: u32 = 0x00020000;
const kFSEventStreamEventIdSinceNow: u64 = 0xFFFFFFFFFFFFFFFF;
const kCFStringEncodingUTF8: u32 = 0x08000100;

// Mirror of FSEventStreamContext (Apple SDK struct; version must be 0).
const FSEventStreamContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque = null,
    retain: ?*anyopaque = null,
    release: ?*anyopaque = null,
    copy_description: ?*anyopaque = null,
};

const cf = struct {
    pub extern "c" fn CFStringCreateWithBytesNoCopy(
        alloc: ?*anyopaque,
        bytes: [*]const u8,
        numBytes: isize,
        encoding: u32,
        isExternalRepresentation: u8,
        contentsDeallocator: ?*anyopaque,
    ) ?*anyopaque;
    pub extern "c" fn CFArrayCreate(
        allocator: ?*anyopaque,
        values: [*]const ?*anyopaque,
        numValues: isize,
        callBacks: ?*anyopaque,
    ) ?*anyopaque;
    pub extern "c" fn CFRelease(cf: *anyopaque) void;
    pub extern "c" fn FSEventStreamCreate(
        allocator: ?*anyopaque,
        callback: *const anyopaque,
        context: *const FSEventStreamContext,
        pathsToWatch: *anyopaque,
        sinceWhen: u64,
        latency: f64,
        flags: u32,
    ) ?*anyopaque;
    pub extern "c" fn FSEventStreamSetDispatchQueue(stream: *anyopaque, queue: *anyopaque) void;
    pub extern "c" fn FSEventStreamStart(stream: *anyopaque) u8;
    pub extern "c" fn FSEventStreamStop(stream: *anyopaque) void;
    pub extern "c" fn FSEventStreamInvalidate(stream: *anyopaque) void;
    pub extern "c" fn FSEventStreamRelease(stream: *anyopaque) void;
    pub extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) *anyopaque;
    pub extern "c" fn dispatch_release(obj: *anyopaque) void;
    pub extern "c" var kCFAllocatorNull: *anyopaque;
};

const CallbackContext = struct {
    handler: *Handler,
    // Snapshot of the watched root paths at arm() time, used to filter out
    // spurious events for the root directories themselves that FSEvents
    // sometimes delivers as historical events at stream start.
    watched_roots: []const []const u8, // owned slice of owned strings
};

pub fn init(handler: *Handler) error{}!@This() {
    return .{
        .handler = handler,
        .stream = null,
        .queue = null,
        .ctx = null,
        .watches = .empty,
    };
}

fn stop_stream(self: *@This(), allocator: std.mem.Allocator) void {
    if (self.stream) |s| {
        cf.FSEventStreamStop(s);
        cf.FSEventStreamInvalidate(s);
        cf.FSEventStreamRelease(s);
        self.stream = null;
    }
    if (self.queue) |q| {
        cf.dispatch_release(q);
        self.queue = null;
    }
    if (self.ctx) |c| {
        for (c.watched_roots) |r| allocator.free(r);
        allocator.free(c.watched_roots);
        allocator.destroy(c);
        self.ctx = null;
    }
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.stop_stream(allocator);
    var it = self.watches.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    self.watches.deinit(allocator);
}

pub fn arm(self: *@This(), allocator: std.mem.Allocator) error{ OutOfMemory, ArmFailed }!void {
    if (self.stream != null) return;
    if (self.watches.count() == 0) return; // no paths yet; will arm on first add_watch

    var cf_strings: std.ArrayListUnmanaged(?*anyopaque) = .empty;
    defer cf_strings.deinit(allocator);
    var it = self.watches.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const s = cf.CFStringCreateWithBytesNoCopy(
            null,
            path.ptr,
            @intCast(path.len),
            kCFStringEncodingUTF8,
            0,
            cf.kCFAllocatorNull,
        ) orelse continue;
        cf_strings.append(allocator, s) catch {
            cf.CFRelease(s);
            break;
        };
    }
    defer for (cf_strings.items) |s| cf.CFRelease(s.?);

    const paths_array = cf.CFArrayCreate(
        null,
        cf_strings.items.ptr,
        @intCast(cf_strings.items.len),
        null,
    ) orelse return error.ArmFailed;
    defer cf.CFRelease(paths_array);

    // Snapshot watched root paths so the callback can filter them out.
    const roots = try allocator.alloc([]const u8, self.watches.count());
    errdefer allocator.free(roots);
    var ri: usize = 0;
    errdefer for (roots[0..ri]) |r| allocator.free(r);
    var wit2 = self.watches.iterator();
    while (wit2.next()) |entry| {
        roots[ri] = try allocator.dupe(u8, entry.key_ptr.*);
        ri += 1;
    }

    const ctx = try allocator.create(CallbackContext);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .handler = self.handler, .watched_roots = roots };

    // FSEventStreamCreate copies the context struct; stack allocation is fine.
    const stream_ctx = FSEventStreamContext{ .version = 0, .info = ctx };
    const stream = cf.FSEventStreamCreate(
        null,
        @ptrCast(&callback),
        &stream_ctx,
        paths_array,
        kFSEventStreamEventIdSinceNow,
        0.1,
        kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents,
    ) orelse return error.ArmFailed;
    errdefer cf.FSEventStreamRelease(stream);

    const queue = cf.dispatch_queue_create("nightwatch", null);
    cf.FSEventStreamSetDispatchQueue(stream, queue);
    _ = cf.FSEventStreamStart(stream);

    self.stream = stream;
    self.queue = queue;
    self.ctx = ctx;
}

fn callback(
    _: *anyopaque,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: *anyopaque,
    event_flags: [*]const u32,
    _: [*]const u64,
) callconv(.c) void {
    const ctx: *CallbackContext = @ptrCast(@alignCast(info orelse return));
    const paths: [*][*:0]const u8 = @ptrCast(@alignCast(event_paths));
    outer: for (0..num_events) |i| {
        const path = std.mem.sliceTo(paths[i], 0);
        const flags = event_flags[i];

        // Skip events for the watched root dirs themselves; FSEvents often
        // delivers spurious historical events for them at stream start.
        for (ctx.watched_roots) |root| {
            if (std.mem.eql(u8, path, root)) continue :outer;
        }

        // FSEvents coalesces operations, so multiple flags may be set on
        // a single event.  Emit one change call per applicable flag so
        // callers see all relevant event types (e.g. created + modified).
        const ot: ObjectType = if (flags & kFSEventStreamEventFlagItemIsDir != 0) .dir else .file;
        if (flags & kFSEventStreamEventFlagItemCreated != 0) {
            ctx.handler.change(path, .created, ot) catch {};
        }
        if (flags & kFSEventStreamEventFlagItemRemoved != 0) {
            ctx.handler.change(path, .deleted, ot) catch {};
        }
        if (flags & kFSEventStreamEventFlagItemRenamed != 0) {
            ctx.handler.change(path, .renamed, ot) catch {};
        }
        if (flags & kFSEventStreamEventFlagItemModified != 0) {
            ctx.handler.change(path, .modified, ot) catch {};
        }
    }
}

pub fn add_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}!void {
    if (self.watches.contains(path)) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try self.watches.put(allocator, owned, {});
    self.stop_stream(allocator);
    self.arm(allocator) catch {};
}

pub fn remove_watch(self: *@This(), allocator: std.mem.Allocator, path: []const u8) void {
    if (self.watches.fetchSwapRemove(path)) |entry| allocator.free(entry.key);
    self.stop_stream(allocator);
    self.arm(allocator) catch {};
}
