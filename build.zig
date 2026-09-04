const std = @import("std");
const package = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseSafe (the shipped configuration); -Doptimize=<mode>
    // or --release=<mode> still overrides. Debug builds also hit the GCC-16
    // crt1.o/sframe link bug on newer toolchains, so tests default to
    // ReleaseSafe too.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .fast => std.builtin.OptimizeMode.ReleaseFast,
        .small => std.builtin.OptimizeMode.ReleaseSmall,
        else => std.builtin.OptimizeMode.ReleaseSafe,
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "cli_version", package.version);

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
    exe.root_module.addOptions("build_options", build_options);

    exe.addCSourceFile(.{ .file = b.path("src/net/curl_shim.c") });
    exe.linkLibC();
    exe.linkSystemLibrary("curl");

    // Cross-compiling against system libcurl: Debian multiarch installs the
    // target arch's headers/libs under /usr/include/<triplet> and
    // /usr/lib/<triplet>; point zig at them for -Dtarget=... cross builds.
    const cross_include_dir = b.option([]const u8, "cross-include-dir", "Target-arch C header dir (e.g. /usr/include/aarch64-linux-gnu)");
    const cross_lib_dir = b.option([]const u8, "cross-lib-dir", "Target-arch library dir (e.g. /usr/lib/aarch64-linux-gnu)");
    if (cross_include_dir) |dir| exe.root_module.addIncludePath(.{ .cwd_relative = dir });
    if (cross_lib_dir) |dir| exe.root_module.addLibraryPath(.{ .cwd_relative = dir });

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
    app_mod.addOptions("build_options", build_options);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The curl shim belongs to the app module itself so every test binary that
    // imports it (runner below, and the app's own tests) links it exactly once.
    app_mod.addCSourceFile(.{ .file = b.path("src/net/curl_shim.c") });
    app_mod.link_libc = true;
    app_mod.linkSystemLibrary("curl", .{});
    exe_unit_tests.root_module.addImport("app", app_mod);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Tests declared inside src/ live in the "app" module; Zig only collects
    // tests from a test compilation's root module, so they need their own
    // test binary rooted at src/main.zig.
    const app_unit_tests = b.addTest(.{ .root_module = app_mod });
    const run_app_unit_tests = b.addRunArtifact(app_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_app_unit_tests.step);

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
