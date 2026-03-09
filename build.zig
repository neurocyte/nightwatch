const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const macos_fsevents = if (target.result.os.tag == .macos) blk: {
        break :blk b.option(
            bool,
            "macos_fsevents",
            "Add the FSEvents backend on macOS (requires Xcode frameworks)",
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

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nightwatch", .module = mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });

    // Integration test suite: exercises the public API by performing real
    // filesystem operations and verifying Handler callbacks via TestHandler.
    // Also imports nightwatch.zig (via the nightwatch module) and main.zig so
    // any tests added there are included automatically.
    const integration_tests = b.addTest(.{
        .name = "integration_tests",
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
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_integration_tests.step);

    b.installArtifact(integration_tests);
}
