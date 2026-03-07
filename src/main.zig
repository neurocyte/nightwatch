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
        .wait_readable = if (builtin.os.tag == .linux) wait_readable_cb else {},
    };

    fn change_cb(h: *nightwatch.Handler, path: []const u8, event_type: nightwatch.EventType) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        var buf: [4096]u8 = undefined;
        var stdout = self.out.writer(&buf);
        defer stdout.interface.flush() catch {};
        const label = switch (event_type) {
            .created => "create ",
            .modified => "modify ",
            .deleted => "delete ",
            .dir_created => "mkdir  ",
            .renamed => "rename ",
        };
        stdout.interface.print("{s}  {s}\n", .{ label, path }) catch return error.HandlerFailed;
    }

    fn rename_cb(h: *nightwatch.Handler, src: []const u8, dst: []const u8) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        var buf: [4096]u8 = undefined;
        var stdout = self.out.writer(&buf);
        defer stdout.interface.flush() catch {};
        stdout.interface.print("rename   {s}  ->  {s}\n", .{ src, dst }) catch return error.HandlerFailed;
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

fn usage(out: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = out.writer(&buf);
    try writer.interface.print(
        \\Usage: nightwatch <path> [<path> ...]
        \\
        \\Watch files and directories for changes. Press Ctrl-C to stop.
        \\
        \\Events printed to stdout:
        \\  create    a file was created
        \\  modify    a file was modified
        \\  delete    a file or directory was deleted
        \\  mkdir     a directory was created
        \\  rename    a file or directory was renamed
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
        };
        try stderr.interface.print("watching: {s}\n", .{path});
    }

    if (builtin.os.tag == .linux) {
        try run_linux(&watcher);
    } else if (is_posix) {
        run_posix();
    }
}

test "simple test" {}
