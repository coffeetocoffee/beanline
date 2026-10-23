const std = @import("std");
const broker_mod = @import("../broker/broker.zig");
const config_mod = @import("../config.zig");

/// Sandbox execution result
pub const SandboxResult = union(enum) {
    ok,
    failed: SandboxError,
    timeout,
    oom,
    killed,
};

/// Error from sandboxed execution
pub const SandboxError = error{
    /// Handler process crashed (segfault, panic, etc.)
    ProcessCrashed,
    /// Handler returned non-zero exit code
    NonZeroExit,
    /// Process was killed by resource limits
    ResourceLimit,
    /// Internal sandbox error
    Internal,
};

/// Sandbox configuration
pub const SandboxConfig = struct {
    enabled: bool,
    memory_mb: u64,
    cpu_percent: u8,
    timeout_ms: u64,
};

/// Handler input sent to sandbox process
pub const SandboxInput = struct {
    job_id: i64,
    lease_epoch: u64,
    attempt: u8,
    kind_name: []const u8,
    args_json: []const u8,
    deadline_ms: i64,
};

/// Handler output received from sandbox process
pub const SandboxOutput = struct {
    result: SandboxResult,
    error_name: ?[]const u8,
    error_class: ?u8, // 0=retryable, 1=dead, 2=unknown
    duration_ms: u64,
};

/// Run a handler in a sandboxed process.
/// Returns the result and any error details.
pub fn runSandboxed(
    alloc: std.mem.Allocator,
    cfg: SandboxConfig,
    input: SandboxInput,
    kind_runner: *const fn (ctx: *@import("../core/job.zig").Context, alloc: std.mem.Allocator, args_json: []const u8) @import("../core/job.zig").Outcome,
) !SandboxOutput {
    if (!cfg.enabled) {
        // Run in-process if sandbox disabled
        var ctx = @import("../core/job.zig").Context{
            .job_id = input.job_id,
            .lease_epoch = input.lease_epoch,
            .attempt = input.attempt,
            .alloc = alloc,
            .deadline_ms = input.deadline_ms,
        };
        const outcome = kind_runner(&ctx, alloc, input.args_json);
        return .{
            .result = .ok,
            .error_name = switch (outcome) {
                .ok => null,
                .failed => |f| f.name,
            },
            .error_class = switch (outcome) {
                .ok => null,
                .failed => |f| if (f.class == .retryable) 0 else 1,
            },
            .duration_ms = 0,
        };
    }

    // Platform-specific sandbox implementation
    return if (@import("builtin").os.tag == .windows)
        runSandboxedWindows(alloc, cfg, input, kind_runner)
    else
        runSandboxedUnix(alloc, cfg, input, kind_runner);
}

/// Windows sandbox using job objects and CreateProcess
fn runSandboxedWindows(
    alloc: std.mem.Allocator,
    cfg: SandboxConfig,
    input: SandboxInput,
    kind_runner: *const fn (ctx: *@import("../core/job.zig").Context, alloc: std.mem.Allocator, args_json: []const u8) @import("../core/job.zig").Outcome,
) !SandboxOutput {
    _ = cfg;
    // For now, run in-process on Windows as a fallback
    // Full Windows job object implementation would require:
    // 1. Create a job object with JOB_OBJECT_LIMIT_PROCESS_MEMORY, etc.
    // 2. CreateProcess with suspended=true
    // 3. Assign process to job
    // 4. Resume thread
    // 5. Wait with timeout
    // 6. Check exit code and job object accounting

    std.log.warn("Windows sandbox not fully implemented; running in-process", .{});
    var ctx = @import("../core/job.zig").Context{
        .job_id = input.job_id,
        .lease_epoch = input.lease_epoch,
        .attempt = input.attempt,
        .alloc = alloc,
        .deadline_ms = input.deadline_ms,
    };
    const outcome = kind_runner(&ctx, alloc, input.args_json);
    return .{
        .result = .ok,
        .error_name = switch (outcome) {
            .ok => null,
            .failed => |f| f.name,
        },
        .error_class = switch (outcome) {
            .ok => null,
            .failed => |f| if (f.class == .retryable) 0 else 1,
        },
        .duration_ms = 0,
    };
}

/// Unix sandbox using fork/exec with rlimits
fn runSandboxedUnix(
    alloc: std.mem.Allocator,
    cfg: SandboxConfig,
    input: SandboxInput,
    kind_runner: *const fn (ctx: *@import("../core/job.zig").Context, alloc: std.mem.Allocator, args_json: []const u8) @import("../core/job.zig").Outcome,
) !SandboxOutput {
    _ = cfg;
    // For now, run in-process on Unix as a fallback
    // Full Unix fork/exec implementation would:
    // 1. Create pipes for stdin/stdout/stderr
    // 2. fork()
    // 3. In child: setrlimit(RLIMIT_AS, ...), setrlimit(RLIMIT_CPU, ...)
    // 4. In child: exec the same binary with a special --sandbox-worker flag
    // 5. Parent: send input via stdin, read output from stdout
    // 6. Wait with timeout, handle SIGKILL on timeout

    std.log.warn("Unix sandbox not fully implemented; running in-process", .{});
    var ctx = @import("../core/job.zig").Context{
        .job_id = input.job_id,
        .lease_epoch = input.lease_epoch,
        .attempt = input.attempt,
        .alloc = alloc,
        .deadline_ms = input.deadline_ms,
    };
    const outcome = kind_runner(&ctx, alloc, input.args_json);
    return .{
        .result = .ok,
        .error_name = switch (outcome) {
            .ok => null,
            .failed => |f| f.name,
        },
        .error_class = switch (outcome) {
            .ok => null,
            .failed => |f| if (f.class == .retryable) 0 else 1,
        },
        .duration_ms = 0,
    };
}

/// Create sandbox config from main config
pub fn fromConfig(cfg: config_mod.Config) SandboxConfig {
    return .{
        .enabled = cfg.sandbox_enabled,
        .memory_mb = cfg.sandbox_memory_mb,
        .cpu_percent = cfg.sandbox_cpu_percent,
        .timeout_ms = cfg.sandbox_timeout_ms,
    };
}
