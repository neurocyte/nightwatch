const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const macos_fsevents = if (target.result.os.tag == .macos) blk: {
        break :blk b.option(
            bool,
            "macos_fsevents",
            "Enable the FSEvents backend for macOS (requires Xcode frameworks)",
        ) orelse false;
    } else false;

    const options = b.addOptions();
    options.addOption(bool, "macos_fsevents", macos_fsevents);
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

    var version: std.ArrayList(u8) = .empty;
    defer version.deinit(b.allocator);
    gen_version(b, version.writer(b.allocator)) catch |e| {
        if (b.release_mode != .off)
            std.debug.panic("gen_version failed: {any}", .{e});
        version.clearAndFree(b.allocator);
        version.appendSlice(b.allocator, "unknown") catch {};
    };
    const write_file_step = b.addWriteFiles();
    const version_file = write_file_step.add("version", version.items);

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

    if (b.option(bool, "install_tests", "Install the tests executable to the output directory") orelse false) {
        b.installArtifact(tests);
    }
}

fn gen_version(b: *std.Build, writer: anytype) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .Ignore);
    const diff_ = try b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .Ignore);
    const diff = std.mem.trimRight(u8, diff_, "\r\n ");
    const version = std.mem.trimRight(u8, describe, "\r\n ");

    try writer.print("{s}{s}", .{ version, if (diff.len > 0) "-dirty" else "" });
}
