const std = @import("std");
const beanline = @import("beanline");
const broker = beanline.broker_api;

pub const Backend = enum { postgres, redis };

const PgBroker = beanline.PostgresBroker;
const RedisBroker = beanline.RedisBroker;

pub const Fixture = struct {
    alloc: std.mem.Allocator,
    broker: broker.Broker,
    backend: Backend,
    queue: []const u8,
    scratch: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator, br: broker.Broker, backend: Backend, queue: []const u8) Fixture {
        return .{
            .alloc = alloc,
            .broker = br,
            .backend = backend,
            .queue = queue,
            .scratch = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Fixture) void {
        self.scratch.deinit();
    }

    pub fn enqueue(self: *Fixture, kind: []const u8, args_json: []const u8, opts: broker.EnqueueOptions) !broker.Enqueued {
        var out = broker.Enqueued{};
        try self.broker.enqueue(kind, args_json, opts, &out);
        return out;
    }

    pub fn claim(self: *Fixture, limit: u32) ![]broker.Claimed {
        const al = self.scratch.allocator();
        const buf = try al.alloc(broker.Claimed, limit);
        const n = try self.broker.claim(self.queue, limit, "ct-worker", 60000, buf);
        return buf[0..n];
    }

    pub fn claimWith(self: *Fixture, limit: u32, worker_id: []const u8, lease_ms: u64) ![]broker.Claimed {
        const al = self.scratch.allocator();
        const buf = try al.alloc(broker.Claimed, limit);
        const n = try self.broker.claim(self.queue, limit, worker_id, lease_ms, buf);
        return buf[0..n];
    }

    pub fn depth(self: *Fixture) !broker.Depth {
        var d = broker.Depth{};
        try self.broker.depth(self.queue, &d);
        return d;
    }

    pub fn getJob(self: *Fixture, id: i64) !?broker.JobRow {
        var out: ?broker.JobRow = null;
        try self.broker.getJob(self.alloc, id, &out);
        return out;
    }

    pub fn events(self: *Fixture, id: i64) ![]broker.EventRow {
        const al = self.scratch.allocator();
        var out = std.ArrayList(broker.EventRow).init(al);
        try self.broker.jobEvents(self.alloc, id, &out);
        return out.toOwnedSlice();
    }

    pub fn listJobs(self: *Fixture, filter: broker.JobFilter) ![]broker.JobRow {
        const al = self.scratch.allocator();
        var out = std.ArrayList(broker.JobRow).init(al);
        try self.broker.listJobs(self.alloc, filter, &out);
        return out.toOwnedSlice();
    }

    pub fn queueNames(self: *Fixture) ![]const []const u8 {
        const al = self.scratch.allocator();
        var out = std.ArrayList([]const u8).init(al);
        try self.broker.queueNames(self.alloc, &out);
        return out.toOwnedSlice();
    }

    pub fn retry(self: *Fixture, id: i64) !void {
        try self.broker.retry(self.queue, id);
    }

    pub fn discard(self: *Fixture, id: i64) !void {
        try self.broker.discard(self.queue, id);
    }

    pub fn cancel(self: *Fixture, id: i64, epoch: ?u64) !void {
        try self.broker.cancel(self.queue, id, epoch);
    }

    pub fn finish(self: *Fixture, id: i64, epoch: u64) !void {
        try self.broker.finish(self.queue, id, epoch);
    }

    pub fn fail(self: *Fixture, id: i64, epoch: u64, err_name: []const u8, failure: broker.Failure) !broker.FailOutcome {
        var out = broker.FailOutcome{};
        try self.broker.fail(self.queue, id, epoch, err_name, failure, &out);
        return out;
    }

    pub fn heartbeat(self: *Fixture, ids: []const i64, epochs: []const u64, lease_ms: u64) !void {
        try self.broker.heartbeat(self.queue, ids, epochs, lease_ms);
    }

    pub fn promote(self: *Fixture, queues: []const []const u8, limit: u32) !u32 {
        return try self.broker.promote(queues, limit);
    }

    pub fn reap(self: *Fixture, queues: []const []const u8, limit: u32) !u32 {
        return try self.broker.reap(queues, limit);
    }

    pub fn enqueueOpts(self: *Fixture, kind: []const u8, args_json: []const u8, opts: broker.EnqueueOptions) broker.EnqueueOptions {
        _ = self;
        _ = kind;
        _ = args_json;
        return opts;
    }
};

pub const Case = struct {
    name: []const u8,
    queue: []const u8,
    run: *const fn (f: *Fixture) anyerror!void,
};

/// A backend-specific divergence probe: asserts the actual (documented-wrong
/// or backend-specific) behavior of one backend. The case name states the gap.
pub const Probe = struct {
    name: []const u8,
    queue: []const u8,
    backend: Backend,
    run: *const fn (f: *Fixture) anyerror!void,
};

pub const Divergence = struct {
    case: []const u8,
    backend: Backend,
    note: []const u8,
};

pub const known_divergences = [_]Divergence{
    .{
        .case = "unique-key-released-after-dead",
        .backend = .postgres,
        .note = "PG keeps the unique key held after the job dies (its partial index excludes only completed/discarded/cancelled); Redis releases the guard on death. Spec is silent on the dead case.",
    },
    .{
        .case = "operator-retry-accepts-discarded",
        .backend = .redis,
        .note = "PG's SQL_RETRY accepts discarded jobs; Redis's redis_retry_lua only accepts dead or cancelled.",
    },
    .{
        .case = "claim-harvests-due-scheduled-without-promote",
        .backend = .redis,
        .note = "PG's claim only selects status='available'; Redis's claim.lua harvests due delayed members itself, so a scheduled job becomes claimable without an explicit promote(). Spec section 5 says scheduled->available via the promoter.",
    },
    .{
        .case = "claimed-run-at-is-epoch-vs-zero",
        .backend = .redis,
        .note = "PG returns the job's run_at (an epoch ms) in Claimed.run_at_ms; Redis returns the stored run_at which is 0 for an immediately enqueued job.",
    },
    .{
        .case = "claimed-args-json-is-normalized",
        .backend = .postgres,
        .note = "PG stores args as JSONB and returns args::text (normalized whitespace and key ordering); Redis stores and returns the original string verbatim.",
    },
    .{
        .case = "promote-and-reap-are-global-vs-per-queue",
        .backend = .redis,
        .note = "PG's promote/reap ignore the queue argument entirely (global); Redis's are per-queue. Documented in architecture.md 7.5. Observable: promoting/reaping one queue affects jobs in other queues under PG.",
    },
    .{
        .case = "event-trail-at-ms-is-populated",
        .backend = .redis,
        .note = "PG records a real timestamp per event; Redis stores 0 (at_ms is not persisted in the capped event list).",
    },
    .{
        .case = "oldest-available-ms-populated",
        .backend = .redis,
        .note = "PG's depth query computes min(run_at) over available jobs; Redis's depth hash never populates oldest_available_ms.",
    },
};

pub fn isKnownDivergence(case_name: []const u8, backend: Backend) ?[]const u8 {
    for (known_divergences) |d| {
        if (std.mem.eql(u8, d.case, case_name) and d.backend == backend) return d.note;
    }
    return null;
}

// ---- backend opening ----

fn openPostgres(alloc: std.mem.Allocator, dsn: []const u8) !broker.Broker {
    const p = try PgBroker.open(alloc, dsn, 5 * 60 * 1000);
    return PgBroker.toBroker(p);
}

fn openRedis(alloc: std.mem.Allocator, url: []const u8) !broker.Broker {
    const r = try RedisBroker.open(alloc, url, 5 * 60 * 1000);
    return RedisBroker.toBroker(r);
}

pub fn openBackend(alloc: std.mem.Allocator, backend: Backend) !broker.Broker {
    switch (backend) {
        .postgres => {
            const dsn = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_DSN") catch |e| {
                if (e == error.EnvironmentVariableNotFound) return error.NoBackendConfigured;
                return e;
            };
            defer alloc.free(dsn);
            return try openPostgres(alloc, dsn);
        },
        .redis => {
            const url = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_REDIS_URL") catch |e| {
                if (e == error.EnvironmentVariableNotFound) return error.NoBackendConfigured;
                return e;
            };
            defer alloc.free(url);
            return try openRedis(alloc, url);
        },
    }
}

pub fn purge(backend: Backend, br: broker.Broker, queue: []const u8) !void {
    switch (backend) {
        .postgres => try PgBroker.purgeQueue(br, queue),
        .redis => try RedisBroker.purgeQueue(br, queue),
    }
}

pub fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .postgres => "postgres",
        .redis => "redis",
    };
}

pub fn runAll(backend: Backend, cases: []const Case, probes: []const Probe) !void {
    const alloc = std.testing.allocator;

    // Required mode: fail loudly instead of silently skipping.
    const required = std.process.getEnvVarOwned(alloc, "BEANLINE_CONTRACT_REQUIRED") catch null;
    defer if (required) |r| alloc.free(r);
    const is_required = required != null;

    const br = openBackend(alloc, backend) catch |e| {
        if (e == error.NoBackendConfigured) {
            if (is_required) {
                std.debug.print("contract suite: {s} backend not configured (set the env var) but BEANLINE_CONTRACT_REQUIRED=1\n", .{backendName(backend)});
                return error.NoBackendConfigured;
            }
            std.debug.print("contract suite: {s} skipped (no env var set)\n", .{backendName(backend)});
            return;
        }
        return e;
    };
    defer br.deinit();

    // Schema check for postgres.
    if (backend == .postgres) {
        const probe_filter = broker.JobFilter{ .limit = 1 };
        var probe_rows = std.ArrayList(broker.JobRow).init(alloc);
        defer probe_rows.deinit();
        _ = br.listJobs(alloc, probe_filter, &probe_rows) catch {
            std.debug.print("contract suite: postgres schema missing - run `beanline migrate` first\n", .{});
            return error.NoBackendConfigured;
        };
    }

    std.debug.print("contract suite: {s}\n", .{backendName(backend)});
    var passed: usize = 0;
    var failed: usize = 0;
    var total: usize = 0;

    // Contract cases.
    for (cases, 0..) |c, i| {
        total += 1;
        var qbuf: [128]u8 = undefined;
        const q = try std.fmt.bufPrint(&qbuf, "ct-{d}-{s}", .{ i, c.queue });
        try purge(backend, br, q);
        var f = Fixture.init(alloc, br, backend, q);
        defer f.deinit();
        c.run(&f) catch |err| {
            failed += 1;
            std.debug.print("  FAIL  {s}\n        error: {s}\n", .{ c.name, @errorName(err) });
            continue;
        };
        // purge after the case so leftovers don't affect later cases.
        purge(backend, br, q) catch {};
        passed += 1;
        std.debug.print("  ok    {s}\n", .{c.name});
    }

    // Divergence probes for this backend.
    for (probes, 0..) |p, i| {
        if (p.backend != backend) continue;
        total += 1;
        var qbuf: [128]u8 = undefined;
        const q = try std.fmt.bufPrint(&qbuf, "ct-p-{d}-{s}", .{ i, p.queue });
        try purge(backend, br, q);
        var f = Fixture.init(alloc, br, backend, q);
        defer f.deinit();
        p.run(&f) catch |err| {
            failed += 1;
            std.debug.print("  FAIL  [probe] {s}\n        error: {s}\n", .{ p.name, @errorName(err) });
            continue;
        };
        purge(backend, br, q) catch {};
        passed += 1;
        std.debug.print("  ok    [probe] {s}\n", .{p.name});
    }

    std.debug.print("contract suite: {s}: {d}/{d} passed\n", .{ backendName(backend), passed, total });
    if (failed > 0) return error.ContractFailure;
}
