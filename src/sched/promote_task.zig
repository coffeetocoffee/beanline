const std = @import("std");
const broker_mod = @import("../broker/broker.zig");

pub const Kind = enum { promoter, reaper };

pub const Task = struct {
    kind: Kind,
    queues: []const []const u8,
    interval_ms: i64,
    limit: u32 = 1000,
    next_due_ms: i64 = 0,

    pub fn step(self: *Task, br: broker_mod.Broker, now_ms: i64) !?u32 {
        if (now_ms < self.next_due_ms) return null;
        const n: u32 = switch (self.kind) {
            .promoter => try br.promote(self.queues, self.limit),
            .reaper => try br.reap(self.queues, self.limit),
        };
        self.next_due_ms = now_ms + self.interval_ms;
        return n;
    }
};

const Mock = struct {
    promote_calls: usize = 0,
    reap_calls: usize = 0,
    n: u32 = 7,

    fn enqueueCb(_: *anyopaque, _: []const u8, _: []const u8, _: broker_mod.EnqueueOptions, _: *broker_mod.Enqueued) anyerror!void {
        return error.Unsupported;
    }
    fn claimCb(_: *anyopaque, _: []const u8, _: u32, _: []const u8, _: u64, _: []broker_mod.Claimed) anyerror!usize {
        return error.Unsupported;
    }
    fn heartbeatCb(_: *anyopaque, _: []const u8, _: []const i64, _: []const u64, _: u64) anyerror!void {
        return error.Unsupported;
    }
    fn finishCb(_: *anyopaque, _: []const u8, _: i64, _: u64) anyerror!void {
        return error.Unsupported;
    }
    fn failCb(_: *anyopaque, _: []const u8, _: i64, _: u64, _: []const u8, _: broker_mod.Failure, _: *broker_mod.FailOutcome) anyerror!void {
        return error.Unsupported;
    }
    fn cancelCb(_: *anyopaque, _: []const u8, _: i64, _: ?u64) anyerror!void {
        return error.Unsupported;
    }
    fn promoteCb(ctx: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        self.promote_calls += 1;
        return self.n;
    }
    fn reapCb(ctx: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        self.reap_calls += 1;
        return self.n;
    }
    fn depthCb(_: *anyopaque, _: []const u8, _: *broker_mod.Depth) anyerror!void {
        return error.Unsupported;
    }
    fn capabilitiesCb() broker_mod.Capabilities {
        return .{ .transactional_enqueue = false, .pubsub_wakeups = false, .named_backend = "mock" };
    }
    fn deinitCb(_: *anyopaque) void {}

    const vt = broker_mod.VTable{
        .enqueue = enqueueCb,
        .claim = claimCb,
        .heartbeat = heartbeatCb,
        .finish = finishCb,
        .fail = failCb,
        .cancel = cancelCb,
        .promote = promoteCb,
        .reap = reapCb,
        .depth = depthCb,
        .capabilities = capabilitiesCb,
        .deinit = deinitCb,
    };

    fn broker(self: *Mock) broker_mod.Broker {
        return .{ .ptr = self, .vtable = &vt };
    }
};

test "promoter and reaper interval gating" {
    var m = Mock{};
    const br = m.broker();
    const qs = [_][]const u8{ "a", "b" };

    var t = Task{ .kind = .promoter, .queues = &qs, .interval_ms = 1000 };
    try std.testing.expectEqual(@as(?u32, 7), try t.step(br, 0));
    try std.testing.expectEqual(@as(?u32, null), try t.step(br, 500));
    try std.testing.expectEqual(@as(?u32, 7), try t.step(br, 1001));
    try std.testing.expectEqual(@as(usize, 2), m.promote_calls);
    try std.testing.expectEqual(@as(usize, 0), m.reap_calls);

    var r = Task{ .kind = .reaper, .queues = &qs, .interval_ms = 5000, .limit = 5 };
    try std.testing.expectEqual(@as(?u32, 7), try r.step(br, 1001));
    try std.testing.expectEqual(@as(usize, 1), m.reap_calls);
    try std.testing.expectEqual(@as(i64, 6001), r.next_due_ms);
}
