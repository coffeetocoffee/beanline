const std = @import("std");
const broker_mod = @import("../broker/broker.zig");
const registry_mod = @import("../core/registry.zig");
const backoff_mod = @import("backoff.zig");
const pool_mod = @import("pool.zig");
const metrics_mod = @import("../obs/metrics.zig");
const limiter_mod = @import("limiter.zig");
const fairness_mod = @import("fairness.zig");
const job_mod = @import("../core/job.zig");
const sandbox_mod = @import("sandbox.zig");

const Broker = broker_mod.Broker;
const Claimed = broker_mod.Claimed;
const Registry = registry_mod.Registry;

pub const QueueConfig = struct {
    name: []const u8,
    concurrency: u32 = 4,
    weight: u32 = 1,
    rate_per_s: f64 = 0,
    lease_ms: u64 = 30_000,
    /// Enable sandbox mode for this queue (runs handlers in isolated processes)
    sandbox_enabled: bool = false,
    sandbox_memory_mb: u64 = 256,
    sandbox_cpu_percent: u8 = 50,
    sandbox_timeout_ms: u64 = 30_000,
};

pub const Options = struct {
    queues: []const QueueConfig,
    worker_name: []const u8 = "beanline",
    /// Backoff for kinds that do not declare their own.
    retry: backoff_mod.Backoff = .{},
    /// Optional metrics sink for the duration and end-to-end histograms.
    metrics: ?*metrics_mod.Metrics = null,
    /// Global sandbox settings (can be overridden per-queue)
    sandbox_enabled: bool = false,
    sandbox_memory_mb: u64 = 256,
    sandbox_cpu_percent: u8 = 50,
    sandbox_timeout_ms: u64 = 30_000,
};

// A claimed job handed to the pool. All bookkeeping happens on the runtime
// thread ("owner"): pool threads only run the handler.
pub const Dispatch = struct {
    owner: *Owner,
    queue_idx: usize,
    id: i64,
    epoch: u64,
    attempts: u32,
    args_json: []u8,
    /// The kind's resolved policy: payload schema, error classification and
    /// backoff all live here.
    entry: registry_mod.Entry,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    outcome: job_mod.Outcome = .ok,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deadline_ms: i64 = 0,
    was_stopped: bool = false,
    /// Set at dispatch so completion can be timed without extra bookkeeping.
    started_ms: i64 = 0,
    kind: []const u8 = "",

    fn run(self: *Dispatch) void {
        const owner = self.owner;
        const sandbox_cfg = owner.sandbox_cfgs[self.queue_idx];
        
        if (sandbox_cfg.enabled) {
            // Run in sandbox
            const input = sandbox_mod.SandboxInput{
                .job_id = self.id,
                .lease_epoch = self.epoch,
                .attempt = @intCast(@min(self.attempts, 255)),
                .kind_name = self.kind,
                .args_json = self.args_json,
                .deadline_ms = self.deadline_ms,
            };
            const sandbox_result = sandbox_mod.runSandboxed(
                owner.alloc,
                sandbox_cfg,
                input,
                self.entry.runner,
            ) catch |e| {
                std.log.warn("sandbox error id={d}: {s}", .{ self.id, @errorName(e) });
                self.outcome = .{ .failed = .{ .class = .dead, .name = "SandboxError" } };
                self.done.store(true, .release);
                return;
            };
            
            self.outcome = switch (sandbox_result.result) {
                .ok => .ok,
                .failed => .{ .failed = .{
                    .class = if (sandbox_result.error_class.? == 0) .retryable else .dead,
                    .name = if (sandbox_result.error_name) |n| n else "SandboxError",
                } },
                .timeout => .{ .failed = .{ .class = .dead, .name = "SandboxTimeout" } },
                .oom => .{ .failed = .{ .class = .dead, .name = "SandboxOOM" } },
                .killed => .{ .failed = .{ .class = .dead, .name = "SandboxKilled" } },
            };
            self.was_stopped = false;
            self.done.store(true, .release);
            return;
        }
        
        // Run in-process (no sandbox)
        var ctx = job_mod.Context{
            .job_id = self.id,
            .lease_epoch = self.epoch,
            .attempt = @intCast(@min(self.attempts, 255)),
            .alloc = owner.alloc,
            .stop_flag = &self.stop,
            .deadline_ms = self.deadline_ms,
        };
        // The kind's own runner decodes the payload into the kind's argument
        // type and classifies the handler's error. The runtime does neither.
        self.outcome = self.entry.runner(&ctx, owner.alloc, self.args_json);
        self.was_stopped = ctx.stopped();
        self.done.store(true, .release);
    }

    fn taskFn(ptr: *anyopaque) void {
        const self: *Dispatch = @ptrCast(@alignCast(ptr));
        self.run();
    }
};

pub const Owner = struct {
    alloc: std.mem.Allocator,
    broker: Broker,
    reg: *Registry,
    pool: *pool_mod.Pool,
    cfgs: []const QueueConfig,
    worker_name: []const u8,
    fair: fairness_mod.Scheduler = .{},
    limiters: []limiter_mod.Limiter = &.{},
    running: std.ArrayListUnmanaged(*Dispatch) = .{},
    free_slots: std.ArrayListUnmanaged(usize) = .{},
    stop: bool = false,
    next_hb_ms: i64 = 0,
    /// Backoff used by kinds that do not declare their own.
    default_retry: backoff_mod.Backoff,
    items: [64]Claimed = undefined,
    metrics: ?*metrics_mod.Metrics,
    /// Sandbox config (per-queue, with global fallback)
    sandbox_cfgs: []sandbox_mod.SandboxConfig,

    pub fn init(alloc: std.mem.Allocator, broker: Broker, reg: *Registry, pool: *pool_mod.Pool, opts: Options) !Owner {
        const lims = try alloc.alloc(limiter_mod.Limiter, opts.queues.len);
        for (opts.queues, 0..) |q, i| lims[i] = limiter_mod.Limiter.init(q.rate_per_s, 8, std.time.milliTimestamp());
        
        // Build sandbox configs per queue
        var sandbox_cfgs = try alloc.alloc(sandbox_mod.SandboxConfig, opts.queues.len);
        for (opts.queues, 0..) |q, i| {
            sandbox_cfgs[i] = .{
                .enabled = opts.sandbox_enabled or q.sandbox_enabled,
                .memory_mb = if (q.sandbox_memory_mb != 0) q.sandbox_memory_mb else opts.sandbox_memory_mb,
                .cpu_percent = if (q.sandbox_cpu_percent != 0) q.sandbox_cpu_percent else opts.sandbox_cpu_percent,
                .timeout_ms = if (q.sandbox_timeout_ms != 0) q.sandbox_timeout_ms else opts.sandbox_timeout_ms,
            };
        }

        var self = Owner{
            .alloc = alloc,
            .broker = broker,
            .reg = reg,
            .pool = pool,
            .cfgs = opts.queues,
            .worker_name = opts.worker_name,
            .default_retry = opts.retry,
            .limiters = lims,
            .metrics = opts.metrics,
            .sandbox_cfgs = sandbox_cfgs,
        };
        var weights: [fairness_mod.MAX_QUEUES]u32 = [_]u32{1} ** fairness_mod.MAX_QUEUES;
        for (opts.queues, 0..) |q, i| if (q.weight != 0) {
            weights[i] = q.weight;
        };
        self.fair.setWeights(weights[0..opts.queues.len]);
        return self;
    }

    pub fn deinit(self: *Owner) void {
        self.alloc.free(self.limiters);
        self.alloc.free(self.sandbox_cfgs);
        self.free_slots.deinit(self.alloc);
        self.running.deinit(self.alloc);
    }

    pub fn inflight(self: *const Owner) usize {
        return self.running.items.len;
    }

    pub fn signalStop(self: *Owner) void {
        self.stop = true;
    }

    /// Ask a running execution to stop and mark the job cancelled. If the job
    /// is not inflight it is cancelled at the broker (queued/scheduled jobs).
    pub fn cancel(self: *Owner, id: i64) !void {
        var qname: ?[]const u8 = null;
        var epoch: u64 = 0;
        for (self.running.items) |d| {
            if (d.id == id) {
                qname = self.cfgs[d.queue_idx].name;
                epoch = d.epoch;
                d.stop.store(true, .seq_cst);
                break;
            }
        }
        if (qname) |q| {
            self.broker.cancel(q, id, epoch) catch |e| {
                std.log.warn("cancel id={d}: {s}", .{ id, @errorName(e) });
            };
        } else {
            for (self.cfgs) |q| {
                self.broker.cancel(q.name, id, null) catch continue;
            }
        }
    }

    /// Cooperative timeouts: flip the stop flag on executions past deadline.
    fn scanTimeouts(self: *Owner, now_ms: i64) void {
        for (self.running.items) |d| {
            if (d.deadline_ms != 0 and now_ms > d.deadline_ms and !d.done.load(.acquire)) {
                d.stop.store(true, .seq_cst);
            }
        }
    }

    // One scheduling round: reap completions, renew leases, fair-claim and
    // dispatch. Returns the number of jobs claimed this round.
    pub fn tick(self: *Owner, now_ms: i64) anyerror!usize {
        try self.processDone();
        if (now_ms >= self.next_hb_ms) self.heartbeat(now_ms);
        self.scanTimeouts(now_ms);
        if (self.stop) return 0;

        self.free_slots.clearRetainingCapacity();
        for (self.cfgs, 0..) |q, i| {
            const used = self.countRunning(i);
            if (q.concurrency > used) try self.free_slots.append(self.alloc, i);
        }
        var claimed: usize = 0;
        var rounds: usize = 0;
        while (self.free_slots.items.len > 0 and rounds <= self.cfgs.len * 2) : (rounds += 1) {
            var flags = [_]bool{false} ** fairness_mod.MAX_QUEUES;
            for (self.free_slots.items) |idx| flags[idx] = true;
            const qi = (self.fair.pick(&flags) orelse break);
            const q = self.cfgs[qi];
            const used = self.countRunning(qi);
            const used_i: i64 = @intCast(used);
            const conc_i: i64 = @intCast(q.concurrency);
            var budget: u32 = @intCast(@max(conc_i - used_i, 0));
            if (self.limiters[qi].rate_per_s > 0) {
                const tokens: u32 = @intFromFloat(@max(0, @min(self.limiters[qi].tokens, 100000)));
                budget = @min(budget, tokens);
            }
            if (budget == 0) {
                if (self.limiters[qi].rate_per_s > 0 and used < q.concurrency) {
                    // rate limited: skip this round entirely
                    return claimed;
                }
                self.removeSlot(qi);
                continue;
            }
            if (budget > self.items.len) budget = @intCast(self.items.len);
            const n = try self.broker.claim(q.name, budget, self.worker_name, q.lease_ms, self.items[0..budget]);
            for (self.items[0..n]) |c| {
                _ = self.limiters[qi].tryAcquire(now_ms);
                try self.dispatchOrUpdate(c, qi, now_ms);
            }
            claimed += n;
            if (n < budget) self.removeSlot(qi); // queue drained; fairness moves on
        }
        return claimed;
    }

    fn dispatchOrUpdate(self: *Owner, c: Claimed, qi: usize, now_ms: i64) anyerror!void {
        const entry = self.reg.get(c.kind) orelse {
            // Unknown kind: never retry, straight to dead.
            var out = broker_mod.FailOutcome{};
            self.broker.fail(self.cfgs[qi].name, c.id, c.lease_epoch, "unknown_kind", .{ .non_retryable = {} }, &out) catch |e| {
                std.log.warn("unknown_kind fail id={d}: {s}", .{ c.id, @errorName(e) });
            };
            return;
        };
        const d = try self.alloc.create(Dispatch);
        d.* = .{
            .owner = self,
            .queue_idx = qi,
            .id = c.id,
            .epoch = c.lease_epoch,
            .attempts = c.attempts,
            .args_json = try self.alloc.dupe(u8, c.args_json),
            .entry = entry,
            .deadline_ms = if (entry.timeout_ms == 0) 0 else now_ms + @as(i64, @intCast(entry.timeout_ms)),
            .started_ms = now_ms,
            .kind = entry.name,
        };
        try self.pool.submit(.{ .ptr = d, .run = Dispatch.taskFn });
        try self.running.append(self.alloc, d);
    }

    fn processDone(self: *Owner) anyerror!void {
        if (self.running.items.len == 0) return;
        var i: usize = 0;
        while (i < self.running.items.len) {
            const d = self.running.items[i];
            if (!d.done.load(.acquire)) {
                i += 1;
                continue;
            }
            const qname = self.cfgs[d.queue_idx].name;
            const stopped = d.stop.load(.acquire) or d.was_stopped;
            if (self.metrics) |mx| recordOutcome(mx, d, stopped);
            switch (d.outcome) {
                .ok => {
                    if (stopped) {
                        // Cancelled/timeout: mark cancelled instead of completed.
                        self.broker.cancel(qname, d.id, d.epoch) catch |e| {
                            std.log.warn("cancel on stop id={d}: {s}", .{ d.id, @errorName(e) });
                        };
                    } else {
                        self.broker.finish(qname, d.id, d.epoch) catch |e| {
                            // Lease was taken over or job got cancelled: log and drop.
                            std.log.warn("fencing: finish id={d} epoch={d} got {s}", .{ d.id, d.epoch, @errorName(e) });
                        };
                    }
                },
                .failed => try self.reportFailure(d, qname),
            }
            self.alloc.free(d.args_json);
            self.alloc.destroy(d);
            _ = self.running.swapRemove(i);
        }
    }

    /// Bump the counter and both histograms for one finished attempt. Duration
    /// is the handler's wall time; the e2e series is measured from `run_at`
    /// (enqueue time), so retry backoff widens it the way §15 describes.
    fn recordOutcome(mx: *metrics_mod.Metrics, d: *Dispatch, stopped: bool) void {
        const now = std.time.milliTimestamp();
        const kind = d.kind;
        switch (d.outcome) {
            .failed => |f| {
                mx.incrFailed(kind);
                const outcome: metrics_mod.Metrics.Outcome = if (f.class == .retryable) .failed else .dead;
                mx.observeJobDuration(kind, outcome, elapsedMicros(d, now));
                mx.observeE2E(kind, outcome, elapsedMicros(d, now));
            },
            .ok => {
                if (stopped) {
                    mx.observeJobDuration(kind, .cancelled, elapsedMicros(d, now));
                    mx.observeE2E(kind, .cancelled, elapsedMicros(d, now));
                } else {
                    mx.incrCompleted(kind);
                    mx.observeJobDuration(kind, .completed, elapsedMicros(d, now));
                    mx.observeE2E(kind, .completed, elapsedMicros(d, now));
                }
            },
        }
    }

    fn elapsedMicros(d: *Dispatch, now_ms: i64) u64 {
        const ms = @max(now_ms - d.started_ms, 0);
        return @as(u64, @intCast(ms)) * 1000;
    }

    fn reportFailure(self: *Owner, d: *Dispatch, qname: []const u8) !void {
        const f = d.outcome.failed;
        var out = broker_mod.FailOutcome{};
        // Two bounds on the attempt budget: the one stored on the job row
        // when it was enqueued, and the one the kind declares. Both are upper
        // bounds, so the effective budget is the smaller of the two, and the
        // broker enforces the row's side on its own.
        //
        // The worker enforces the kind's bound even when the producer did
        // not know the kind, so a kind that says "three strikes and
        // dead-letter" is never given more than three attempts.
        const kind_budget: u32 = d.entry.max_attempts;
        const may_retry = f.class == .retryable and d.attempts < kind_budget;

        var retry_at: i64 = 0;
        if (may_retry) {
            const bo = d.entry.retry orelse self.default_retry;
            var prng = std.Random.DefaultPrng.init(@bitCast(@as(u64, @intCast(d.id)) ^ (@as(u64, d.attempts) << 8)));
            const delay = bo.delayMs(d.attempts + 1, 0, prng.random());
            retry_at = std.time.milliTimestamp() + @as(i64, @intCast(delay));
        }

        // Why the job stops, if it stops now: a permanent error, or an
        // exhausted budget. Those are different causes, and the row records
        // which one it was.
        const failure: broker_mod.Failure = if (!may_retry)
            (if (f.class == .retryable) .{ .attempts_exhausted = {} } else .{ .non_retryable = {} })
        else
            .{ .retry = retry_at };

        self.broker.fail(qname, d.id, d.epoch, f.name, failure, &out) catch |e| {
            std.log.warn("fail id={d}: {s}", .{ d.id, @errorName(e) });
        };
    }

    fn heartbeat(self: *Owner, now_ms: i64) void {
        if (self.cfgs.len == 0) return;
        const interval = @max(self.cfgs[0].lease_ms / 3, 250);
        self.next_hb_ms = now_ms + @as(i64, @intCast(interval));
        if (self.running.items.len == 0) return;
        for (self.cfgs, 0..) |q, qi| {
            var ids: std.ArrayListUnmanaged(i64) = .{};
            var eps: std.ArrayListUnmanaged(u64) = .{};
            defer ids.deinit(self.alloc);
            defer eps.deinit(self.alloc);
            for (self.running.items) |d| {
                if (d.queue_idx == qi) {
                    ids.append(self.alloc, d.id) catch return;
                    eps.append(self.alloc, d.epoch) catch return;
                }
            }
            if (ids.items.len == 0) continue;
            self.broker.heartbeat(q.name, ids.items, eps.items, q.lease_ms) catch |e| {
                std.log.warn("heartbeat queue={s}: {s}", .{ q.name, @errorName(e) });
            };
        }
    }

    fn countRunning(self: *Owner, qi: usize) usize {
        var n: usize = 0;
        for (self.running.items) |d| {
            if (d.queue_idx == qi and !d.done.load(.acquire)) n += 1;
        }
        return n;
    }

    fn removeSlot(self: *Owner, idx: usize) void {
        for (self.free_slots.items, 0..) |v, k| {
            if (v == idx) {
                _ = self.free_slots.swapRemove(k);
                return;
            }
        }
    }
};

test "fairness pick with refreshed slots" {
    var o = Owner{
        .alloc = undefined,
        .broker = undefined,
        .reg = undefined,
        .pool = undefined,
        .cfgs = &.{},
        .worker_name = "",
        .default_retry = .{},
        .metrics = null,
        .sandbox_cfgs = &.{},
    };
    o.fair.setWeights(&[_]u32{ 1, 1 });
    var flags = [_]bool{ true, false };
    try std.testing.expectEqual(@as(?usize, 0), o.fair.pick(&flags));
}
