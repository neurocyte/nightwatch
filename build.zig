const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_fsevents = if (target.result.os.tag == .macos) blk: {
        break :blk b.option(
            bool,
            "use_fsevents",
            "Use the FSEvents backend on macOS instead of kqueue (requires Xcode frameworks)",
        ) orelse false;
    } else false;

    const linux_read_thread = if (target.result.os.tag == .linux) blk: {
        break :blk b.option(
            bool,
            "linux_read_thread",
            "Use a background thread on Linux (like macOS/Windows) instead of requiring the caller to drive the event loop via poll_fd/handle_read_ready",
        ) orelse false;
    } else false;

    const options = b.addOptions();
    options.addOption(bool, "use_fsevents", use_fsevents);
    options.addOption(bool, "linux_read_thread", linux_read_thread);
    const options_mod = options.createModule();

    const mod = b.addModule("nightwatch", .{
        .root_source_file = b.path("src/nightwatch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    if (use_fsevents) {
        const xcode_frameworks = b.lazyDependency("xcode-frameworks", .{}) orelse return;
        mod.addSystemFrameworkPath(xcode_frameworks.path("Frameworks"));
        mod.addLibraryPath(xcode_frameworks.path("lib"));
        mod.linkFramework("CoreServices", .{});
        mod.linkFramework("CoreFoundation", .{});
    }

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

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args|
        run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{
        .name = "mod_tests",
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .name = "exe_tests",
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
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Integration test suite: exercises the public API by performing real
    // filesystem operations and verifying Handler callbacks via TestHandler.
    const integration_tests = b.addTest(.{
        .name = "integration_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nightwatch_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nightwatch", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    b.installArtifact(mod_tests);
    b.installArtifact(exe_tests);
    b.installArtifact(integration_tests);
}
