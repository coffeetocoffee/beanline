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
        // Distinct name: the unit probe below installs as `test`, and both
        // would otherwise land in zig-out/bin as `test`.
        .name = "test-fuzz-tests",
    });
    fuzz_tests.root_module.addImport("beanline", beanline_mod);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_test_step = b.step("test-fuzz", "Run fuzz target unit tests");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    // Install-only counterpart of the probe step: compile the fuzz test binary
    // without running it, so CI can execute it directly. Same rationale as
    // `test-unit-probe` below — running a test binary through the Zig 0.14.1
    // build runner hangs on macos-14 arm64, while executing the binary
    // directly works there in seconds.
    const install_fuzz_tests = b.addInstallArtifact(fuzz_tests, .{});
    const test_fuzz_install_step = b.step("test-fuzz-install", "Install the fuzz test binary for direct runs");
    test_fuzz_install_step.dependOn(&install_fuzz_tests.step);

    // Progress-probing test runs: `zig build test-unit-probe` compiles the
    // unit tests and runs the test binary directly, bypassing the build
    // runner's `--listen` mediation, so the binary's own `N/M name...OK`
    // lines stream to the log as each test completes. If a platform hangs
    // in test, the last line names the culprit instead of dying silently
    // at the job timeout. The plain `test` step above stays the gate; the
    // probe is diagnostics only.
    const unit_probe = b.addTest(.{
        .root_source_file = b.path("src/beanline.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_probe = b.addInstallArtifact(unit_probe, .{});
    const test_unit_probe_step = b.step("test-unit-probe", "Install the unit test binary for direct streaming runs");
    test_unit_probe_step.dependOn(&install_probe.step);

    // Contract suite: one shared suite of assertions run against both backends.
    // Each case is written against the Broker interface so a backend change
    // that passes on one backend but not the other fails CI.
    const contract_mod = b.createModule(.{
        .root_source_file = b.path("tests/contract/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    contract_mod.addImport("beanline", beanline_mod);
    const contract_tests = b.addTest(.{
        .root_module = contract_mod,
        .name = "test-contract",
    });
    const run_contract_tests = b.addRunArtifact(contract_tests);
    const contract_test_step = b.step("test-contract", "Run the shared contract suite (requires a live backend)");
    contract_test_step.dependOn(&run_contract_tests.step);
    // Install-only counterpart so CI can run the binary directly (the Zig
    // 0.14.1 build runner hangs when executing test binaries on macOS).
    const install_contract_tests = b.addInstallArtifact(contract_tests, .{});
    const contract_test_install_step = b.step("test-contract-install", "Install the contract test binary for direct runs");
    contract_test_install_step.dependOn(&install_contract_tests.step);
}
