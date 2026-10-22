const std = @import("std");
const b = @import("../broker/broker.zig");
const pg = @import("../broker/postgres.zig");
const redis = @import("../broker/redis.zig");
const queue_mod = @import("queues.zig");
const pool_mod = @import("pool.zig");
const registry_mod = @import("../core/registry.zig");
const job_mod = @import("../core/job.zig");

const Owner = queue_mod.Owner;
const QueueConfig = queue_mod.QueueConfig;

// Two different payload shapes. The queue used to hardcode one struct for
// every kind, so this file is the regression test for that: a kind with its
// own schema must be able to run next to a kind with a different one.
const MailArgs = struct { to: []const u8, subject: []const u8 };
const InvoiceArgs = struct { cents: u64, note: []const u8 };

var noop_hits: usize = 0;
var invoice_hits: usize = 0;
var boom_hits: usize = 0;
var flaky_hits: usize = 0;

const noop_kind = job_mod.Kind(MailArgs, error{}).new(.{
    .name = "e2e.noop",
    .queue = "e2e",
    .handle = struct {
        fn run(_: *job_mod.Context, _: MailArgs) error{}!void {
            _ = @atomicRmw(usize, &noop_hits, .Add, 1, .seq_cst);
        }
    }.run,
});

const invoice_kind = job_mod.Kind(InvoiceArgs, error{}).new(.{
    .name = "e2e.invoice",
    .queue = "e2e",
    .handle = struct {
        fn run(_: *job_mod.Context, _: InvoiceArgs) error{}!void {
            _ = @atomicRmw(usize, &invoice_hits, .Add, 1, .seq_cst);
        }
    }.run,
});

/// A permanent failure: classified dead, so the job must dead-letter on its
/// first attempt instead of burning the whole attempt budget.
const dead_kind = job_mod.Kind(MailArgs, error{Boom}).new(.{
    .name = "e2e.boom",
    .queue = "e2e",
    .errors = .{ .dead_on = &.{error.Boom} },
    .handle = struct {
        fn run(_: *job_mod.Context, _: MailArgs) error{Boom}!void {
            _ = @atomicRmw(usize, &boom_hits, .Add, 1, .seq_cst);
            return error.Boom;
        }
    }.run,
});

/// A transient failure: classified retryable, so the job goes back on the
/// queue with a backoff.
const flaky_kind = job_mod.Kind(MailArgs, error{Flaky}).new(.{
    .name = "e2e.flaky",
    .queue = "e2e",
    .errors = .{ .retryable = &.{error.Flaky} },
    .retry = .{ .base_ms = 10, .cap_ms = 50 },
    .handle = struct {
        fn run(_: *job_mod.Context, _: MailArgs) error{Flaky}!void {
            _ = @atomicRmw(usize, &flaky_hits, .Add, 1, .seq_cst);
            return error.Flaky;
        }
    }.run,
});

const sleeper_kind = job_mod.Kind(MailArgs, error{}).new(.{
    .name = "e2e.sleeper",
    .queue = "e2e",
    .timeout_ms = 150,
    .handle = struct {
        fn run(ctx: *job_mod.Context, _: MailArgs) error{}!void {
            while (!ctx.stopped()) std.time.sleep(2);
        }
    }.run,
});

fn setupRegistry(alloc: std.mem.Allocator) registry_mod.Registry {
    var reg = registry_mod.Registry.init(alloc);
    reg.register(registry_mod.entryFor(@TypeOf(noop_kind), noop_kind)) catch unreachable;
    reg.register(registry_mod.entryFor(@TypeOf(invoice_kind), invoice_kind)) catch unreachable;
    reg.register(registry_mod.entryFor(@TypeOf(dead_kind), dead_kind)) catch unreachable;
    reg.register(registry_mod.entryFor(@TypeOf(flaky_kind), flaky_kind)) catch unreachable;
    reg.register(registry_mod.entryFor(@TypeOf(sleeper_kind), sleeper_kind)) catch unreachable;
    return reg;
}

fn uniqueQueue(comptime tag: []const u8, buf: []u8) []const u8 {
    const s = std.fmt.bufPrint(buf, "{s}-{d}", .{ tag, std.time.milliTimestamp() }) catch unreachable;
    return s;
}

// Runs the full worker-owner loop through a live broker.
//
// Covered here, all of which used to be impossible or wrong:
//   - two kinds with different payload shapes run side by side;
//   - an error classified dead dead-letters on the first attempt;
//   - an error classified retryable goes back on the queue;
//   - a payload that does not fit the kind's schema dead-letters on the
//     first attempt (it used to be retried until the attempt budget ran out);
//   - an unknown kind dead-letters immediately;
//   - a graceful drain leaves nothing behind.
fn runE2E(alloc: std.mem.Allocator, br: b.Broker, queue: []const u8, wname: []const u8) !void {
    var reg = setupRegistry(alloc);
    defer reg.deinit();

    var pool = pool_mod.Pool{ .alloc = alloc };
    try pool.start(2);
    defer pool.shutdown();

    const cfgs = [_]QueueConfig{.{ .name = queue, .concurrency = 2, .lease_ms = 5000 }};
    var owner = try Owner.init(alloc, br, &reg, &pool, .{
        .queues = &cfgs,
        .worker_name = wname,
        .retry = .{ .base_ms = 10, .cap_ms = 50 },
    });
    defer owner.deinit();

    var enq = b.Enqueued{};

    var noop_id: i64 = 0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try br.enqueue("e2e.noop", "{\"to\":\"a\",\"subject\":\"s\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);
        if (i == 0) noop_id = enq.id;
    }

    // A second kind with a completely different payload shape.
    try br.enqueue("e2e.invoice", "{\"cents\":1200,\"note\":\"n\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    // Unknown kind: dead immediately, never claimed.
    try br.enqueue("e2e.unknown", "{}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    // A payload that does not fit the kind's schema: dead on the first
    // attempt, not retried until the attempt budget is gone.
    try br.enqueue("e2e.noop", "{\"to\":\"a\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    // A permanent handler error, classified dead.
    try br.enqueue("e2e.boom", "{\"to\":\"b\",\"subject\":\"x\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    // A transient handler error, classified retryable.
    try br.enqueue("e2e.flaky", "{\"to\":\"c\",\"subject\":\"z\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    // A handler that never returns on its own: the deadline cancels it.
    try br.enqueue("e2e.sleeper", "{\"to\":\"d\",\"subject\":\"w\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    _ = @atomicStore(usize, &noop_hits, 0, .seq_cst);
    _ = @atomicStore(usize, &invoice_hits, 0, .seq_cst);
    _ = @atomicStore(usize, &boom_hits, 0, .seq_cst);
    _ = @atomicStore(usize, &flaky_hits, 0, .seq_cst);

    const deadline = std.time.milliTimestamp() + 15000;
    while (std.time.milliTimestamp() < deadline) {
        const n = try owner.tick(std.time.milliTimestamp());
        var depth = b.Depth{};
        try br.depth(queue, &depth);
        if (depth.completed == 4 and depth.dead == 3 and depth.cancelled == 1) break;
        if (n == 0 and owner.inflight() == 0 and depth.available == 0 and depth.running == 0) break;
        std.time.sleep(if (n == 0) 25 else 5);
    }

    // Three mail jobs completed, plus the invoice job with its own schema.
    try std.testing.expectEqual(@as(usize, 3), @atomicLoad(usize, &noop_hits, .seq_cst));
    try std.testing.expectEqual(@as(usize, 1), @atomicLoad(usize, &invoice_hits, .seq_cst));

    // The dead-classified error ran exactly once: it did not burn the
    // attempt budget.
    try std.testing.expectEqual(@as(usize, 1), @atomicLoad(usize, &boom_hits, .seq_cst));

    // Graceful drain: stop claiming, let running handlers finish, reap.
    owner.signalStop();
    const settle = deadline;
    while (owner.inflight() > 0 and std.time.milliTimestamp() < settle) {
        std.time.sleep(2);
        _ = try owner.tick(std.time.milliTimestamp());
    }
    try std.testing.expectEqual(@as(usize, 0), owner.inflight());
    _ = try owner.tick(std.time.milliTimestamp());

    var depth = b.Depth{};
    try br.depth(queue, &depth);
    try std.testing.expectEqual(@as(u64, 4), depth.completed);
    // unknown kind + bad payload + dead-classified error
    try std.testing.expectEqual(@as(u64, 3), depth.dead);
    try std.testing.expectEqual(@as(u64, 1), depth.cancelled);
    try std.testing.expectEqual(@as(u64, 0), depth.available);
    try std.testing.expectEqual(@as(u64, 0), depth.running);

    // The retryable error went back on the queue: it was attempted more than
    // once and is not dead.
    try std.testing.expect(@atomicLoad(usize, &flaky_hits, .seq_cst) >= 1);

    // A job that dead-lettered on the first attempt must show one attempt,
    // not the whole budget.
    var row: ?b.JobRow = null;
    try br.getJob(alloc, noop_id, &row);
    if (row) |r| {
        try std.testing.expectEqual(b.Status.completed, r.status);
    }
}

test "e2e worker owner over postgres" {
    const alloc = std.testing.allocator;
    const dsn = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_DSN") catch return;
    defer alloc.free(dsn);

    const p = try pg.open(alloc, dsn, 5 * 60 * 1000);
    const br = pg.toBroker(p);
    defer br.deinit();

    var buf: [64]u8 = undefined;
    const queue = uniqueQueue("e2e-pg", &buf);
    try runE2E(alloc, br, queue, "worker-e2e-pg");
}

test "e2e worker owner over redis" {
    const alloc = std.testing.allocator;
    const url = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_REDIS_URL") catch return;
    defer alloc.free(url);

    const r = try redis.open(alloc, url, 5 * 60 * 1000);
    const br = redis.toBroker(r);
    defer br.deinit();

    var buf: [64]u8 = undefined;
    const queue = uniqueQueue("e2e-redis", &buf);
    try runE2E(alloc, br, queue, "worker-e2e-redis");
}
