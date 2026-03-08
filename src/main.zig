const std = @import("std");
const builtin = @import("builtin");
const nightwatch = @import("nightwatch");

const is_posix = switch (builtin.os.tag) {
    .linux, .macos, .freebsd => true,
    else => false,
};

// Self-pipe: signal handler writes a byte so poll() / read() unblocks cleanly.
var sig_pipe: if (is_posix) [2]std.posix.fd_t else void = undefined;

fn posix_sighandler(_: c_int) callconv(.c) void {
    _ = std.posix.write(sig_pipe[1], &[_]u8{0}) catch {};
}

const CliHandler = struct {
    handler: nightwatch.Handler,
    out: std.fs.File,

    const vtable = nightwatch.Handler.VTable{
        .change = change_cb,
        .rename = rename_cb,
        .wait_readable = if (nightwatch.linux_poll_mode) wait_readable_cb else {},
    };

    fn change_cb(h: *nightwatch.Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        var buf: [4096]u8 = undefined;
        var stdout = self.out.writer(&buf);
        defer stdout.interface.flush() catch {};
        const event_label = switch (event_type) {
            .created => "create ",
            .modified => "modify ",
            .deleted => "delete ",
            .renamed => "rename ",
        };
        const type_label = switch (object_type) {
            .file => "file",
            .dir => "dir ",
            .unknown => "?   ",
        };
        stdout.interface.print("{s}  {s}  {s}\n", .{ event_label, type_label, path }) catch return error.HandlerFailed;
    }

    fn rename_cb(h: *nightwatch.Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        var buf: [4096]u8 = undefined;
        var stdout = self.out.writer(&buf);
        defer stdout.interface.flush() catch {};
        const type_label = switch (object_type) {
            .file => "file",
            .dir => "dir ",
            .unknown => "?   ",
        };
        stdout.interface.print("rename   {s}  {s}  ->  {s}\n", .{ type_label, src, dst }) catch return error.HandlerFailed;
    }

    fn wait_readable_cb(_: *nightwatch.Handler) error{HandlerFailed}!nightwatch.ReadableStatus {
        return .will_notify;
    }
};

fn run_linux(watcher: *nightwatch) !void {
    var fds = [_]std.posix.pollfd{
        .{ .fd = watcher.poll_fd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = sig_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        _ = try std.posix.poll(&fds, -1);
        if (fds[1].revents & std.posix.POLL.IN != 0) return; // signal
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            watcher.handle_read_ready() catch return;
        }
    }
}

fn run_posix() void {
    // Backend (kqueue) drives its own thread; we just block until signal.
    var buf: [1]u8 = undefined;
    _ = std.posix.read(sig_pipe[0], &buf) catch {};
}

var win_shutdown = std.atomic.Value(bool).init(false);

fn win_ctrl_handler(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    _ = ctrl_type;
    win_shutdown.store(true, .release);
    return std.os.windows.TRUE;
}

fn run_windows() void {
    const SetConsoleCtrlHandler = struct {
        extern "kernel32" fn SetConsoleCtrlHandler(
            HandlerRoutine: ?*const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
            Add: std.os.windows.BOOL,
        ) callconv(.winapi) std.os.windows.BOOL;
    }.SetConsoleCtrlHandler;
    _ = SetConsoleCtrlHandler(win_ctrl_handler, std.os.windows.TRUE);
    while (!win_shutdown.load(.acquire)) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn usage(out: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = out.writer(&buf);
    try writer.interface.print(
        \\Usage: nightwatch <path> [<path> ...]
        \\
        \\The Watch never sleeps.
        \\
        \\Events printed to stdout (columns: event  type  path):
        \\  create    a file or directory was created
        \\  modify    a file was modified
        \\  delete    a file or directory was deleted
        \\  rename    a file or directory was renamed
        \\
        \\Type column: file, dir, or ? (unknown)
        \\
        \\Stand down with Ctrl-C.
        \\
    , .{});
    try writer.interface.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try usage(std.fs.File.stderr());
        std.process.exit(1);
    }
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try usage(std.fs.File.stdout());
        return;
    }

    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    defer stderr.interface.flush() catch {};

    if (is_posix) {
        sig_pipe = try std.posix.pipe();
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = posix_sighandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    }
    defer if (is_posix) {
        std.posix.close(sig_pipe[0]);
        std.posix.close(sig_pipe[1]);
    };

    var cli_handler = CliHandler{
        .handler = .{ .vtable = &CliHandler.vtable },
        .out = std.fs.File.stdout(),
    };

    var watcher = try nightwatch.init(allocator, &cli_handler.handler);
    defer watcher.deinit();

    for (args[1..]) |path| {
        watcher.watch(path) catch |err| {
            try stderr.interface.print("nightwatch: {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        try stderr.interface.print("on watch: {s}\n", .{path});
    }

    if (nightwatch.linux_poll_mode) {
        try run_linux(&watcher);
    } else if (builtin.os.tag == .windows) {
        run_windows();
    } else if (is_posix) {
        run_posix();
    }
}

test "simple test" {}
