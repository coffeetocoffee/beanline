const std = @import("std");
const broker_mod = @import("../broker/broker.zig");
const auth_mod = @import("auth.zig");

/// REST API layer for the dashboard. Every response body is a JSON string the
/// caller owns. Mutations go through the same Broker primitives as the
/// library path (doc §5 rules); the dashboard never writes raw SQL.
pub const Rest = struct {
    alloc: std.mem.Allocator,
    broker: broker_mod.Broker,

    pub fn init(alloc: std.mem.Allocator, broker: broker_mod.Broker) Rest {
        return .{ .alloc = alloc, .broker = broker };
    }

    fn errJson(self: *Rest, code: u16, msg: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{{\"error\":\"{s}\",\"code\":{d}}}", .{ msg, code });
    }

    fn escapeJson(self: *Rest, s: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(self.alloc);
        errdefer out.deinit();
        for (s) |c| {
            switch (c) {
                '"' => try out.appendSlice("\\\""),
                '\\' => try out.appendSlice("\\\\"),
                '\n' => try out.appendSlice("\\n"),
                '\r' => try out.appendSlice("\\r"),
                '\t' => try out.appendSlice("\\t"),
                else => {
                    if (c < 0x20) {
                        try out.writer().print("\\u{x:0>4}", .{c});
                    } else {
                        try out.append(c);
                    }
                },
            }
        }
        return out.toOwnedSlice();
    }

    fn maskedArgs(self: *Rest, args: []const u8, sensitive: bool) ![]u8 {
        if (!sensitive) return try self.alloc.dupe(u8, args);
        return try self.alloc.dupe(u8, "\"***\"");
    }

    /// GET /api/queues — depth per queue. `names` is the configured queue list.
    pub fn queues(self: *Rest, names: []const []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(self.alloc);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"queues\":[");
        for (names, 0..) |q, i| {
            if (i > 0) try w.writeAll(",");
            var d = broker_mod.Depth{};
            self.broker.depth(q, &d) catch {
                d = .{};
            };
            const paused = self.broker.queuePaused(q) catch false;
            const esc = try self.escapeJson(q);
            defer self.alloc.free(esc);
            try w.print("{{\"name\":\"{s}\",\"available\":{d},\"scheduled\":{d},\"running\":{d},\"dead\":{d},\"completed\":{d},\"cancelled\":{d},\"oldest_available_ms\":{d},\"paused\":{s}}}", .{
                esc, d.available, d.scheduled, d.running, d.dead, d.completed, d.cancelled, d.oldest_available_ms, if (paused) "true" else "false",
            });
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    fn queueCtlError(self: *Rest, e: anyerror) ![]u8 {
        if (e == error.Unsupported) return self.errJson(501, "not_supported");
        return self.errJson(500, @errorName(e));
    }

    /// POST /api/queues/{name}/pause and /resume — durable across processes.
    pub fn setQueuePaused(self: *Rest, queue: []const u8, paused: bool) ![]u8 {
        if (paused) {
            self.broker.pauseQueue(queue) catch |e| return self.queueCtlError(e);
        } else {
            self.broker.resumeQueue(queue) catch |e| return self.queueCtlError(e);
        }
        const esc = try self.escapeJson(queue);
        defer self.alloc.free(esc);
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"queue\":\"{s}\",\"paused\":{s}}}", .{ esc, if (paused) "true" else "false" });
    }

    /// GET /api/jobs?status=&kind=&queue=&limit=&offset=
    pub fn listJobs(self: *Rest, query: []const u8, actor: ?[]const u8) ![]u8 {
        _ = actor;
        var filter = broker_mod.JobFilter{};
        var qbuf: [64]u8 = undefined;
        var kbuf: [128]u8 = undefined;
        var qname: ?[]const u8 = null;
        var kname: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "status=")) {
                filter.status = broker_mod.Status.fromSql(pair["status=".len..]);
            } else if (std.mem.startsWith(u8, pair, "queue=")) {
                const v = pair["queue=".len..];
                @memcpy(qbuf[0..@min(v.len, qbuf.len)], v[0..@min(v.len, qbuf.len)]);
                qname = qbuf[0..@min(v.len, qbuf.len)];
                filter.queue = qname;
            } else if (std.mem.startsWith(u8, pair, "kind=")) {
                const v = pair["kind=".len..];
                @memcpy(kbuf[0..@min(v.len, kbuf.len)], v[0..@min(v.len, kbuf.len)]);
                kname = kbuf[0..@min(v.len, kbuf.len)];
                filter.kind = kname;
            } else if (std.mem.startsWith(u8, pair, "limit=")) {
                filter.limit = std.fmt.parseInt(u32, pair["limit=".len..], 10) catch 50;
                filter.limit = @min(filter.limit, 500);
            } else if (std.mem.startsWith(u8, pair, "offset=")) {
                filter.offset = std.fmt.parseInt(u32, pair["offset=".len..], 10) catch 0;
            }
        }

        var rows = std.ArrayList(broker_mod.JobRow).init(self.alloc);
        defer rows.deinit();
        self.broker.listJobs(self.alloc, filter, &rows) catch |e| {
            return self.errJson(500, @errorName(e));
        };

        var out = std.ArrayList(u8).init(self.alloc);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"jobs\":[");
        for (rows.items, 0..) |r, i| {
            if (i > 0) try w.writeAll(",");
            const q = try self.escapeJson(r.queue);
            defer self.alloc.free(q);
            const k = try self.escapeJson(r.kind);
            defer self.alloc.free(k);
            const args = try self.maskedArgs(r.args_json, false);
            defer self.alloc.free(args);
            const wid = try self.escapeJson(r.worker_id);
            defer self.alloc.free(wid);
            try w.print("{{\"id\":{d},\"queue\":\"{s}\",\"kind\":\"{s}\",\"args\":{s},\"status\":\"{s}\",\"priority\":{d},\"run_at_ms\":{d},\"attempts\":{d},\"max_attempts\":{d},\"lease_epoch\":{d},\"worker_id\":\"{s}\",\"inserted_ms\":{d},\"started_ms\":{d},\"finished_ms\":{d}}}", .{
                r.id, q, k, args, @tagName(r.status), r.priority, r.run_at_ms, r.attempts, r.max_attempts, r.lease_epoch, wid, r.inserted_ms, r.started_ms, r.finished_ms,
            });
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// GET /api/jobs/{id} — detail + events.
    pub fn jobDetail(self: *Rest, id: i64) ![]u8 {
        var maybe: ?broker_mod.JobRow = null;
        self.broker.getJob(self.alloc, id, &maybe) catch |e| {
            return self.errJson(500, @errorName(e));
        };
        const r = maybe orelse return self.errJson(404, "not_found");

        var evs = std.ArrayList(broker_mod.EventRow).init(self.alloc);
        defer evs.deinit();
        self.broker.jobEvents(self.alloc, id, &evs) catch {};

        var out = std.ArrayList(u8).init(self.alloc);
        errdefer out.deinit();
        const w = out.writer();
        const q = try self.escapeJson(r.queue);
        defer self.alloc.free(q);
        const k = try self.escapeJson(r.kind);
        defer self.alloc.free(k);
        const args = try self.maskedArgs(r.args_json, false);
        defer self.alloc.free(args);
        const wid = try self.escapeJson(r.worker_id);
        defer self.alloc.free(wid);
        try w.print("{{\"id\":{d},\"queue\":\"{s}\",\"kind\":\"{s}\",\"args\":{s},\"status\":\"{s}\",\"priority\":{d},\"run_at_ms\":{d},\"attempts\":{d},\"max_attempts\":{d},\"lease_epoch\":{d},\"worker_id\":\"{s}\",\"inserted_ms\":{d},\"started_ms\":{d},\"finished_ms\":{d},\"events\":[", .{
            r.id, q, k, args, @tagName(r.status), r.priority, r.run_at_ms, r.attempts, r.max_attempts, r.lease_epoch, wid, r.inserted_ms, r.started_ms, r.finished_ms,
        });
        for (evs.items, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            const t = try self.escapeJson(e.event_type);
            defer self.alloc.free(t);
            const d = try self.maskedArgs(e.data_json, false);
            defer self.alloc.free(d);
            try w.print("{{\"seq\":{d},\"type\":\"{s}\",\"data\":{s},\"at_ms\":{d}}}", .{ e.seq, t, d, e.at_ms });
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// POST /api/jobs/{id}/retry
    pub fn jobRetry(self: *Rest, queue: []const u8, id: i64) ![]u8 {
        self.broker.retry(queue, id) catch |e| {
            if (e == error.NotFound) return self.errJson(404, "not_found");
            return self.errJson(500, @errorName(e));
        };
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"id\":{d}}}", .{id});
    }

    /// POST /api/jobs/{id}/discard
    pub fn jobDiscard(self: *Rest, queue: []const u8, id: i64) ![]u8 {
        self.broker.discard(queue, id) catch |e| {
            if (e == error.NotFound) return self.errJson(404, "not_found");
            return self.errJson(500, @errorName(e));
        };
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"id\":{d}}}", .{id});
    }

    /// POST /api/jobs/{id}/cancel
    pub fn jobCancel(self: *Rest, queue: []const u8, id: i64) ![]u8 {
        self.broker.cancel(queue, id, null) catch |e| {
            if (e == error.NotFound) return self.errJson(404, "not_found");
            if (e == error.Running) return self.errJson(409, "running");
            return self.errJson(500, @errorName(e));
        };
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"id\":{d}}}", .{id});
    }

    /// POST /api/enqueue — body: {"kind":..,"queue":..,"args":{...},"run_at_ms":..,"unique_key":..}
    /// Returns 409 when a uniqueness guard dedupes the request.
    pub fn enqueue(self: *Rest, body: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch {
            return self.errJson(400, "bad_json");
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.errJson(400, "bad_json"),
        };
        const kind_v = obj.get("kind") orelse return self.errJson(400, "missing_kind");
        const kind = switch (kind_v) {
            .string => |s| s,
            else => return self.errJson(400, "bad_kind"),
        };
        const queue: []const u8 = if (obj.get("queue")) |qv| switch (qv) {
            .string => |s| s,
            else => "default",
        } else "default";
        var args_buf: [8192]u8 = undefined;
        var args_fbs = std.io.fixedBufferStream(&args_buf);
        if (obj.get("args")) |av| {
            std.json.stringify(av, .{}, args_fbs.writer()) catch return self.errJson(400, "bad_args");
        } else {
            try args_fbs.writer().writeAll("{}");
        }
        const run_at: i64 = if (obj.get("run_at_ms")) |rv| switch (rv) {
            .integer => |n| n,
            else => 0,
        } else 0;
        const unique: ?[]const u8 = if (obj.get("unique_key")) |uv| switch (uv) {
            .string => |s| s,
            else => null,
        } else null;

        var enq = broker_mod.Enqueued{};
        self.broker.enqueue(kind, args_fbs.getWritten(), .{ .queue = queue, .run_at_ms = run_at, .unique_key = unique }, &enq) catch |e| {
            return self.errJson(500, @errorName(e));
        };
        if (enq.deduped) {
            return std.fmt.allocPrint(self.alloc, "{{\"ok\":false,\"deduped\":true,\"id\":{d}}}", .{enq.id});
        }
        return std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"id\":{d}}}", .{enq.id});
    }

    /// GET /api/schedules — reads broker schedule table where available; the
    /// runtime-owned in-memory schedules are reported by the worker tier.
    pub fn schedules(self: *Rest, entries_json: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{{\"schedules\":{s}}}", .{entries_json});
    }
};

test "rest queues renders depth json" {
    const Mock = struct {
        var depth_return: broker_mod.Depth = .{ .available = 3, .dead = 1 };
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
        fn failCb(_: *anyopaque, _: []const u8, _: i64, _: u64, _: []const u8, _: bool, _: i64, _: *broker_mod.FailOutcome) anyerror!void {
            return error.Unsupported;
        }
        fn cancelCb(_: *anyopaque, _: []const u8, _: i64, _: ?u64) anyerror!void {
            return error.Unsupported;
        }
        fn promoteCb(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
            return error.Unsupported;
        }
        fn reapCb(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
            return error.Unsupported;
        }
        fn depthCb(_: *anyopaque, _: []const u8, out: *broker_mod.Depth) anyerror!void {
            out.* = depth_return;
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
    };
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var rest = Rest.init(std.testing.allocator, br);
    const s = try rest.queues(&.{"default"});
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"available\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"dead\":1") != null);
}

test "rest enqueue parses body" {
    const Mock = struct {
        fn enqueueCb(_: *anyopaque, kind: []const u8, args_json: []const u8, _: broker_mod.EnqueueOptions, out: *broker_mod.Enqueued) anyerror!void {
            try std.testing.expectEqualStrings("emails.send", kind);
            try std.testing.expect(std.mem.indexOf(u8, args_json, "\"to\"") != null);
            out.* = .{ .id = 42 };
        }
        fn depthCb(_: *anyopaque, _: []const u8, _: *broker_mod.Depth) anyerror!void {
            return error.Unsupported;
        }
        fn capabilitiesCb() broker_mod.Capabilities {
            return .{ .transactional_enqueue = false, .pubsub_wakeups = false, .named_backend = "mock" };
        }
        fn deinitCb(_: *anyopaque) void {}
        fn unsupportedClaim(_: *anyopaque, _: []const u8, _: u32, _: []const u8, _: u64, _: []broker_mod.Claimed) anyerror!usize {
            return error.Unsupported;
        }
        fn unsupportedHeartbeat(_: *anyopaque, _: []const u8, _: []const i64, _: []const u64, _: u64) anyerror!void {
            return error.Unsupported;
        }
        fn unsupportedFinish(_: *anyopaque, _: []const u8, _: i64, _: u64) anyerror!void {
            return error.Unsupported;
        }
        fn unsupportedFail(_: *anyopaque, _: []const u8, _: i64, _: u64, _: []const u8, _: bool, _: i64, _: *broker_mod.FailOutcome) anyerror!void {
            return error.Unsupported;
        }
        fn unsupportedCancel(_: *anyopaque, _: []const u8, _: i64, _: ?u64) anyerror!void {
            return error.Unsupported;
        }
        fn unsupportedPromote(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
            return error.Unsupported;
        }
        fn unsupportedReap(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
            return error.Unsupported;
        }
        const vt = broker_mod.VTable{
            .enqueue = enqueueCb,
            .claim = unsupportedClaim,
            .heartbeat = unsupportedHeartbeat,
            .finish = unsupportedFinish,
            .fail = unsupportedFail,
            .cancel = unsupportedCancel,
            .promote = unsupportedPromote,
            .reap = unsupportedReap,
            .depth = depthCb,
            .capabilities = capabilitiesCb,
            .deinit = deinitCb,
        };
    };
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var rest = Rest.init(std.testing.allocator, br);
    const s = try rest.enqueue("{\"kind\":\"emails.send\",\"args\":{\"to\":\"a\"}}");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"id\":42") != null);
    const bad = try rest.enqueue("not json");
    defer std.testing.allocator.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "\"code\":400") != null);
}
