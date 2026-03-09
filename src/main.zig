const std = @import("std");
const builtin = @import("builtin");
const nightwatch = @import("nightwatch");

const Watcher = switch (builtin.os.tag) {
    .linux => nightwatch.Create(.polling),
    else => nightwatch.Default,
};

const is_posix = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    .windows => false,
    else => @compileError("unsupported OS"),
};

// Self-pipe: signal handler writes a byte so poll() / read() unblocks cleanly.
var sig_pipe: if (is_posix) [2]std.posix.fd_t else void = undefined;

fn posix_sighandler(_: c_int) callconv(.c) void {
    _ = std.posix.write(sig_pipe[1], &[_]u8{0}) catch {};
}

const CliHandler = struct {
    handler: Watcher.Handler,
    out: std.fs.File,
    ignore: []const []const u8,

    const vtable: Watcher.Handler.VTable = switch (Watcher.interface_type) {
        .polling => .{
            .change = change_cb,
            .rename = rename_cb,
            .wait_readable = wait_readable_cb,
        },
        .threaded => .{
            .change = change_cb,
            .rename = rename_cb,
        },
    };

    fn change_cb(h: *Watcher.Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        for (self.ignore) |ignored| {
            if (std.mem.eql(u8, path, ignored)) return;
        }
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

    fn rename_cb(h: *Watcher.Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        for (self.ignore) |ignored| {
            if (std.mem.eql(u8, src, ignored) or std.mem.eql(u8, dst, ignored)) return;
        }
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

    fn wait_readable_cb(_: *Watcher.Handler) error{HandlerFailed}!Watcher.Handler.ReadableStatus {
        return .will_notify;
    }
};

fn run_linux(watcher: *Watcher) !void {
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
        \\Usage: nightwatch [--ignore <path>]... <path> [<path> ...]
        \\
        \\The Watch never sleeps.
        \\
        \\Options:
        \\  --ignore <path>   Suppress events whose path exactly matches <path>.
        \\                    May be specified multiple times.
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

    // Parse --ignore options and watch paths.
    // Ignored paths are made absolute (without resolving symlinks) so they
    // match the absolute paths the backend emits in event callbacks.
    var ignore_list = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (ignore_list.items) |p| allocator.free(p);
        ignore_list.deinit(allocator);
    }
    var watch_paths = std.ArrayListUnmanaged([]const u8){};
    defer watch_paths.deinit(allocator);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ignore")) {
            i += 1;
            if (i >= args.len) {
                try stderr.interface.print("nightwatch: --ignore requires an argument\n", .{});
                std.process.exit(1);
            }
            const raw = args[i];
            const abs = if (std.fs.path.isAbsolute(raw))
                try allocator.dupe(u8, raw)
            else
                try std.fs.path.join(allocator, &.{ cwd, raw });
            try ignore_list.append(allocator, abs);
        } else {
            try watch_paths.append(allocator, args[i]);
        }
    }

    if (watch_paths.items.len == 0) {
        try usage(std.fs.File.stderr());
        std.process.exit(1);
    }

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
        .ignore = ignore_list.items,
    };

    var watcher = switch (builtin.os.tag) {
        .linux => try nightwatch.Create(.polling).init(allocator, &cli_handler.handler),
        else => try nightwatch.Default.init(allocator, &cli_handler.handler),
    };

    defer watcher.deinit();

    for (watch_paths.items) |path| {
        watcher.watch(path) catch |err| {
            try stderr.interface.print("nightwatch: {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        try stderr.interface.print("on watch: {s}\n", .{path});
    }

    if (Watcher.interface_type == .polling) {
        try run_linux(&watcher);
    } else if (builtin.os.tag == .windows) {
        run_windows();
    } else if (is_posix) {
        run_posix();
    }
}

test "simple test" {}
