const std = @import("std");
const cron = @import("cron.zig");
const tz = @import("tz.zig");
const civil = @import("civil.zig");
const broker_mod = @import("../broker/broker.zig");

pub const Misfire = enum { skip, fire_once, catch_up };

pub const Entry = struct {
    id: []const u8,
    kind: []const u8,
    queue: []const u8 = "default",
    args_json: []const u8 = "{}",
    cron_expr: []const u8,
    zone_name: []const u8 = "UTC",
    misfire: Misfire = .skip,
    jitter_ms: u32 = 5000,
    catch_up_limit: u32 = 100,
    enabled: bool = true,
};

pub const FireRequest = struct {
    kind: []const u8,
    queue: []const u8,
    args_json: []const u8,
    run_at_ms: i64,
    run_id: []const u8,
};

pub const Sink = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, req: FireRequest) anyerror!void,

    pub fn emit(self: Sink, req: FireRequest) anyerror!void {
        return self.call(self.ptr, req);
    }
};

fn fnv1a(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn wallKey(alloc: std.mem.Allocator, id: []const u8, zone: *const tz.Zone, u: i64) ![]const u8 {
    const wall = zone.toLocal(u).wall;
    const c = civil.civilFromDays(civil.floorDiv(wall, 86400));
    const sod = civil.floorMod(wall, 86400);
    return std.fmt.allocPrint(alloc, "{s}@{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}", .{
        id,
        @as(u16, @intCast(c.year)),
        @as(u8, @intCast(c.month)),
        @as(u8, @intCast(c.day)),
        @as(u8, @intCast(@divTrunc(sod, 3600))),
        @as(u8, @intCast(@mod(@divTrunc(sod, 60), 60))),
    });
}

const Compiled = struct {
    entry: Entry,
    sched: cron.Schedule,
    zone: tz.Zone,
};

pub const Scheduler = struct {
    alloc: std.mem.Allocator,
    compiled: std.ArrayList(Compiled),
    last_utc: std.ArrayList(i64),
    anchored: bool = false,
    scratch: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) Scheduler {
        return .{
            .alloc = alloc,
            .compiled = std.ArrayList(Compiled).init(alloc),
            .last_utc = std.ArrayList(i64).init(alloc),
            .scratch = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.compiled.items) |*c| {
            var z = c.zone;
            z.free(self.alloc);
        }
        self.compiled.deinit();
        self.last_utc.deinit();
        self.scratch.deinit();
    }

    pub fn add(self: *Scheduler, e: Entry) !void {
        const sched = try cron.Schedule.parse(e.cron_expr);
        var zone = (try tz.load(self.alloc, e.zone_name)) orelse return error.UnknownZone;
        errdefer zone.free(self.alloc);
        try self.compiled.append(.{ .entry = e, .sched = sched, .zone = zone });
        try self.last_utc.append(0);
    }

    pub fn entryCount(self: *const Scheduler) usize {
        return self.compiled.items.len;
    }

    pub fn tick(self: *Scheduler, now_ms: i64, sink: Sink) !usize {
        const now = @divFloor(now_ms, 1000);
        if (!self.anchored) {
            for (self.last_utc.items) |*l| l.* = now;
            self.anchored = true;
            return 0;
        }
        var fired: usize = 0;
        for (self.compiled.items, self.last_utc.items) |*cp, *last| {
            if (!cp.entry.enabled) continue;
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const al = arena.allocator();

            var fires = std.ArrayList(i64).init(al);
            var cursor = last.*;
            while (fires.items.len < 1000) {
                const u = cp.sched.nextIn(&cp.zone, cursor) orelse break;
                if (u > now) break;
                try fires.append(u);
                cursor = u;
            }
            last.* = now;
            if (fires.items.len == 0) continue;

            switch (cp.entry.misfire) {
                .skip => {
                    const u = fires.items[fires.items.len - 1];
                    fired += try self.emit(cp, u, now_ms, al, sink);
                },
                .fire_once => {
                    const u = fires.items[0];
                    fired += try self.emit(cp, u, now_ms, al, sink);
                },
                .catch_up => {
                    const max: usize = @min(fires.items.len, cp.entry.catch_up_limit);
                    for (fires.items[0..max]) |u| {
                        fired += try self.emit(cp, u, u * 1000, al, sink);
                    }
                },
            }
        }
        return fired;
    }

    fn emit(self: *Scheduler, cp: *Compiled, u: i64, now_ms: i64, al: std.mem.Allocator, sink: Sink) !usize {
        _ = self;
        const run_id = try wallKey(al, cp.entry.id, &cp.zone, u);
        const jitter: i64 = if (cp.entry.jitter_ms > 0) @as(i64, @intCast(fnv1a(run_id) % cp.entry.jitter_ms)) else 0;
        try sink.emit(.{
            .kind = cp.entry.kind,
            .queue = cp.entry.queue,
            .args_json = cp.entry.args_json,
            .run_at_ms = now_ms + jitter,
            .run_id = run_id,
        });
        return 1;
    }
};

pub const BrokerSink = struct {
    br: broker_mod.Broker,
    last_deduped: bool = false,

    fn call(ptr: *anyopaque, req: FireRequest) anyerror!void {
        const self: *BrokerSink = @ptrCast(@alignCast(ptr));
        var out = broker_mod.Enqueued{};
        try self.br.enqueue(req.kind, req.args_json, .{
            .queue = req.queue,
            .run_at_ms = req.run_at_ms,
            .dedup_run_id = req.run_id,
        }, &out);
        self.last_deduped = out.deduped;
    }

    pub fn sink(self: *BrokerSink) Sink {
        return .{ .ptr = self, .call = call };
    }
};

fn discard_cb(_: *anyopaque, _: FireRequest) anyerror!void {}

const discard_sink = Sink{ .ptr = undefined, .call = discard_cb };

const MockSink = struct {
    got: std.ArrayList(FireRequest),
    alloc: std.mem.Allocator,

    fn call(ptr: *anyopaque, req: FireRequest) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const owned = try self.alloc.dupe(u8, req.run_id);
        var copy = req;
        copy.run_id = owned;
        try self.got.append(copy);
    }

    fn sink(self: *@This()) Sink {
        return .{ .ptr = self, .call = call };
    }
};

test "scheduler fires due slots with unique run ids" {
    const alloc = std.testing.allocator;
    var s = Scheduler.init(alloc);
    defer s.deinit();
    try s.add(.{ .id = "five", .kind = "reports.five", .cron_expr = "*/5 * * * *", .jitter_ms = 0 });

    var mock = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer {
        for (mock.got.items) |r| alloc.free(r.run_id);
        mock.got.deinit();
    }

    const t0: i64 = 1767225600 * 1000;
    try std.testing.expectEqual(@as(usize, 0), try s.tick(t0, mock.sink()));
    try std.testing.expectEqual(@as(usize, 1), try s.tick(t0 + 300_000, mock.sink()));
    try std.testing.expectEqual(@as(usize, 0), try s.tick(t0 + 300_000, mock.sink()));
    try std.testing.expectEqual(@as(usize, 1), try s.tick(t0 + 600_000, mock.sink()));
    try std.testing.expectEqual(@as(usize, 2), mock.got.items.len);
    try std.testing.expectEqualStrings("five@2026-01-01T00:05", mock.got.items[0].run_id);
    try std.testing.expectEqualStrings("five@2026-01-01T00:10", mock.got.items[1].run_id);
    try std.testing.expectEqual(t0 + 300_000, mock.got.items[0].run_at_ms);
}

test "misfire skip keeps latest, fire_once keeps first" {
    const alloc = std.testing.allocator;

    var s1 = Scheduler.init(alloc);
    defer s1.deinit();
    try s1.add(.{ .id = "a", .kind = "k", .cron_expr = "* * * * *", .misfire = .skip, .jitter_ms = 0 });
    _ = try s1.tick(1767225600 * 1000, discard_sink);
    s1.last_utc.items[0] = 1767225600 - 180;

    var mock = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer {
        for (mock.got.items) |r| alloc.free(r.run_id);
        mock.got.deinit();
    }
    const t = 1767225600 * 1000;
    try std.testing.expectEqual(@as(usize, 1), try s1.tick(t, mock.sink()));
    try std.testing.expectEqualStrings("a@2026-01-01T00:00", mock.got.items[0].run_id);

    var s2 = Scheduler.init(alloc);
    defer s2.deinit();
    try s2.add(.{ .id = "a", .kind = "k", .cron_expr = "* * * * *", .misfire = .fire_once, .jitter_ms = 0 });
    _ = try s2.tick(t, discard_sink);
    s2.last_utc.items[0] = 1767225600 - 180;
    var mock2 = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer {
        for (mock2.got.items) |r| alloc.free(r.run_id);
        mock2.got.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), try s2.tick(t, mock2.sink()));
    try std.testing.expectEqualStrings("a@2025-12-31T23:58", mock2.got.items[0].run_id);
}

test "catch up enqueues every missed slot at original time" {
    const alloc = std.testing.allocator;
    var s = Scheduler.init(alloc);
    defer s.deinit();
    try s.add(.{ .id = "c", .kind = "k", .cron_expr = "* * * * *", .misfire = .catch_up, .jitter_ms = 0 });
    const t: i64 = 1767225600 * 1000;
    _ = try s.tick(t, discard_sink);
    s.last_utc.items[0] = 1767225600 - 180;

    var mock = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer {
        for (mock.got.items) |r| alloc.free(r.run_id);
        mock.got.deinit();
    }
    try std.testing.expectEqual(@as(usize, 3), try s.tick(t, mock.sink()));
    try std.testing.expectEqual(t - 120_000, mock.got.items[0].run_at_ms);
    try std.testing.expectEqual(t - 60_000, mock.got.items[1].run_at_ms);
    try std.testing.expectEqual(t, mock.got.items[2].run_at_ms);
}

test "jitter is deterministic per run id" {
    const alloc = std.testing.allocator;
    var s1 = Scheduler.init(alloc);
    defer s1.deinit();
    try s1.add(.{ .id = "j", .kind = "k", .cron_expr = "*/5 * * * *", .jitter_ms = 5000 });
    var m1 = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer {
        for (m1.got.items) |r| alloc.free(r.run_id);
        m1.got.deinit();
    }
    const t0: i64 = 1767225600 * 1000;
    _ = try s1.tick(t0, m1.sink());
    _ = try s1.tick(t0 + 300_000, m1.sink());

    var s2 = Scheduler.init(alloc);
    defer s2.deinit();
    try s2.add(.{ .id = "j", .kind = "k", .cron_expr = "*/5 * * * *", .jitter_ms = 5000 });
    var m2 = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer {
        for (m2.got.items) |r| alloc.free(r.run_id);
        m2.got.deinit();
    }
    _ = try s2.tick(t0, m2.sink());
    _ = try s2.tick(t0 + 300_000, m2.sink());

    try std.testing.expectEqual(m1.got.items[0].run_at_ms, m2.got.items[0].run_at_ms);
    try std.testing.expect(m1.got.items[0].run_at_ms >= t0 + 300_000);
    try std.testing.expect(m1.got.items[0].run_at_ms < t0 + 305_000);
}

test "scheduler respects enabled flag and unknown zones" {
    const alloc = std.testing.allocator;
    var s = Scheduler.init(alloc);
    defer s.deinit();
    try std.testing.expectError(error.UnknownZone, s.add(.{ .id = "x", .kind = "k", .cron_expr = "* * * * *", .zone_name = "Mars/Olympus" }));

    try s.add(.{ .id = "off", .kind = "k", .cron_expr = "* * * * *", .enabled = false });
    _ = try s.tick(1767225600 * 1000, discard_sink);
    s.last_utc.items[0] -= 120;
    var m = MockSink{ .got = std.ArrayList(FireRequest).init(alloc), .alloc = alloc };
    defer m.got.deinit();
    try std.testing.expectEqual(@as(usize, 0), try s.tick(1767225600 * 1000, m.sink()));
}

test "live scheduler enqueues exactly one job per slot with pg dedup" {
    const alloc = std.testing.allocator;
    const dsn = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_DSN") catch return;
    defer alloc.free(dsn);

    const pg = @import("../broker/postgres.zig");
    const p = try pg.open(alloc, dsn);
    const br = pg.toBroker(p);
    defer br.deinit();

    _ = p.c.execSimple("DELETE FROM beanline_job_events WHERE job_id IN (SELECT id FROM beanline_jobs WHERE queue = 'sched-live')") catch {};
    try p.c.execSimple("DELETE FROM beanline_jobs WHERE queue = 'sched-live'");

    var s = Scheduler.init(alloc);
    defer s.deinit();
    try s.add(.{ .id = "l5", .kind = "reports.live", .queue = "sched-live", .cron_expr = "*/5 * * * *", .jitter_ms = 0 });

    var b_sink = BrokerSink{ .br = br };
    const t0: i64 = 1767225600 * 1000;
    try std.testing.expectEqual(@as(usize, 0), try s.tick(t0, b_sink.sink()));
    try std.testing.expectEqual(@as(usize, 1), try s.tick(t0 + 300_000, b_sink.sink()));
    try std.testing.expectEqual(@as(usize, 0), try s.tick(t0 + 300_000, b_sink.sink()));
    try std.testing.expect(!b_sink.last_deduped);

    var d = broker_mod.Depth{};
    try br.depth("sched-live", &d);
    try std.testing.expectEqual(@as(u64, 1), d.available);

    _ = try s.tick(t0 + 600_000, b_sink.sink());
    try br.depth("sched-live", &d);
    try std.testing.expectEqual(@as(u64, 2), d.available);

    _ = p.c.execSimple("DELETE FROM beanline_job_events WHERE job_id IN (SELECT id FROM beanline_jobs WHERE queue = 'sched-live')") catch {};
    try p.c.execSimple("DELETE FROM beanline_jobs WHERE queue = 'sched-live'");
}
