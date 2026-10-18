const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module so tests (library + fuzz targets) can import the public
    // surface without reaching outside their own module path.
    const beanline_mod = b.addModule("beanline", .{
        .root_source_file = b.path("src/beanline.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The fuzz exes get their own copy of the library compiled in ReleaseSafe
    // so the memory checks that catch bugs are actually enabled.
    const beanline_fuzz_mod = b.addModule("beanline-fuzz", .{
        .root_source_file = b.path("src/beanline.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });

    const exe = b.addExecutable(.{
        .name = "beanline",
        .root_source_file = b.path("src/beanline.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const lib = b.addStaticLibrary(.{
        .name = "beanline",
        .root_source_file = b.path("src/beanline.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the beanline CLI");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/beanline.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Fuzz targets. Each is also a normal executable so the harness can drive
    // it deterministically (see tests/fuzz/harness.zig for why this is not
    // std.testing.fuzz yet).
    const fuzz_targets = [_][]const u8{
        "resp_decode",
        "cron_parse",
        "args_json",
    };
    const fuzz_step = b.step("fuzz", "Run the deterministic fuzz targets");
    const gate_step = b.step("fuzz-gate", "Run the fuzz targets in CI-sized mode");
    for (fuzz_targets) |name| {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/fuzz/{s}.zig", .{name})),
            .target = target,
            // ReleaseSafe keeps the checks that turn a memory bug into a gate
            // failure instead of silent corruption.
            .optimize = .ReleaseSafe,
        });
        fuzz_mod.addImport("beanline", beanline_fuzz_mod);
        const fuzz_exe = b.addExecutable(.{
            .name = b.fmt("fuzz-{s}", .{name}),
            .root_module = fuzz_mod,
        });
        const run = b.addRunArtifact(fuzz_exe);
        if (b.args) |args| run.addArgs(args);
        fuzz_step.dependOn(&run.step);

        const gate_run = b.addRunArtifact(fuzz_exe);
        gate_run.addArgs(&.{ "--iterations", "20000" });
        gate_step.dependOn(&gate_run.step);
    }

    // Unit tests for the fuzz targets themselves (parsing + regression cases).
    const fuzz_tests = b.addTest(.{
        .root_source_file = b.path("tests/fuzz/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_tests.root_module.addImport("beanline", beanline_mod);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_test_step = b.step("test-fuzz", "Run fuzz target unit tests");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
}
