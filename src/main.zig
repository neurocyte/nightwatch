const std = @import("std");
const builtin = @import("builtin");
const nightwatch = @import("nightwatch");
const build_options = @import("build_options");

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

fn posix_sighandler(_: std.posix.SIG) callconv(.c) void {
    _ = std.posix.system.write(sig_pipe[1], &[_]u8{0}, 1);
}

const CliHandler = struct {
    handler: Watcher.Handler,
    io: std.Io,
    out: std.Io.File,
    tty_mode: std.Io.Terminal.Mode,
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
        var w = std.Io.File.writer(self.out, self.io, &buf);
        defer w.flush() catch {};
        const color: std.Io.Terminal.Color = switch (event_type) {
            .created => .green,
            .modified => .blue,
            .closed => .bright_black,
            .deleted => .red,
        };
        const event_label = switch (event_type) {
            .created => "create ",
            .modified => "modify ",
            .closed => "close  ",
            .deleted => "delete ",
        };
        const tty = std.Io.Terminal{ .writer = &w.interface, .mode = self.tty_mode };
        tty.setColor(color) catch return error.HandlerFailed;
        w.interface.writeAll(event_label) catch return error.HandlerFailed;
        tty.setColor(.reset) catch return error.HandlerFailed;
        w.interface.writeAll("  ") catch return error.HandlerFailed;
        self.writeTypeLabel(&w.interface, object_type) catch return error.HandlerFailed;
        w.interface.print("  {s}\n", .{path}) catch return error.HandlerFailed;
    }

    fn rename_cb(h: *Watcher.Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *CliHandler = @fieldParentPtr("handler", h);
        for (self.ignore) |ignored| {
            if (std.mem.eql(u8, src, ignored) or std.mem.eql(u8, dst, ignored)) return;
        }
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.writer(self.out, self.io, &buf);
        defer w.flush() catch {};
        const tty = std.Io.Terminal{ .writer = &w.interface, .mode = self.tty_mode };
        tty.setColor(.magenta) catch return error.HandlerFailed;
        w.interface.writeAll("rename ") catch return error.HandlerFailed;
        tty.setColor(.reset) catch return error.HandlerFailed;
        w.interface.writeAll("  ") catch return error.HandlerFailed;
        self.writeTypeLabel(&w.interface, object_type) catch return error.HandlerFailed;
        w.interface.print("  {s}  ->  {s}\n", .{ src, dst }) catch return error.HandlerFailed;
    }

    fn writeTypeLabel(self: *CliHandler, w: *std.Io.Writer, object_type: nightwatch.ObjectType) !void {
        const tty = std.Io.Terminal{ .writer = w, .mode = self.tty_mode };
        switch (object_type) {
            .file => {
                try tty.setColor(.cyan);
                try w.writeAll("file");
                try tty.setColor(.reset);
            },
            .dir => {
                try tty.setColor(.yellow);
                try w.writeAll("dir ");
                try tty.setColor(.reset);
            },
            .unknown => try w.writeAll("?   "),
        }
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
    return .TRUE;
}

fn run_windows(io: std.Io) void {
    const SetConsoleCtrlHandler = struct {
        extern "kernel32" fn SetConsoleCtrlHandler(
            HandlerRoutine: ?*const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
            Add: std.os.windows.BOOL,
        ) callconv(.winapi) std.os.windows.BOOL;
    }.SetConsoleCtrlHandler;
    _ = SetConsoleCtrlHandler(win_ctrl_handler, .TRUE);
    while (!win_shutdown.load(.acquire)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
}

fn usage(io: std.Io, out: std.Io.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.writer(out, io, &buf);
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
        \\  close     a file was closed after writing (Linux only)
        \\  delete    a file or directory was deleted or moved out
        \\  rename    a file or directory was renamed (Linux/Windows only, src -> dst)
        \\
        \\Type column: file, dir, or ? (unknown)
        \\
        \\Stand down with Ctrl-C.
        \\
    , .{});
    try writer.flush();
}

fn version(io: std.Io, out: std.Io.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.writer(out, io, &buf);
    try writer.interface.print(
        \\nightwatch version {s}
        \\using: {s}
        \\
    , .{
        @embedFile("version"),
        @typeName(get_nightwatch().Backend),
    });
    try writer.flush();
}

fn get_nightwatch() type {
    return switch (builtin.os.tag) {
        .linux => nightwatch.Create(.polling),
        else => nightwatch.Default,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try usage(init.io, std.Io.File.stderr());
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try usage(init.io, std.Io.File.stdout());
        return;
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        try version(init.io, std.Io.File.stdout());
        return;
    }

    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.writer(std.Io.File.stderr(), init.io, &buf);
    defer stderr.flush() catch {};
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.writer(std.Io.File.stdout(), init.io, &out_buf);
    defer stdout.flush() catch {};

    // Parse --ignore options and watch paths.
    // Ignored paths are made absolute (without resolving symlinks) so they
    // match the absolute paths the backend emits in event callbacks.
    var ignore_list = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (ignore_list.items) |p| allocator.free(p);
        ignore_list.deinit(allocator);
    }
    var watch_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer watch_paths.deinit(allocator);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(init.io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

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
        try usage(init.io, std.Io.File.stderr());
        std.process.exit(1);
    }

    if (is_posix) {
        sig_pipe = try std.Io.Threaded.pipe2(.{});
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = posix_sighandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    }
    defer if (is_posix) {
        std.Io.Threaded.closeFd(sig_pipe[0]);
        std.Io.Threaded.closeFd(sig_pipe[1]);
    };

    const NO_COLOR = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;
    const CLICOLOR_FORCE = if (init.environ_map.get("CLICOLOR_FORCE")) |v| v.len > 0 else false;
    const tty_mode = std.Io.Terminal.Mode.detect(init.io, std.Io.File.stdout(), NO_COLOR, CLICOLOR_FORCE) catch .no_color;

    var cli_handler = CliHandler{
        .handler = .{ .vtable = &CliHandler.vtable },
        .out = std.Io.File.stdout(),
        .tty_mode = tty_mode,
        .io = init.io,
        .ignore = ignore_list.items,
    };

    var watcher = try get_nightwatch().init(init.io, allocator, &cli_handler.handler);

    defer watcher.deinit();

    for (watch_paths.items) |path| {
        watcher.watch(path) catch |err| {
            try stderr.interface.print("nightwatch: {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        (std.Io.Terminal{ .writer = &stdout.interface, .mode = tty_mode }).setColor(.dim) catch {};
        try stdout.interface.print("# on watch: {s}", .{path});
        (std.Io.Terminal{ .writer = &stdout.interface, .mode = tty_mode }).setColor(.reset) catch {};
        try stdout.interface.print("\n", .{});
        try stdout.flush();
    }

    if (Watcher.interface_type == .polling) {
        try run_linux(&watcher);
    } else if (builtin.os.tag == .windows) {
        run_windows(init.io);
    } else if (is_posix) {
        run_posix();
    }
}
