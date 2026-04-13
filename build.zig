const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const install_tests = b.option(bool, "install_tests", "Install the tests executable to the output directory") orelse false;
    const macos_fsevents = if (target.result.os.tag == .macos) blk: {
        const macos_fsevents = b.option(
            bool,
            "macos_fsevents",
            "Enable the FSEvents backend for macOS (requires Xcode frameworks)",
        ) orelse false;
        options.addOption(bool, "macos_fsevents", macos_fsevents);
        break :blk macos_fsevents;
    } else false;
    options.addOption(bool, "install_tests", install_tests);
    const options_mod = options.createModule();

    const mod = b.addModule("nightwatch", .{
        .root_source_file = b.path("src/nightwatch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    if (macos_fsevents) {
        const xcode_frameworks = b.lazyDependency("xcode-frameworks", .{}) orelse return;
        mod.addSystemFrameworkPath(xcode_frameworks.path("Frameworks"));
        mod.addLibraryPath(xcode_frameworks.path("lib"));
        mod.linkFramework("CoreServices", .{});
        mod.linkFramework("CoreFoundation", .{});
    }

    var version: std.Io.Writer.Allocating = .init(b.allocator);
    defer version.deinit();
    gen_version(b, &version.writer) catch |e| {
        if (b.release_mode != .off)
            std.debug.panic("gen_version failed: {any}", .{e});
        version.writer.writeAll("unknown") catch {};
    };
    const write_file_step = b.addWriteFiles();
    const version_file = write_file_step.add("version", version.written());

    const exe = b.addExecutable(.{
        .name = "nightwatch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nightwatch", .module = mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    exe.root_module.addImport("version", b.createModule(.{ .root_source_file = version_file }));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args|
        run_cmd.addArgs(args);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nightwatch", .module = mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nightwatch_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nightwatch", .module = mod },
                .{ .name = "main", .module = main_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    if (install_tests) {
        b.installArtifact(tests);
    }
}

fn gen_version(b: *std.Build, writer: *std.Io.Writer) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .ignore);
    const diff_ = try b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .ignore);
    const diff = std.mem.trimEnd(u8, diff_, "\r\n ");
    const version = std.mem.trimEnd(u8, describe, "\r\n ");

    try writer.print("{s}{s}", .{ version, if (diff.len > 0) "-dirty" else "" });
}
