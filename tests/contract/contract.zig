const std = @import("std");
const beanline = @import("beanline");
const broker = beanline.broker_api;
const harness = @import("harness.zig");

const Fixture = harness.Fixture;

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn parseJson(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
}

fn jsonInt(v: std.json.Value, key: []const u8) !i64 {
    const o = switch (v) {
        .object => |o| o,
        else => return error.BadJson,
    };
    const f = o.get(key) orelse return error.MissingField;
    return switch (f) {
        .integer => |i| i,
        else => error.NotInteger,
    };
}

fn eventTypes(alloc: std.mem.Allocator, evs: []const broker.EventRow) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, evs.len);
    for (evs, 0..) |e, i| out[i] = e.event_type;
    return out;
}

// ---------------------------------------------------------------- enqueue / state machine

fn case_enqueue_now_available(f: *Fixture) !void {
    const q = f.queue;
    _ = q;
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = 0 });
    try std.testing.expect(enq.id > 0);
    try std.testing.expect(!enq.deduped);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.scheduled);
    try std.testing.expectEqual(@as(u64, 0), d.running);
}

fn case_enqueue_future_scheduled(f: *Fixture) !void {
    const future = nowMs() + 5000;
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = future });
    try std.testing.expect(enq.id > 0);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.available);
    try std.testing.expectEqual(@as(u64, 1), d.scheduled);
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 0), claimed.len);
}

fn case_promote_due_scheduled(f: *Fixture) !void {
    const due = nowMs() + 200;
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = due });
    try std.testing.expect(enq.id > 0);
    std.time.sleep(400 * std.time.ns_per_ms);
    var d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.scheduled);
    try std.testing.expectEqual(@as(u64, 0), d.available);
    const moved = try f.promote(&.{f.queue}, 100);
    _ = moved;
    d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.scheduled);
    try std.testing.expectEqual(@as(u64, 1), d.available);
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
}

fn case_claim_returns_enqueued(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{\"n\":7}", .{ .queue = f.queue, .run_at_ms = 0, .max_attempts = 5 });
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    const c = claimed[0];
    try std.testing.expectEqual(enq.id, c.id);
    try std.testing.expectEqualStrings("ct.kind", c.kind);
    try std.testing.expectEqual(@as(u32, 1), c.attempts);
    try std.testing.expectEqual(@as(u32, 5), c.max_attempts);
    try std.testing.expect(c.lease_epoch >= 1);
    try std.testing.expectEqual(@as(u8, 1), c.priority);
    const parsed = try parseJson(f.alloc, c.args_json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), try jsonInt(parsed.value, "n"));
}

fn case_claim_empty_queue(f: *Fixture) !void {
    const claimed = try f.claim(4);
    try std.testing.expectEqual(@as(usize, 0), claimed.len);
}

fn case_claim_respects_limit(f: *Fixture) !void {
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const claimed = try f.claim(2);
    try std.testing.expectEqual(@as(usize, 2), claimed.len);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 2), d.running);
}

fn case_claim_no_duplicate(f: *Fixture) !void {
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c1 = try f.claim(10);
    const c2 = try f.claim(10);
    try std.testing.expectEqual(@as(usize, 2), c1.len + c2.len);
    // no id appears in both
    var seen = std.ArrayList(i64).init(f.alloc);
    defer seen.deinit();
    for (c1) |c| try seen.append(c.id);
    for (c2) |c| for (seen.items) |s| try std.testing.expect(s != c.id);
}

fn case_claim_increments_attempts(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 3 });
    const c1 = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), c1.len);
    try std.testing.expectEqual(@as(u32, 1), c1[0].attempts);
    // fail retryable to return to available, then re-claim
    const fo = try f.fail(enq.id, c1[0].lease_epoch, "E", true, nowMs() - 1000);
    try std.testing.expectEqual(broker.Status.available, fo.status);
    const c2 = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), c2.len);
    try std.testing.expectEqual(@as(u32, 2), c2[0].attempts);
}

fn case_claim_epoch_increases(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c1 = try f.claimWith(1, "worker-a", 50);
    try std.testing.expectEqual(@as(usize, 1), c1.len);
    // expire lease and reap
    std.time.sleep(500 * std.time.ns_per_ms);
    const reaped = try f.reap(&.{f.queue}, 10);
    try std.testing.expect(reaped >= 1);
    const c2 = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), c2.len);
    try std.testing.expect(c2[0].lease_epoch > c1[0].lease_epoch);
    _ = enq;
}

fn case_finish_marks_completed(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try f.finish(enq.id, c[0].lease_epoch);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.completed);
    try std.testing.expectEqual(@as(u64, 0), d.running);
    const row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.completed, row.status);
}

fn case_finish_stale_epoch_rejected(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try std.testing.expectError(error.StaleLease, f.finish(enq.id, c[0].lease_epoch + 1));
}

fn case_finish_twice_rejected(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try f.finish(enq.id, c[0].lease_epoch);
    try std.testing.expectError(error.StaleLease, f.finish(enq.id, c[0].lease_epoch));
}

fn case_fail_retryable_returns_available(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 3 });
    const c = try f.claim(1);
    const fo = try f.fail(enq.id, c[0].lease_epoch, "E", true, nowMs() - 1000);
    try std.testing.expectEqual(broker.Status.available, fo.status);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.running);
}

fn case_fail_retryable_at_max_goes_dead(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 1 });
    const c = try f.claim(1);
    const fo = try f.fail(enq.id, c[0].lease_epoch, "E", true, nowMs() - 1000);
    try std.testing.expectEqual(broker.Status.dead, fo.status);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.dead);
}

fn case_fail_nonretryable_goes_dead(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 3 });
    const c = try f.claim(1);
    const fo = try f.fail(enq.id, c[0].lease_epoch, "E", false, 0);
    try std.testing.expectEqual(broker.Status.dead, fo.status);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.dead);
}

fn case_fail_stale_epoch_rejected(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try std.testing.expectError(error.StaleLease, f.fail(enq.id, c[0].lease_epoch + 1, "E", true, nowMs() - 1000));
}

fn case_cancel_available(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    try f.cancel(enq.id, null);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.cancelled);
    try std.testing.expectEqual(@as(u64, 0), d.available);
    const row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.cancelled, row.status);
}

fn case_cancel_running_with_epoch(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try f.cancel(enq.id, c[0].lease_epoch);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.cancelled);
    try std.testing.expectEqual(@as(u64, 0), d.running);
}

fn case_cancel_running_wrong_epoch(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try std.testing.expectError(error.Running, f.cancel(enq.id, c[0].lease_epoch + 1));
}

fn case_cancel_unknown(f: *Fixture) !void {
    try std.testing.expectError(error.NotFound, f.cancel(999999999, null));
}

fn case_discard_available(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    try f.discard(enq.id);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.available);
    const row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.discarded, row.status);
    // not claimable afterwards
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 0), claimed.len);
}

fn case_operator_retry_dead(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 1 });
    const c = try f.claim(1);
    _ = try f.fail(enq.id, c[0].lease_epoch, "E", false, 0);
    var d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.dead);
    try f.retry(enq.id);
    d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.dead);
    try std.testing.expectEqual(@as(u64, 1), d.available);
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    try std.testing.expectEqual(@as(u32, 1), claimed[0].attempts);
}

// ---------------------------------------------------------------- lease / reap

fn case_reap_requeues_expired(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 3 });
    const c = try f.claimWith(1, "worker-a", 50);
    _ = c;
    std.time.sleep(200 * std.time.ns_per_ms);
    const n = try f.reap(&.{f.queue}, 10);
    try std.testing.expect(n >= 1);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.running);
    try std.testing.expectEqual(@as(u64, 1), d.available);
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    try std.testing.expectEqual(enq.id, claimed[0].id);
    // The attempt is refunded: a lease expiry is usually not the job's
    // fault, so it must not spend the failure budget. The lease loss is
    // counted separately and is not refunded.
    try std.testing.expectEqual(@as(u32, 1), claimed[0].attempts);
    const row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(@as(u32, 1), row.lease_losses);
    try std.testing.expectEqual(broker.Status.running, row.status);
}

fn case_reap_dead_when_exhausted(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 1 });
    const c = try f.claimWith(1, "worker-a", 50);
    _ = c;
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try f.reap(&.{f.queue}, 10);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.dead);
    try std.testing.expectEqual(@as(u64, 0), d.available);
    _ = enq;
}

// A job whose handler kills its worker on every attempt never spends an
// attempt, so max_attempts alone never dead-letters it: the attempt
// counter is refunded on every reap. The lease-loss counter is the bound.
fn case_reap_dead_after_lease_losses(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{
        .queue = f.queue,
        .max_attempts = 25,
        .max_lease_losses = 2,
    });

    // First lease loss: requeued, attempt refunded, loss counted.
    _ = try f.claimWith(1, "worker-a", 50);
    std.time.sleep(200 * std.time.ns_per_ms);
    try std.testing.expect((try f.reap(&.{f.queue}, 10)) >= 1);
    var d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.running);
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.dead);
    var row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.available, row.status);
    try std.testing.expectEqual(@as(u32, 0), row.attempts);
    try std.testing.expectEqual(@as(u32, 1), row.lease_losses);

    // Second lease loss: dead-lettered even though no attempt was spent.
    _ = try f.claimWith(1, "worker-a", 50);
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try f.reap(&.{f.queue}, 10);
    d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.running);
    try std.testing.expectEqual(@as(u64, 1), d.dead);
    row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.dead, row.status);
    try std.testing.expectEqual(@as(u32, 2), row.lease_losses);
    try std.testing.expectEqual(@as(u32, 2), row.max_lease_losses);
}

// max_lease_losses = 0 disables the bound: the job is requeued forever.
fn case_reap_lease_loss_bound_disabled(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{
        .queue = f.queue,
        .max_attempts = 25,
        .max_lease_losses = 0,
    });

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = try f.claimWith(1, "worker-a", 50);
        std.time.sleep(200 * std.time.ns_per_ms);
        _ = try f.reap(&.{f.queue}, 10);
    }
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.dead);
    const row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.available, row.status);
    try std.testing.expectEqual(@as(u32, 3), row.lease_losses);
}

// An operator replay starts the job with a fresh budget: the attempt count
// and the lease loss count both go back to zero, otherwise a replayed job
// would be one lease loss away from dead again.
fn case_replay_resets_lease_losses(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{
        .queue = f.queue,
        .max_attempts = 25,
        .max_lease_losses = 2,
    });

    // One loss short of the bound, then kill the job the hard way.
    _ = try f.claimWith(1, "worker-a", 50);
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try f.reap(&.{f.queue}, 10);
    var row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(@as(u32, 1), row.lease_losses);

    // Dead-letter it so it can be replayed.
    _ = try f.claimWith(1, "worker-a", 50);
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try f.reap(&.{f.queue}, 10);
    row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.dead, row.status);
    try std.testing.expectEqual(@as(u32, 2), row.lease_losses);

    try f.retry(enq.id);
    row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(broker.Status.available, row.status);
    try std.testing.expectEqual(@as(u32, 0), row.attempts);
    try std.testing.expectEqual(@as(u32, 0), row.lease_losses);
}

fn case_heartbeat_extends_lease(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claimWith(1, "worker-a", 200);
    std.time.sleep(100 * std.time.ns_per_ms);
    try f.heartbeat(&.{c[0].id}, &.{c[0].lease_epoch}, 2000);
    std.time.sleep(300 * std.time.ns_per_ms);
    _ = try f.reap(&.{f.queue}, 10);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.running);
    try std.testing.expectEqual(@as(u64, 0), d.available);
    _ = enq;
}

fn case_heartbeat_stale_epoch_noop(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claimWith(1, "worker-a", 50);
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try f.reap(&.{f.queue}, 10);
    // stale epoch heartbeat must not error or resurrect
    try f.heartbeat(&.{c[0].id}, &.{c[0].lease_epoch}, 60000);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.running);
    _ = enq;
}

// ---------------------------------------------------------------- unique keys

fn case_unique_dedupes_pending(f: *Fixture) !void {
    const e1 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "u-1" });
    const e2 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "u-1" });
    try std.testing.expect(!e1.deduped);
    try std.testing.expect(e2.deduped);
    try std.testing.expectEqual(e1.id, e2.id);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
}

fn case_unique_released_after_completion(f: *Fixture) !void {
    const e1 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "u-2" });
    const c = try f.claim(1);
    try f.finish(e1.id, c[0].lease_epoch);
    const e2 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "u-2" });
    try std.testing.expect(!e2.deduped);
    try std.testing.expect(e2.id != e1.id);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 1), d.available);
    try std.testing.expectEqual(@as(u64, 1), d.completed);
}

fn case_unique_not_deduped_across_queues(f: *Fixture) !void {
    const q2 = try f.alloc.dupe(u8, "ct-other-q");
    defer f.alloc.free(q2);
    const e1 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "u-3" });
    const e2 = try f.enqueue("ct.kind", "{}", .{ .queue = q2, .unique_key = "u-3" });
    try std.testing.expect(!e1.deduped);
    try std.testing.expect(!e2.deduped);
    _ = try harness.purge(f.backend, f.broker, q2);
}

fn case_unique_not_deduped_across_kinds(f: *Fixture) !void {
    const e1 = try f.enqueue("ct.kindA", "{}", .{ .queue = f.queue, .unique_key = "u-4" });
    const e2 = try f.enqueue("ct.kindB", "{}", .{ .queue = f.queue, .unique_key = "u-4" });
    try std.testing.expect(!e1.deduped);
    try std.testing.expect(!e2.deduped);
}

fn case_dedup_run_id_dedupes(f: *Fixture) !void {
    const e1 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .dedup_run_id = "run-1" });
    const e2 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .dedup_run_id = "run-1" });
    try std.testing.expect(!e1.deduped);
    try std.testing.expect(e2.deduped);
    try std.testing.expectEqual(e1.id, e2.id);
}

fn case_replace_unique_unsupported(f: *Fixture) !void {
    try std.testing.expectError(error.UnsupportedUnique, f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "u-5", .unique = .replace }));
}

// ---------------------------------------------------------------- promote boundaries

fn case_promote_not_before_due(f: *Fixture) !void {
    const due = nowMs() + 5000;
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = due });
    _ = try f.promote(&.{f.queue}, 100);
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.available);
    try std.testing.expectEqual(@as(u64, 1), d.scheduled);
}

fn case_promote_after_due(f: *Fixture) !void {
    const due = nowMs() - 1000;
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = due });
    const moved = try f.promote(&.{f.queue}, 100);
    _ = moved;
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.scheduled);
    try std.testing.expectEqual(@as(u64, 1), d.available);
}

// ---------------------------------------------------------------- depth

fn case_depth_tracks_states(f: *Fixture) !void {
    // available
    const e1 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    // scheduled
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = nowMs() + 5000 });
    // running (claim one)
    const c = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    // completed (finish a second job)
    const e3 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c2 = try f.claim(1);
    try f.finish(e3.id, c2[0].lease_epoch);
    // dead
    const e4 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 1 });
    const c3 = try f.claim(1);
    _ = try f.fail(e4.id, c3[0].lease_epoch, "E", false, 0);
    // cancelled
    const e5 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    try f.cancel(e5.id, null);
    _ = e1;
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.available);
    try std.testing.expectEqual(@as(u64, 1), d.scheduled);
    try std.testing.expectEqual(@as(u64, 1), d.running);
    try std.testing.expectEqual(@as(u64, 1), d.completed);
    try std.testing.expectEqual(@as(u64, 1), d.dead);
    try std.testing.expectEqual(@as(u64, 1), d.cancelled);
}

fn case_depth_empty(f: *Fixture) !void {
    const d = try f.depth();
    try std.testing.expectEqual(@as(u64, 0), d.available);
    try std.testing.expectEqual(@as(u64, 0), d.scheduled);
    try std.testing.expectEqual(@as(u64, 0), d.running);
    try std.testing.expectEqual(@as(u64, 0), d.dead);
    try std.testing.expectEqual(@as(u64, 0), d.completed);
    try std.testing.expectEqual(@as(u64, 0), d.cancelled);
    try std.testing.expectEqual(@as(i64, 0), d.oldest_available_ms);
}

// ---------------------------------------------------------------- read-side

fn case_get_job_unknown(f: *Fixture) !void {
    const row = try f.getJob(999999999);
    try std.testing.expect(row == null);
}

fn case_get_job_returns_row(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const row = (try f.getJob(enq.id)).?;
    try std.testing.expectEqual(enq.id, row.id);
    try std.testing.expectEqualStrings(f.queue, row.queue);
    try std.testing.expectEqualStrings("ct.kind", row.kind);
    try std.testing.expectEqual(broker.Status.available, row.status);
    try std.testing.expectEqual(@as(u32, 0), row.attempts);
}

fn case_list_jobs_filters(f: *Fixture) !void {
    const e1 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const e2 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    const claimed_id = c[0].id;
    const other_id = if (claimed_id == e1.id) e2.id else e1.id;
    const completed_filter = broker.JobFilter{ .queue = f.queue, .status = broker.Status.completed, .limit = 50 };
    const completed_rows = try f.listJobs(completed_filter);
    try std.testing.expectEqual(@as(usize, 0), completed_rows.len);
    const avail_rows = try f.listJobs(.{ .queue = f.queue, .status = broker.Status.available, .limit = 50 });
    try std.testing.expectEqual(@as(usize, 1), avail_rows.len);
    try std.testing.expectEqual(other_id, avail_rows[0].id);
}

fn case_queue_names_includes(f: *Fixture) !void {
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const names = try f.queueNames();
    var found = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, f.queue)) found = true;
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------- event trail

fn case_event_trail(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try f.finish(enq.id, c[0].lease_epoch);
    const evs = try f.events(enq.id);
    try std.testing.expect(evs.len >= 3);
    const types = try eventTypes(f.alloc, evs);
    defer f.alloc.free(types);
    // first three must be enqueued, claimed, completed in order
    try std.testing.expectEqualStrings("enqueued", types[0]);
    try std.testing.expectEqualStrings("claimed", types[1]);
    try std.testing.expectEqualStrings("completed", types[2]);
}

fn case_event_trail_dead(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 1 });
    const c = try f.claim(1);
    _ = try f.fail(enq.id, c[0].lease_epoch, "E", false, 0);
    const evs = try f.events(enq.id);
    var has_dead = false;
    for (evs) |e| {
        if (std.mem.eql(u8, e.event_type, "dead")) has_dead = true;
    }
    try std.testing.expect(has_dead);
}

// ---------------------------------------------------------------- args / context round trip

fn case_args_round_trip(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{\"n\":7,\"s\":\"x\"}", .{ .queue = f.queue });
    const c = try f.claim(1);
    const parsed = try parseJson(f.alloc, c[0].args_json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), try jsonInt(parsed.value, "n"));
    const o = parsed.value.object;
    const s = o.get("s").?;
    try std.testing.expectEqualStrings("x", s.string);
    _ = enq;
}

fn case_context_round_trip(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .context_json = "{\"trace\":\"abc\"}" });
    const c = try f.claim(1);
    const parsed = try parseJson(f.alloc, c[0].context_json);
    defer parsed.deinit();
    const o = parsed.value.object;
    const t = o.get("trace").?;
    try std.testing.expectEqualStrings("abc", t.string);
    _ = enq;
}

// ---------------------------------------------------------------- retry timing

fn case_retry_not_claimable_until_run_at(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 3 });
    const c = try f.claim(1);
    _ = try f.fail(enq.id, c[0].lease_epoch, "E", true, nowMs() + 5000);
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 0), claimed.len);
}

fn case_retry_claimable_after_run_at(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .max_attempts = 3 });
    const c = try f.claim(1);
    _ = try f.fail(enq.id, c[0].lease_epoch, "E", true, nowMs() - 1000);
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    try std.testing.expectEqual(enq.id, claimed[0].id);
    try std.testing.expectEqual(@as(u32, 2), claimed[0].attempts);
}

fn case_transactional_enqueue(f: *Fixture) !void {
    if (f.backend != .postgres) return;
    const dsn = std.process.getEnvVarOwned(f.alloc, "BEANLINE_TEST_DSN") catch return error.NoBackendConfigured;
    defer f.alloc.free(dsn);
    const cfg = try beanline.parsePgDsn(f.alloc, dsn);
    defer cfg.free(f.alloc);
    var conn = try beanline.PgConn.connect(f.alloc, cfg);
    defer conn.deinit();

    // commit path
    try conn.execSimple("BEGIN");
    const e1 = blk: {
        var out = broker.Enqueued{};
        try beanline.enqueueIn(&conn, f.alloc, "ct.kind", "{\"n\":1}", .{ .queue = f.queue, .run_at_ms = 0 }, &out);
        break :blk out;
    };
    try conn.execSimple("COMMIT");
    const row1 = (try f.getJob(e1.id)).?;
    try std.testing.expectEqual(broker.Status.available, row1.status);

    // rollback path
    try conn.execSimple("BEGIN");
    const e2 = blk: {
        var out = broker.Enqueued{};
        try beanline.enqueueIn(&conn, f.alloc, "ct.kind", "{\"n\":2}", .{ .queue = f.queue, .run_at_ms = 0 }, &out);
        break :blk out;
    };
    try conn.execSimple("ROLLBACK");
    // the rolled-back job must not exist
    const row2 = try f.getJob(e2.id);
    try std.testing.expect(row2 == null);
}

fn case_capabilities_named_backend(f: *Fixture) !void {
    const caps = f.broker.capabilities();
    const expected = if (f.backend == .postgres) "postgres" else "redis";
    try std.testing.expectEqualStrings(expected, caps.named_backend);
}

fn case_capabilities_transactional_enqueue(f: *Fixture) !void {
    const caps = f.broker.capabilities();
    const expected = f.backend == .postgres;
    try std.testing.expectEqual(expected, caps.transactional_enqueue);
}

// ---------------------------------------------------------------- probes (backend-specific documented divergences)

fn probe_unique_released_after_dead(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "ud-1" });
    const c = try f.claim(1);
    _ = try f.fail(enq.id, c[0].lease_epoch, "E", false, 0);
    const e2 = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .unique_key = "ud-1" });
    // After fix: both postgres and redis release the guard when a job goes
    // dead (postgres via the 'dead'-excluding unique index, redis via the
    // guard key deletion), so the re-enqueue is accepted, not deduped.
    try std.testing.expect(!e2.deduped);
}

fn probe_retry_accepts_discarded(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    try f.discard(enq.id);
    if (f.backend == .postgres) {
        try f.retry(enq.id);
        const d = try f.depth();
        try std.testing.expectEqual(@as(u64, 1), d.available);
    } else {
        try std.testing.expectError(error.NotFound, f.retry(enq.id));
    }
}

fn probe_claim_harvests_due_scheduled(f: *Fixture) !void {
    const due = nowMs() + 100;
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue, .run_at_ms = due });
    std.time.sleep(250 * std.time.ns_per_ms);
    // postgres: claim does NOT return it (status scheduled, promote required)
    // redis: claim harvests it and returns it
    const claimed = try f.claim(1);
    if (f.backend == .postgres) {
        try std.testing.expectEqual(@as(usize, 0), claimed.len);
    } else {
        try std.testing.expectEqual(@as(usize, 1), claimed.len);
    }
}

fn probe_claimed_run_at(f: *Fixture) !void {
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    if (f.backend == .postgres) {
        try std.testing.expect(claimed[0].run_at_ms > 0);
    } else {
        try std.testing.expectEqual(@as(i64, 0), claimed[0].run_at_ms);
    }
}

fn probe_claimed_args_normalized(f: *Fixture) !void {
    _ = try f.enqueue("ct.kind", "{\"n\":7}", .{ .queue = f.queue });
    const claimed = try f.claim(1);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    if (f.backend == .postgres) {
        // normalized: contains ": " separator
        try std.testing.expect(std.mem.indexOf(u8, claimed[0].args_json, ": ") != null);
    } else {
        // verbatim: no space after colon
        try std.testing.expect(std.mem.indexOf(u8, claimed[0].args_json, ": ") == null);
    }
}

fn probe_promote_reap_global(f: *Fixture) !void {
    // enqueue a scheduled job in another queue, then call promote with only
    // this queue's name; under postgres the global promote also promotes it.
    const other_q = try f.alloc.dupe(u8, "ct-other-promote-q");
    defer f.alloc.free(other_q);
    const due = nowMs() + 100;
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = other_q, .run_at_ms = due });
    std.time.sleep(250 * std.time.ns_per_ms);
    _ = try f.promote(&.{f.queue}, 100);
    const other_depth = blk: {
        var d = broker.Depth{};
        try f.broker.depth(other_q, &d);
        break :blk d;
    };
    if (f.backend == .postgres) {
        try std.testing.expectEqual(@as(u64, 1), other_depth.available);
        try std.testing.expectEqual(@as(u64, 0), other_depth.scheduled);
    } else {
        try std.testing.expectEqual(@as(u64, 0), other_depth.available);
        try std.testing.expectEqual(@as(u64, 1), other_depth.scheduled);
    }
    _ = try harness.purge(f.backend, f.broker, other_q);
}

fn probe_events_at_ms(f: *Fixture) !void {
    const enq = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const c = try f.claim(1);
    try f.finish(enq.id, c[0].lease_epoch);
    const evs = try f.events(enq.id);
    try std.testing.expect(evs.len >= 1);
    if (f.backend == .postgres) {
        try std.testing.expect(evs[0].at_ms > 0);
    } else {
        try std.testing.expectEqual(@as(i64, 0), evs[0].at_ms);
    }
}

fn probe_oldest_available_ms(f: *Fixture) !void {
    _ = try f.enqueue("ct.kind", "{}", .{ .queue = f.queue });
    const d = try f.depth();
    if (f.backend == .postgres) {
        try std.testing.expect(d.oldest_available_ms > 0);
    } else {
        try std.testing.expectEqual(@as(i64, 0), d.oldest_available_ms);
    }
}

// ---------------------------------------------------------------- case list

pub const contract_cases = [_]harness.Case{
    .{ .name = "enqueue-immediately-available", .queue = "enqueue-now", .run = case_enqueue_now_available },
    .{ .name = "enqueue-future-is-scheduled", .queue = "enqueue-future", .run = case_enqueue_future_scheduled },
    .{ .name = "promote-due-scheduled", .queue = "promote-due", .run = case_promote_due_scheduled },
    .{ .name = "claim-returns-enqueued-job", .queue = "claim-basic", .run = case_claim_returns_enqueued },
    .{ .name = "claim-empty-queue", .queue = "claim-empty", .run = case_claim_empty_queue },
    .{ .name = "claim-respects-limit", .queue = "claim-limit", .run = case_claim_respects_limit },
    .{ .name = "claim-no-duplicate", .queue = "claim-nodup", .run = case_claim_no_duplicate },
    .{ .name = "claim-increments-attempts", .queue = "claim-attempts", .run = case_claim_increments_attempts },
    .{ .name = "claim-epoch-increases", .queue = "claim-epoch", .run = case_claim_epoch_increases },
    .{ .name = "finish-marks-completed", .queue = "finish-basic", .run = case_finish_marks_completed },
    .{ .name = "finish-stale-epoch-rejected", .queue = "finish-stale", .run = case_finish_stale_epoch_rejected },
    .{ .name = "finish-twice-rejected", .queue = "finish-twice", .run = case_finish_twice_rejected },
    .{ .name = "fail-retryable-returns-available", .queue = "fail-retry", .run = case_fail_retryable_returns_available },
    .{ .name = "fail-retryable-at-max-goes-dead", .queue = "fail-max", .run = case_fail_retryable_at_max_goes_dead },
    .{ .name = "fail-nonretryable-goes-dead", .queue = "fail-dead", .run = case_fail_nonretryable_goes_dead },
    .{ .name = "fail-stale-epoch-rejected", .queue = "fail-stale", .run = case_fail_stale_epoch_rejected },
    .{ .name = "cancel-available", .queue = "cancel-avail", .run = case_cancel_available },
    .{ .name = "cancel-running-with-epoch", .queue = "cancel-run", .run = case_cancel_running_with_epoch },
    .{ .name = "cancel-running-wrong-epoch", .queue = "cancel-wrong", .run = case_cancel_running_wrong_epoch },
    .{ .name = "cancel-unknown", .queue = "cancel-unk", .run = case_cancel_unknown },
    .{ .name = "discard-available", .queue = "discard-avail", .run = case_discard_available },
    .{ .name = "operator-retry-dead", .queue = "retry-dead", .run = case_operator_retry_dead },
    .{ .name = "reap-requeues-expired", .queue = "reap-requeue", .run = case_reap_requeues_expired },
    .{ .name = "reap-dead-when-exhausted", .queue = "reap-dead", .run = case_reap_dead_when_exhausted },
    .{ .name = "reap-dead-after-lease-losses", .queue = "reap-losses", .run = case_reap_dead_after_lease_losses },
    .{ .name = "reap-lease-loss-bound-disabled", .queue = "reap-nolimit", .run = case_reap_lease_loss_bound_disabled },
    .{ .name = "replay-resets-lease-losses", .queue = "replay-losses", .run = case_replay_resets_lease_losses },
    .{ .name = "heartbeat-extends-lease", .queue = "hb-extend", .run = case_heartbeat_extends_lease },
    .{ .name = "heartbeat-stale-epoch-noop", .queue = "hb-stale", .run = case_heartbeat_stale_epoch_noop },
    .{ .name = "unique-dedupes-pending", .queue = "uniq-pend", .run = case_unique_dedupes_pending },
    .{ .name = "unique-released-after-completion", .queue = "uniq-release", .run = case_unique_released_after_completion },
    .{ .name = "unique-not-deduped-across-queues", .queue = "uniq-queue", .run = case_unique_not_deduped_across_queues },
    .{ .name = "unique-not-deduped-across-kinds", .queue = "uniq-kind", .run = case_unique_not_deduped_across_kinds },
    .{ .name = "dedup-run-id-dedupes", .queue = "dedup-run", .run = case_dedup_run_id_dedupes },
    .{ .name = "replace-unique-unsupported", .queue = "uniq-replace", .run = case_replace_unique_unsupported },
    .{ .name = "promote-not-before-due", .queue = "promote-not", .run = case_promote_not_before_due },
    .{ .name = "promote-after-due", .queue = "promote-due", .run = case_promote_after_due },
    .{ .name = "depth-tracks-states", .queue = "depth-states", .run = case_depth_tracks_states },
    .{ .name = "depth-empty", .queue = "depth-empty", .run = case_depth_empty },
    .{ .name = "get-job-unknown-id", .queue = "get-unknown", .run = case_get_job_unknown },
    .{ .name = "get-job-returns-row", .queue = "get-row", .run = case_get_job_returns_row },
    .{ .name = "list-jobs-filters", .queue = "list-filter", .run = case_list_jobs_filters },
    .{ .name = "queue-names-includes-queue", .queue = "qnames", .run = case_queue_names_includes },
    .{ .name = "event-trail-lifecycle", .queue = "events-life", .run = case_event_trail },
    .{ .name = "event-trail-dead", .queue = "events-dead", .run = case_event_trail_dead },
    .{ .name = "args-round-trip", .queue = "args-rt", .run = case_args_round_trip },
    .{ .name = "context-round-trip", .queue = "ctx-rt", .run = case_context_round_trip },
    .{ .name = "retry-not-claimable-until-run-at", .queue = "retry-not", .run = case_retry_not_claimable_until_run_at },
    .{ .name = "retry-claimable-after-run-at", .queue = "retry-yes", .run = case_retry_claimable_after_run_at },
    .{ .name = "capabilities-named-backend", .queue = "caps-name", .run = case_capabilities_named_backend },
    .{ .name = "capabilities-transactional-enqueue", .queue = "caps-tx", .run = case_capabilities_transactional_enqueue },
    .{ .name = "transactional-enqueue-commit-rollback", .queue = "tx-enq", .run = case_transactional_enqueue },
};

pub const divergence_probes = [_]harness.Probe{
    .{ .name = "unique-key-released-after-dead", .queue = "probe-uniq-dead", .backend = .postgres, .run = probe_unique_released_after_dead },
    .{ .name = "unique-key-released-after-dead", .queue = "probe-uniq-dead", .backend = .redis, .run = probe_unique_released_after_dead },
    .{ .name = "operator-retry-accepts-discarded", .queue = "probe-retry-disc", .backend = .postgres, .run = probe_retry_accepts_discarded },
    .{ .name = "operator-retry-accepts-discarded", .queue = "probe-retry-disc", .backend = .redis, .run = probe_retry_accepts_discarded },
    .{ .name = "claim-harvests-due-scheduled", .queue = "probe-claim-harvest", .backend = .postgres, .run = probe_claim_harvests_due_scheduled },
    .{ .name = "claim-harvests-due-scheduled", .queue = "probe-claim-harvest", .backend = .redis, .run = probe_claim_harvests_due_scheduled },
    .{ .name = "claimed-run-at-is-epoch-vs-zero", .queue = "probe-runat", .backend = .postgres, .run = probe_claimed_run_at },
    .{ .name = "claimed-run-at-is-epoch-vs-zero", .queue = "probe-runat", .backend = .redis, .run = probe_claimed_run_at },
    .{ .name = "claimed-args-json-normalized", .queue = "probe-argsnorm", .backend = .postgres, .run = probe_claimed_args_normalized },
    .{ .name = "claimed-args-json-normalized", .queue = "probe-argsnorm", .backend = .redis, .run = probe_claimed_args_normalized },
    .{ .name = "promote-and-reap-are-global-vs-per-queue", .queue = "probe-global", .backend = .postgres, .run = probe_promote_reap_global },
    .{ .name = "promote-and-reap-are-global-vs-per-queue", .queue = "probe-global", .backend = .redis, .run = probe_promote_reap_global },
    .{ .name = "event-trail-at-ms-populated", .queue = "probe-evat", .backend = .postgres, .run = probe_events_at_ms },
    .{ .name = "event-trail-at-ms-populated", .queue = "probe-evat", .backend = .redis, .run = probe_events_at_ms },
    .{ .name = "oldest-available-ms-populated", .queue = "probe-oldest", .backend = .postgres, .run = probe_oldest_available_ms },
    .{ .name = "oldest-available-ms-populated", .queue = "probe-oldest", .backend = .redis, .run = probe_oldest_available_ms },
};
