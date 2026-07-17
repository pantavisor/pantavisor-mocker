const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const exe = b.addExecutable(.{
        .name = "pantavisor-mocker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("vaxis", vaxis_mod);

    exe.addCSourceFile(.{ .file = b.path("src/net/curl_shim.c") });
    exe.linkLibC();
    exe.linkSystemLibrary("curl");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("vaxis", vaxis_mod);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addImport("app", app_mod);
    exe_unit_tests.addCSourceFile(.{ .file = b.path("src/net/curl_shim.c") });
    exe_unit_tests.linkLibC();
    exe_unit_tests.linkSystemLibrary("curl");

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // End-to-end tests: spawn the REAL binary and drive it from the outside
    // (CLI, storage dir, pv-ctrl socket, mock pantahub). No app code is linked
    // in — the binary path is injected so the tests exercise the shipped
    // artifact. Run with `zig build e2e`.
    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("mocker_bin", exe.getEmittedBin());
    e2e_tests.root_module.addOptions("build_options", e2e_options);

    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("e2e", "Run end-to-end tests against the real binary");
    e2e_step.dependOn(&run_e2e_tests.step);
}
