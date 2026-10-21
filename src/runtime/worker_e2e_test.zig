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

var noop_hits: usize = 0;

fn noopHandle(_: *job_mod.Context, _: job_mod.Args) anyerror!void {
    _ = @atomicRmw(usize, &noop_hits, .Add, 1, .seq_cst);
}

fn boomHandle(_: *job_mod.Context, _: job_mod.Args) anyerror!void {
    return error.Boom;
}

fn sleeperHandle(ctx: *job_mod.Context, _: job_mod.Args) anyerror!void {
    while (!ctx.stopped()) std.time.sleep(2);
}

fn setupRegistry(alloc: std.mem.Allocator) registry_mod.Registry {
    var reg = registry_mod.Registry.init(alloc);
    reg.register(.{ .name = "e2e.noop", .queue = "e2e", .handle = noopHandle }) catch unreachable;
    reg.register(.{ .name = "e2e.boom", .queue = "e2e", .handle = boomHandle }) catch unreachable;
    reg.register(.{ .name = "e2e.sleeper", .queue = "e2e", .timeout_ms = 150, .handle = sleeperHandle }) catch unreachable;
    return reg;
}

fn uniqueQueue(comptime tag: []const u8, buf: []u8) []const u8 {
    const s = std.fmt.bufPrint(buf, "{s}-{d}", .{ tag, std.time.milliTimestamp() }) catch unreachable;
    return s;
}

// Runs the full worker-owner loop through a live broker: 3 noop jobs complete
// exactly once, an unknown kind and a max-attempts=1 boom job land in dead,
// then a graceful drain leaves nothing behind.
fn runE2E(alloc: std.mem.Allocator, br: b.Broker, queue: []const u8, wname: []const u8) !void {
    var reg = setupRegistry(alloc);
    defer reg.deinit();

    var pool = pool_mod.Pool{ .alloc = alloc };
    try pool.start(2);
    defer pool.shutdown();

    const cfgs = [_]QueueConfig{.{ .name = queue, .concurrency = 2, .lease_ms = 5000 }};
    var owner = try Owner.init(alloc, br, &reg, &pool, .{ .queues = &cfgs, .worker_name = wname, .dead_on = &.{"Boom"} });
    defer owner.deinit();

    var enq = b.Enqueued{};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try br.enqueue("e2e.noop", "{\"to\":\"a\",\"subject\":\"s\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);
    }
    try br.enqueue("e2e.unknown", "{}", .{ .queue = queue, .run_at_ms = 0 }, &enq);
    try br.enqueue("e2e.boom", "{\"to\":\"b\",\"subject\":\"x\"}", .{ .queue = queue, .run_at_ms = 0, .max_attempts = 1 }, &enq);
    try br.enqueue("e2e.sleeper", "{\"to\":\"c\",\"subject\":\"z\"}", .{ .queue = queue, .run_at_ms = 0 }, &enq);

    _ = @atomicStore(usize, &noop_hits, 0, .seq_cst);

    const deadline = std.time.milliTimestamp() + 15000;
    while (std.time.milliTimestamp() < deadline) {
        const n = try owner.tick(std.time.milliTimestamp());
        var depth = b.Depth{};
        try br.depth(queue, &depth);
        if (depth.completed == 3 and depth.dead == 2 and depth.cancelled == 1) break;
        if (n == 0 and owner.inflight() == 0 and depth.available == 0 and depth.running == 0) break;
        std.time.sleep(if (n == 0) 25 else 5);
    }
    try std.testing.expectEqual(@as(usize, 3), @atomicLoad(usize, &noop_hits, .seq_cst));

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
    try std.testing.expectEqual(@as(u64, 3), depth.completed);
    try std.testing.expectEqual(@as(u64, 2), depth.dead);
    try std.testing.expectEqual(@as(u64, 1), depth.cancelled);
    try std.testing.expectEqual(@as(u64, 0), depth.available);
    try std.testing.expectEqual(@as(u64, 0), depth.running);
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
