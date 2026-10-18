const std = @import("std");

pub const Args = struct {
    to: []const u8,
    subject: []const u8,
};

pub const Context = struct {
    job_id: i64,
    lease_epoch: u64,
    attempt: u8,
    alloc: std.mem.Allocator,

    /// Set by the runtime on cancel/timeout; handlers must poll and return.
    stop_flag: ?*const std.atomic.Value(bool) = null,
    deadline_ms: i64 = 0,

    /// True once the runtime asked this execution to stop (cancel or timeout).
    /// Cooperative: infinite handlers only stop if they poll this.
    pub fn stopped(self: *const Context) bool {
        if (self.stop_flag) |f| {
            if (f.load(.seq_cst)) return true;
        }
        return self.deadline_ms != 0 and std.time.milliTimestamp() > self.deadline_ms;
    }
};

pub const Handle = *const fn (ctx: *Context, args: Args) anyerror!void;

pub const Job = struct {
    name: []const u8,
    queue: []const u8 = "default",
    max_attempts: u8 = 25,
    /// Cooperative per-execution deadline; 0 disables.
    timeout_ms: u32 = 0,
    handle: Handle,
};
