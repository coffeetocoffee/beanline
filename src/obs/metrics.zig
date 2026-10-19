const std = @import("std");

/// Prometheus-exposition metrics. All counters are atomics so they can be
/// bumped from any thread without a lock; rendering snapshots them into a
/// Prometheus text-format buffer. Mirrors the metric names in architecture
/// doc §15 (beanline_jobs_enqueued_total{kind,queue}, ...).
///
/// Cardinality policy (doc §24c): label values are interned under a hard cap
/// and overflow into a single `__other__` series, so a bad `kind` or queue
/// name can never blow up the scrape. Histograms deliberately carry only
/// low-cardinality labels (`kind`, `outcome`): never attempt numbers, tags,
/// job ids, or worker ids, which belong in traces and the event log.
pub const Metrics = struct {
    // counters: per kind and per queue are kept flat in bounded arrays keyed
    // by an interned string id so we never allocate on the hot path.
    kind_ids: std.StringHashMap(u16),
    kind_names: std.ArrayList([]const u8),
    queue_ids: std.StringHashMap(u16),
    queue_names: std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Hard caps on distinct label values. Zero means unlimited.
    max_kinds: usize,
    max_queues: usize,
    overflowed_kinds: std.atomic.Value(u64),
    overflowed_queues: std.atomic.Value(u64),

    enqueued: std.ArrayList(AtomicCounter),
    completed: std.ArrayList(AtomicCounter),
    failed: std.ArrayList(AtomicCounter),
    dead: std.ArrayList(AtomicCounter),
    reaped: std.ArrayList(AtomicCounter),

    /// Per-kind attempt-duration histograms, one series per outcome.
    duration: std.ArrayList(DurationSeries),
    /// Per-kind enqueue-to-terminal histograms. Wider bounds than `duration`
    /// because retries can span hours (doc §10.2).
    e2e: std.ArrayList(DurationSeries),

    // gauges, keyed by queue id.
    depth_available: std.ArrayList(std.atomic.Value(i64)),
    depth_scheduled: std.ArrayList(std.atomic.Value(i64)),
    depth_running: std.ArrayList(std.atomic.Value(i64)),
    depth_dead: std.ArrayList(std.atomic.Value(i64)),
    depth_completed: std.ArrayList(std.atomic.Value(i64)),
    depth_cancelled: std.ArrayList(std.atomic.Value(i64)),

    claim_duration_us_total: std.atomic.Value(u64),
    claim_duration_us_count: std.atomic.Value(u64),
    scheduler_skipped: std.atomic.Value(u64),
    leader_active: std.atomic.Value(i64),
    started_at_ms: i64,

    pub const overflow_label = "__other__";

    const AtomicCounter = struct {
        total: std.atomic.Value(u64),
        last_window: std.atomic.Value(u64),
    };

    /// Bucket bounds for a per-attempt handler duration, in seconds.
    pub const duration_bounds_s = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 300 };
    /// Bucket bounds for enqueue-to-terminal latency, in seconds. Coarse on
    /// purpose: these span retry backoff up to a weekend outage.
    pub const e2e_bounds_s = [_]f64{ 0.05, 0.25, 1, 5, 30, 300, 3600, 21600, 86400, 604800 };

    const n_buckets = duration_bounds_s.len + 1; // +Inf terminator

    pub const Outcome = enum {
        completed,
        failed,
        dead,
        cancelled,

        pub fn label(self: Outcome) []const u8 {
            return @tagName(self);
        }
    };
    const outcome_count = @typeInfo(Outcome).@"enum".fields.len;

    /// Cumulative counters per outcome, one entry per bucket index plus +Inf,
    /// plus the running sum in microseconds and the observation count.
    const DurationSeries = struct {
        counts: [outcome_count][n_buckets]std.atomic.Value(u64),
        sum_us: [outcome_count]std.atomic.Value(u64),
        observed: [outcome_count]std.atomic.Value(u64),

        fn init() DurationSeries {
            var s = DurationSeries{
                .sum_us = undefined,
                .observed = undefined,
                .counts = undefined,
            };
            for (&s.counts) |*row| {
                for (row) |*c| c.* = std.atomic.Value(u64).init(0);
            }
            for (&s.sum_us) |*v| v.* = std.atomic.Value(u64).init(0);
            for (&s.observed) |*v| v.* = std.atomic.Value(u64).init(0);
            return s;
        }
    };

    pub const Limits = struct {
        max_kinds: usize = 500,
        max_queues: usize = 200,
    };

    pub fn init(alloc: std.mem.Allocator) Metrics {
        return initWithLimits(alloc, .{});
    }

    pub fn initWithLimits(alloc: std.mem.Allocator, limits: Limits) Metrics {
        return .{
            .alloc = alloc,
            .kind_ids = std.StringHashMap(u16).init(alloc),
            .kind_names = std.ArrayList([]const u8).init(alloc),
            .queue_ids = std.StringHashMap(u16).init(alloc),
            .queue_names = std.ArrayList([]const u8).init(alloc),
            .max_kinds = limits.max_kinds,
            .max_queues = limits.max_queues,
            .overflowed_kinds = std.atomic.Value(u64).init(0),
            .overflowed_queues = std.atomic.Value(u64).init(0),
            .enqueued = std.ArrayList(AtomicCounter).init(alloc),
            .completed = std.ArrayList(AtomicCounter).init(alloc),
            .failed = std.ArrayList(AtomicCounter).init(alloc),
            .dead = std.ArrayList(AtomicCounter).init(alloc),
            .reaped = std.ArrayList(AtomicCounter).init(alloc),
            .duration = std.ArrayList(DurationSeries).init(alloc),
            .e2e = std.ArrayList(DurationSeries).init(alloc),
            .depth_available = std.ArrayList(std.atomic.Value(i64)).init(alloc),
            .depth_scheduled = std.ArrayList(std.atomic.Value(i64)).init(alloc),
            .depth_running = std.ArrayList(std.atomic.Value(i64)).init(alloc),
            .depth_dead = std.ArrayList(std.atomic.Value(i64)).init(alloc),
            .depth_completed = std.ArrayList(std.atomic.Value(i64)).init(alloc),
            .depth_cancelled = std.ArrayList(std.atomic.Value(i64)).init(alloc),
            .claim_duration_us_total = std.atomic.Value(u64).init(0),
            .claim_duration_us_count = std.atomic.Value(u64).init(0),
            .scheduler_skipped = std.atomic.Value(u64).init(0),
            .leader_active = std.atomic.Value(i64).init(0),
            .started_at_ms = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Metrics) void {
        for (self.kind_names.items) |k| self.alloc.free(k);
        for (self.queue_names.items) |q| self.alloc.free(q);
        self.kind_ids.deinit();
        self.kind_names.deinit();
        self.queue_ids.deinit();
        self.queue_names.deinit();
        self.enqueued.deinit();
        self.completed.deinit();
        self.failed.deinit();
        self.dead.deinit();
        self.reaped.deinit();
        self.duration.deinit();
        self.e2e.deinit();
        self.depth_available.deinit();
        self.depth_scheduled.deinit();
        self.depth_running.deinit();
        self.depth_dead.deinit();
        self.depth_completed.deinit();
        self.depth_cancelled.deinit();
    }

    fn addKind(self: *Metrics, owned: []const u8) !u16 {
        const id: u16 = @intCast(self.kind_names.items.len);
        try self.kind_names.append(owned);
        try self.enqueued.append(.{ .total = std.atomic.Value(u64).init(0), .last_window = std.atomic.Value(u64).init(0) });
        try self.completed.append(.{ .total = std.atomic.Value(u64).init(0), .last_window = std.atomic.Value(u64).init(0) });
        try self.failed.append(.{ .total = std.atomic.Value(u64).init(0), .last_window = std.atomic.Value(u64).init(0) });
        try self.dead.append(.{ .total = std.atomic.Value(u64).init(0), .last_window = std.atomic.Value(u64).init(0) });
        try self.reaped.append(.{ .total = std.atomic.Value(u64).init(0), .last_window = std.atomic.Value(u64).init(0) });
        try self.duration.append(DurationSeries.init());
        try self.e2e.append(DurationSeries.init());
        try self.kind_ids.put(owned, id);
        return id;
    }

    /// Returns the interned id for `name`, or the shared overflow id when the
    /// cap is hit. Never fails the caller: metrics must not break the worker.
    fn internKind(self: *Metrics, name: []const u8) u16 {
        if (self.kind_ids.get(name)) |id| return id;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.kind_ids.get(name)) |id| return id;
        if (self.max_kinds != 0 and self.kind_names.items.len >= self.max_kinds) {
            if (self.kind_ids.get(overflow_label)) |id| return id;
            _ = self.overflowed_kinds.fetchAdd(1, .monotonic);
            const owned = self.alloc.dupe(u8, overflow_label) catch return 0;
            return self.addKind(owned) catch 0;
        }
        const owned = self.alloc.dupe(u8, name) catch return 0;
        return self.addKind(owned) catch 0;
    }

    fn addQueue(self: *Metrics, owned: []const u8) !u16 {
        const id: u16 = @intCast(self.queue_names.items.len);
        try self.queue_names.append(owned);
        try self.depth_available.append(std.atomic.Value(i64).init(0));
        try self.depth_scheduled.append(std.atomic.Value(i64).init(0));
        try self.depth_running.append(std.atomic.Value(i64).init(0));
        try self.depth_dead.append(std.atomic.Value(i64).init(0));
        try self.depth_completed.append(std.atomic.Value(i64).init(0));
        try self.depth_cancelled.append(std.atomic.Value(i64).init(0));
        try self.queue_ids.put(owned, id);
        return id;
    }

    fn internQueue(self: *Metrics, name: []const u8) u16 {
        if (self.queue_ids.get(name)) |id| return id;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue_ids.get(name)) |id| return id;
        if (self.max_queues != 0 and self.queue_names.items.len >= self.max_queues) {
            if (self.queue_ids.get(overflow_label)) |id| return id;
            _ = self.overflowed_queues.fetchAdd(1, .monotonic);
            const owned = self.alloc.dupe(u8, overflow_label) catch return 0;
            return self.addQueue(owned) catch 0;
        }
        const owned = self.alloc.dupe(u8, name) catch return 0;
        return self.addQueue(owned) catch 0;
    }

    pub fn incrEnqueued(self: *Metrics, kind: []const u8, queue: []const u8) void {
        const k = self.internKind(kind);
        _ = self.internQueue(queue);
        if (k >= self.enqueued.items.len) return;
        _ = self.enqueued.items[k].total.fetchAdd(1, .monotonic);
    }

    pub fn incrCompleted(self: *Metrics, kind: []const u8) void {
        const k = self.internKind(kind);
        if (k >= self.completed.items.len) return;
        _ = self.completed.items[k].total.fetchAdd(1, .monotonic);
    }

    pub fn incrFailed(self: *Metrics, kind: []const u8) void {
        const k = self.internKind(kind);
        if (k >= self.failed.items.len) return;
        _ = self.failed.items[k].total.fetchAdd(1, .monotonic);
    }

    pub fn incrDead(self: *Metrics, kind: []const u8) void {
        const k = self.internKind(kind);
        if (k >= self.dead.items.len) return;
        _ = self.dead.items[k].total.fetchAdd(1, .monotonic);
    }

    pub fn incrReaped(self: *Metrics, kind: []const u8) void {
        const k = self.internKind(kind);
        if (k >= self.reaped.items.len) return;
        _ = self.reaped.items[k].total.fetchAdd(1, .monotonic);
    }

    pub fn setQueueDepth(self: *Metrics, queue: []const u8, available: i64, scheduled: i64, running: i64, dead: i64) void {
        self.setQueueDepthFull(queue, available, scheduled, running, dead, 0, 0);
    }

    pub fn setQueueDepthFull(self: *Metrics, queue: []const u8, available: i64, scheduled: i64, running: i64, dead: i64, completed: i64, cancelled: i64) void {
        const q = self.internQueue(queue);
        if (q >= self.depth_available.items.len) return;
        self.depth_available.items[q].store(available, .monotonic);
        self.depth_scheduled.items[q].store(scheduled, .monotonic);
        self.depth_running.items[q].store(running, .monotonic);
        self.depth_dead.items[q].store(dead, .monotonic);
        self.depth_completed.items[q].store(completed, .monotonic);
        self.depth_cancelled.items[q].store(cancelled, .monotonic);
    }

    pub fn observeClaim(self: *Metrics, elapsed_us: u64) void {
        _ = self.claim_duration_us_total.fetchAdd(elapsed_us, .monotonic);
        _ = self.claim_duration_us_count.fetchAdd(1, .monotonic);
    }

    /// Per-attempt handler duration. Labelled by `kind` and `outcome` only.
    pub fn observeJobDuration(self: *Metrics, kind: []const u8, outcome: Outcome, micros: u64) void {
        const k = self.internKind(kind);
        if (k >= self.duration.items.len) return;
        observe(&self.duration.items[k], outcome, micros, &duration_bounds_s);
    }

    /// Enqueue-to-terminal latency for one attempt. Kept separate from the
    /// handler histogram because retry backoff makes the distribution far
    /// wider, and folding the two together would poison the p99.
    pub fn observeE2E(self: *Metrics, kind: []const u8, outcome: Outcome, micros: u64) void {
        const k = self.internKind(kind);
        if (k >= self.e2e.items.len) return;
        observe(&self.e2e.items[k], outcome, micros, &e2e_bounds_s);
    }

    fn observe(series: *DurationSeries, outcome: Outcome, micros: u64, comptime bounds: []const f64) void {
        const o: usize = @intFromEnum(outcome);
        const secs = @as(f64, @floatFromInt(micros)) / 1_000_000.0;
        var idx: usize = bounds.len; // +Inf
        for (bounds, 0..) |b, i| {
            if (secs <= b) {
                idx = i;
                break;
            }
        }
        _ = series.counts[o][idx].fetchAdd(1, .monotonic);
        _ = series.sum_us[o].fetchAdd(micros, .monotonic);
        _ = series.observed[o].fetchAdd(1, .monotonic);
    }

    pub fn incrSchedulerSkipped(self: *Metrics) void {
        _ = self.scheduler_skipped.fetchAdd(1, .monotonic);
    }

    pub fn setLeaderActive(self: *Metrics, v: bool) void {
        self.leader_active.store(@intFromBool(v), .monotonic);
    }

    fn writeLabeledCounter(w: anytype, name: []const u8, kind: []const u8, value: u64) !void {
        try w.print("{s}{{kind=\"{s}\"}} {d}\n", .{ name, kind, value });
    }

    fn writeHistogram(
        w: anytype,
        name: []const u8,
        help: []const u8,
        kind: []const u8,
        series: *const DurationSeries,
        comptime bounds: []const f64,
    ) !void {
        try w.print("# HELP {s} {s}\n", .{ name, help });
        try w.print("# TYPE {s} histogram\n", .{name});
        for (0..outcome_count) |o| {
            const outcome: Outcome = @enumFromInt(o);
            var cumulative: u64 = 0;
            for (bounds, 0..) |b, i| {
                cumulative += series.counts[o][i].load(.monotonic);
                try w.print("{s}_bucket{{kind=\"{s}\",outcome=\"{s}\",le=\"{d}\"}} {d}\n", .{
                    name, kind, outcome.label(), b, cumulative,
                });
            }
            cumulative += series.counts[o][bounds.len].load(.monotonic);
            try w.print("{s}_bucket{{kind=\"{s}\",outcome=\"{s}\",le=\"+Inf\"}} {d}\n", .{
                name, kind, outcome.label(), cumulative,
            });
            const count = series.observed[o].load(.monotonic);
            try w.print("{s}_sum{{kind=\"{s}\",outcome=\"{s}\"}} {d}\n", .{
                name, kind, outcome.label(), @as(f64, @floatFromInt(series.sum_us[o].load(.monotonic))) / 1_000_000.0,
            });
            try w.print("{s}_count{{kind=\"{s}\",outcome=\"{s}\"}} {d}\n", .{ name, kind, outcome.label(), count });
        }
    }

    /// Render the full Prometheus text exposition. Caller owns the returned
    /// string.
    pub fn render(self: *Metrics, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(alloc);
        errdefer out.deinit();
        const w = out.writer();

        try w.writeAll("# HELP beanline_jobs_enqueued_total Jobs enqueued.\n");
        try w.writeAll("# TYPE beanline_jobs_enqueued_total counter\n");
        for (self.kind_names.items, self.enqueued.items) |k, c| {
            try writeLabeledCounter(w, "beanline_jobs_enqueued_total", k, c.total.load(.monotonic));
        }

        try w.writeAll("# HELP beanline_jobs_completed_total Jobs completed.\n");
        try w.writeAll("# TYPE beanline_jobs_completed_total counter\n");
        for (self.kind_names.items, self.completed.items) |k, c| {
            try writeLabeledCounter(w, "beanline_jobs_completed_total", k, c.total.load(.monotonic));
        }

        try w.writeAll("# HELP beanline_jobs_failed_total Jobs that failed (retryable).\n");
        try w.writeAll("# TYPE beanline_jobs_failed_total counter\n");
        for (self.kind_names.items, self.failed.items) |k, c| {
            try writeLabeledCounter(w, "beanline_jobs_failed_total", k, c.total.load(.monotonic));
        }

        try w.writeAll("# HELP beanline_jobs_dead_total Jobs that landed in the dead letter queue.\n");
        try w.writeAll("# TYPE beanline_jobs_dead_total counter\n");
        for (self.kind_names.items, self.dead.items) |k, c| {
            try writeLabeledCounter(w, "beanline_jobs_dead_total", k, c.total.load(.monotonic));
        }

        try w.writeAll("# HELP beanline_jobs_reaped_total Jobs reclaimed from expired leases.\n");
        try w.writeAll("# TYPE beanline_jobs_reaped_total counter\n");
        for (self.kind_names.items, self.reaped.items) |k, c| {
            try writeLabeledCounter(w, "beanline_jobs_reaped_total", k, c.total.load(.monotonic));
        }

        try w.writeAll("# HELP beanline_job_duration_seconds Handler duration per attempt.\n");
        try w.writeAll("# TYPE beanline_job_duration_seconds histogram\n");
        for (self.kind_names.items, 0..) |k, i| {
            try writeHistogram(w, "beanline_job_duration_seconds", "Handler duration per attempt.", k, &self.duration.items[i], &duration_bounds_s);
        }

        try w.writeAll("# HELP beanline_job_e2e_seconds Enqueue to terminal-state latency.\n");
        try w.writeAll("# TYPE beanline_job_e2e_seconds histogram\n");
        for (self.kind_names.items, 0..) |k, i| {
            try writeHistogram(w, "beanline_job_e2e_seconds", "Enqueue to terminal-state latency.", k, &self.e2e.items[i], &e2e_bounds_s);
        }

        try w.writeAll("# HELP beanline_queue_depth Current jobs by state per queue.\n");
        try w.writeAll("# TYPE beanline_queue_depth gauge\n");
        for (self.queue_names.items, 0..) |q, i| {
            try w.print("beanline_queue_depth{{queue=\"{s}\",state=\"available\"}} {d}\n", .{ q, self.depth_available.items[i].load(.monotonic) });
        }
        for (self.queue_names.items, 0..) |q, i| {
            try w.print("beanline_queue_depth{{queue=\"{s}\",state=\"scheduled\"}} {d}\n", .{ q, self.depth_scheduled.items[i].load(.monotonic) });
        }
        for (self.queue_names.items, 0..) |q, i| {
            try w.print("beanline_queue_depth{{queue=\"{s}\",state=\"running\"}} {d}\n", .{ q, self.depth_running.items[i].load(.monotonic) });
        }
        for (self.queue_names.items, 0..) |q, i| {
            try w.print("beanline_queue_depth{{queue=\"{s}\",state=\"dead\"}} {d}\n", .{ q, self.depth_dead.items[i].load(.monotonic) });
        }
        for (self.queue_names.items, 0..) |q, i| {
            try w.print("beanline_queue_depth{{queue=\"{s}\",state=\"completed\"}} {d}\n", .{ q, self.depth_completed.items[i].load(.monotonic) });
        }
        for (self.queue_names.items, 0..) |q, i| {
            try w.print("beanline_queue_depth{{queue=\"{s}\",state=\"cancelled\"}} {d}\n", .{ q, self.depth_cancelled.items[i].load(.monotonic) });
        }

        try w.writeAll("# HELP beanline_claim_duration_seconds Job claim duration.\n");
        try w.writeAll("# TYPE beanline_claim_duration_seconds summary\n");
        const cnt = self.claim_duration_us_count.load(.monotonic);
        const total_us = self.claim_duration_us_total.load(.monotonic);
        try w.print("beanline_claim_duration_seconds_sum {d}\n", .{@as(f64, @floatFromInt(total_us)) / 1_000_000.0});
        try w.print("beanline_claim_duration_seconds_count {d}\n", .{cnt});

        try w.writeAll("# HELP beanline_scheduler_skipped_fires_total Skipped scheduler fires.\n");
        try w.writeAll("# TYPE beanline_scheduler_skipped_fires_total counter\n");
        try w.print("beanline_scheduler_skipped_fires_total {d}\n", .{self.scheduler_skipped.load(.monotonic)});

        try w.writeAll("# HELP beanline_leader_active Whether this process holds leader roles.\n");
        try w.writeAll("# TYPE beanline_leader_active gauge\n");
        try w.print("beanline_leader_active {d}\n", .{self.leader_active.load(.monotonic)});

        try w.writeAll("# HELP beanline_metrics_label_overflow_total Label values dropped by the cardinality cap.\n");
        try w.writeAll("# TYPE beanline_metrics_label_overflow_total counter\n");
        try w.print("beanline_metrics_label_overflow_total{{label=\"kind\"}} {d}\n", .{self.overflowed_kinds.load(.monotonic)});
        try w.print("beanline_metrics_label_overflow_total{{label=\"queue\"}} {d}\n", .{self.overflowed_queues.load(.monotonic)});

        try w.writeAll("# HELP beanline_uptime_seconds Process uptime.\n");
        try w.writeAll("# TYPE beanline_uptime_seconds gauge\n");
        try w.print("beanline_uptime_seconds {d}\n", .{@max(0, @divTrunc(std.time.milliTimestamp() - self.started_at_ms, 1000))});

        return out.toOwnedSlice();
    }
};

test "metrics render prometheus text" {
    var m = Metrics.init(std.testing.allocator);
    defer m.deinit();
    m.incrEnqueued("emails.send", "mailers");
    m.incrEnqueued("emails.send", "mailers");
    m.incrCompleted("emails.send");
    m.incrDead("emails.send");
    m.setQueueDepth("mailers", 3, 1, 2, 0);
    const s = try m.render(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_jobs_enqueued_total{kind=\"emails.send\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_jobs_completed_total{kind=\"emails.send\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_jobs_dead_total{kind=\"emails.send\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_queue_depth{queue=\"mailers\",state=\"available\"} 3") != null);
}

test "metrics keys are interned once" {
    var m = Metrics.init(std.testing.allocator);
    defer m.deinit();
    m.incrEnqueued("k", "q");
    m.incrEnqueued("k", "q");
    m.incrEnqueued("k2", "q");
    try std.testing.expectEqual(@as(usize, 2), m.kind_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), m.queue_names.items.len);
}

test "kind cardinality overflows into one series" {
    var m = Metrics.initWithLimits(std.testing.allocator, .{ .max_kinds = 2, .max_queues = 2 });
    defer m.deinit();
    m.incrEnqueued("a", "q1");
    m.incrEnqueued("b", "q2");
    m.incrEnqueued("c", "q3");
    m.incrEnqueued("d", "q4");
    try std.testing.expectEqual(@as(usize, 3), m.kind_names.items.len);
    try std.testing.expectEqualStrings(Metrics.overflow_label, m.kind_names.items[2]);
    try std.testing.expectEqual(@as(usize, 3), m.queue_names.items.len);
    try std.testing.expectEqualStrings(Metrics.overflow_label, m.queue_names.items[2]);

    const s = try m.render(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "kind=\"__other__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_metrics_label_overflow_total{label=\"kind\"} 1") != null);
}

test "duration histogram buckets and labels" {
    var m = Metrics.init(std.testing.allocator);
    defer m.deinit();
    m.observeJobDuration("emails.send", .completed, 12_000); // 12 ms
    m.observeJobDuration("emails.send", .completed, 900_000); // 900 ms
    m.observeJobDuration("emails.send", .failed, 20_000);
    m.observeE2E("emails.send", .completed, 5_000_000); // 5 s

    const s = try m.render(std.testing.allocator);
    defer std.testing.allocator.free(s);
    // 12 ms and 900 ms both land at or below the 0.25 and 1.0 bounds.
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_count{kind=\"emails.send\",outcome=\"completed\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_bucket{kind=\"emails.send\",outcome=\"completed\",le=\"0.025\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_bucket{kind=\"emails.send\",outcome=\"completed\",le=\"1\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_bucket{kind=\"emails.send\",outcome=\"failed\",le=\"0.025\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_e2e_seconds_bucket{kind=\"emails.send\",outcome=\"completed\",le=\"5\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_count{kind=\"emails.send\",outcome=\"dead\"} 0") != null);
}

test "duration above the last bound lands in +Inf" {
    var m = Metrics.init(std.testing.allocator);
    defer m.deinit();
    m.observeJobDuration("slow", .completed, 400 * 1_000_000); // 400 s, past the 300 bound
    const s = try m.render(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_bucket{kind=\"slow\",outcome=\"completed\",le=\"300\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "beanline_job_duration_seconds_bucket{kind=\"slow\",outcome=\"completed\",le=\"+Inf\"} 1") != null);
}
