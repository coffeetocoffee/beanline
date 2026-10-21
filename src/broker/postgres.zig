const std = @import("std");
const b = @import("broker.zig");
const pg = @import("pg/conn.zig");

const SQL_INSERT_UNIQUE =
    \\INSERT INTO beanline_jobs (queue, kind, args, priority, run_at, max_attempts, unique_key, dedup_run_id, context, status)
    \\VALUES ($1, $2, $3::jsonb, $4,
    \\  CASE WHEN $5::bigint = 0 THEN now() ELSE to_timestamp($5::bigint::double precision / 1000.0) END,
    \\  $6::int, $7, $8, $9::jsonb,
    \\  CASE WHEN $5::bigint <> 0 AND to_timestamp($5::bigint::double precision / 1000.0) > now()
    \\       THEN 'scheduled' ELSE 'available' END)
    \\ON CONFLICT (queue, kind, unique_key) WHERE unique_key IS NOT NULL AND status NOT IN ('completed','discarded','cancelled','dead')
    \\DO NOTHING
    \\RETURNING id
;

const SQL_INSERT_DEDUP =
    \\INSERT INTO beanline_jobs (queue, kind, args, priority, run_at, max_attempts, unique_key, dedup_run_id, context, status)
    \\VALUES ($1, $2, $3::jsonb, $4,
    \\  CASE WHEN $5::bigint = 0 THEN now() ELSE to_timestamp($5::bigint::double precision / 1000.0) END,
    \\  $6::int, $7, $8, $9::jsonb,
    \\  CASE WHEN $5::bigint <> 0 AND to_timestamp($5::bigint::double precision / 1000.0) > now()
    \\       THEN 'scheduled' ELSE 'available' END)
    \\ON CONFLICT (kind, dedup_run_id) WHERE dedup_run_id IS NOT NULL
    \\DO NOTHING
    \\RETURNING id
;

const SQL_LOOKUP_UNIQUE =
    \\SELECT id FROM beanline_jobs
    \\WHERE queue = $1 AND kind = $2 AND unique_key = $3
    \\  AND status NOT IN ('completed','discarded','cancelled','dead')
    \\LIMIT 1
;

const SQL_LOOKUP_DEDUP =
    \\SELECT id FROM beanline_jobs
    \\WHERE kind = $1 AND dedup_run_id = $2
    \\  AND status NOT IN ('completed','discarded','cancelled','dead')
    \\LIMIT 1
;

const SQL_EVENT =
    \\INSERT INTO beanline_job_events (job_id, seq, type, data)
    \\SELECT $1, coalesce((SELECT max(seq) FROM beanline_job_events e2 WHERE e2.job_id = $1), 0) + 1, $2, $3::jsonb
;

const SQL_CLAIM =
    \\WITH batch AS (
    \\  SELECT id FROM beanline_jobs
    \\  WHERE queue = $1 AND status = 'available' AND run_at <= now()
    \\    AND NOT EXISTS (SELECT 1 FROM beanline_queue_state s WHERE s.queue = $1 AND s.paused)
    \\  ORDER BY (priority::int - floor((extract(epoch from now()) * 1000 - (extract(epoch from inserted_at) * 1000)::bigint)::numeric / $5::numeric))::int, run_at
    \\  FOR UPDATE SKIP LOCKED
    \\  LIMIT $2
    \\)
    \\UPDATE beanline_jobs j
    \\SET status = 'running',
    \\    attempts = j.attempts + 1,
    \\    lease_epoch = j.lease_epoch + 1,
    \\    worker_id = $3,
    \\    started_at = coalesce(j.started_at, now()),
    \\    lock_expires_at = now() + ($4::bigint * interval '1 millisecond')
    \\FROM batch
    \\WHERE j.id = batch.id
    \\RETURNING j.id, j.queue, j.kind, j.args::text, j.attempts, j.max_attempts,
    \\          j.lease_epoch, j.priority, (extract(epoch from j.run_at) * 1000)::bigint, j.context::text
;

const SQL_HB =
    \\UPDATE beanline_jobs SET lock_expires_at = now() + ($3::bigint * interval '1 millisecond')
    \\WHERE id = ANY($1::bigint[]) AND lease_epoch = ANY($2::bigint[]) AND status = 'running'
;

const SQL_FINISH =
    \\UPDATE beanline_jobs SET status = 'completed', finished_at = now(), lock_expires_at = NULL
    \\WHERE id = $1 AND lease_epoch = $2 AND status = 'running'
;

const SQL_FAIL =
    \\UPDATE beanline_jobs SET
    \\  status = CASE WHEN $3::bool AND attempts < max_attempts THEN 'available' ELSE 'dead' END,
    \\  run_at = CASE WHEN $3::bool AND attempts < max_attempts
    \\                THEN to_timestamp($4::bigint::double precision / 1000.0) ELSE run_at END,
    \\  lock_expires_at = NULL
    \\WHERE id = $1 AND lease_epoch = $2 AND status = 'running'
    \\RETURNING status, attempts, (extract(epoch from run_at) * 1000)::bigint
;

const SQL_CANCEL_PENDING =
    \\UPDATE beanline_jobs SET status = 'cancelled', finished_at = now()
    \\WHERE id = $1 AND status IN ('available','scheduled')
;

const SQL_CANCEL_RUNNING =
    \\UPDATE beanline_jobs SET status = 'cancelled', finished_at = now(), lock_expires_at = NULL
    \\WHERE id = $1 AND lease_epoch = $2 AND status = 'running'
;

const SQL_STATUS =
    \\SELECT status FROM beanline_jobs WHERE id = $1
;

const SQL_PROMOTE =
    \\WITH batch AS (
    \\  SELECT id FROM beanline_jobs
    \\  WHERE status = 'scheduled' AND run_at <= now()
    \\  ORDER BY run_at
    \\  FOR UPDATE SKIP LOCKED
    \\  LIMIT $1
    \\)
    \\UPDATE beanline_jobs j SET status = 'available'
    \\FROM batch WHERE j.id = batch.id
    \\RETURNING j.id
;

const SQL_REAP =
    \\WITH exp AS (
    \\  SELECT id, attempts, max_attempts FROM beanline_jobs
    \\  WHERE status = 'running' AND lock_expires_at < now()
    \\  ORDER BY lock_expires_at
    \\  FOR UPDATE SKIP LOCKED
    \\  LIMIT $1
    \\)
    \\UPDATE beanline_jobs j SET
    \\  status = CASE WHEN e.attempts >= e.max_attempts THEN 'dead' ELSE 'available' END,
    \\  attempts = CASE WHEN e.attempts >= e.max_attempts THEN e.attempts ELSE greatest(e.attempts - 1, 0) END,
    \\  lock_expires_at = NULL
    \\FROM exp e WHERE j.id = e.id
    \\RETURNING j.id, j.status, j.attempts
;

const SQL_DEPTH =
    \\SELECT count(*) FILTER (WHERE status = 'available'),
    \\       count(*) FILTER (WHERE status = 'scheduled'),
    \\       count(*) FILTER (WHERE status = 'running'),
    \\       count(*) FILTER (WHERE status = 'dead'),
    \\       count(*) FILTER (WHERE status = 'completed'),
    \\       count(*) FILTER (WHERE status = 'cancelled'),
    \\       coalesce((extract(epoch from min(run_at) FILTER (WHERE status = 'available')) * 1000)::bigint, 0)
    \\FROM beanline_jobs WHERE queue = $1
;

const Pg = struct {
    alloc: std.mem.Allocator,
    c: pg.Conn,
    claim: ?pg.Rows = null,
    read_arena: std.heap.ArenaAllocator,
    aging_interval_ms: u64,
    /// Serializes all connection use. The Postgres wire protocol is strictly
    /// request/response on one stream, and several operations pair BEGIN with
    /// COMMIT, so concurrent use from multiple threads corrupts the frame
    /// stream. Lock at the vtable entry points below (the *Impl helpers call
    /// each other; locking inside them would self-deadlock).
    mu: std.Thread.Mutex = .{},

    fn rollback(self: *Pg) void {
        self.c.execSimple("ROLLBACK") catch {};
    }

    fn textCell(row: []?[]const u8, i: usize) ![]const u8 {
        return row[i] orelse error.ProtocolViolation;
    }

    fn intCell(comptime T: type, row: []?[]const u8, i: usize) !T {
        const s = try textCell(row, i);
        return std.fmt.parseInt(T, s, 10) catch error.ProtocolViolation;
    }

    fn quoteJson(self: *Pg, s: []const u8) ![]u8 {
        return try quoteJsonAlloc(self.alloc, s);
    }

    fn insertEvent(self: *Pg, job_id: i64, event_type: []const u8, data_json: []const u8) !void {
        try insertEventOnConn(self.alloc, &self.c, job_id, event_type, data_json);
    }

    fn enqueueImpl(self: *Pg, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) !void {
        try self.c.execSimple("BEGIN");
        errdefer self.rollback();
        try enqueueCore(self.alloc, &self.c, kind, args_json, opts, out);
        try self.c.execSimple("COMMIT");
    }
    fn claimImpl(self: *Pg, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []b.Claimed) !usize {
        if (self.claim) |*r| {
            r.deinit();
            self.claim = null;
        }
        if (out.len == 0) return 0;
        const bounded: u32 = @intCast(@min(limit, out.len));

        var pbuf: [3][24]u8 = undefined;
        const lim = try std.fmt.bufPrint(&pbuf[0], "{d}", .{bounded});
        const lms = try std.fmt.bufPrint(&pbuf[1], "{d}", .{lease_ms});
        const aging = try std.fmt.bufPrint(&pbuf[2], "{d}", .{self.aging_interval_ms});
        const params = [_]?[]const u8{ queue, lim, worker_id, lms, aging };

        try self.c.execSimple("BEGIN");
        errdefer self.rollback();

        var rows = try self.c.query(SQL_CLAIM, &params);
        if (rows.rows.len == 0) {
            rows.deinit();
            self.c.execSimple("COMMIT") catch |e| {
                self.rollback();
                return e;
            };
            return 0;
        }
        errdefer rows.deinit();

        for (rows.rows) |row| {
            const id = try Pg.intCell(i64, row, 0);
            const epoch = try Pg.intCell(u64, row, 6);
            const quoted_worker = try self.quoteJson(worker_id);
            defer self.alloc.free(quoted_worker);
            var evbuf: [320]u8 = undefined;
            const evdata = try std.fmt.bufPrint(&evbuf, "{{\"worker\":{s},\"epoch\":{d}}}", .{ quoted_worker, epoch });
            try self.insertEvent(id, "claimed", evdata);
        }

        var i: usize = 0;
        while (i < rows.rows.len) : (i += 1) {
            const row = rows.rows[i];
            out[i] = .{
                .id = try Pg.intCell(i64, row, 0),
                .queue = try textCell(row, 1),
                .kind = try textCell(row, 2),
                .args_json = try textCell(row, 3),
                .attempts = try Pg.intCell(u32, row, 4),
                .max_attempts = try Pg.intCell(u32, row, 5),
                .lease_epoch = try Pg.intCell(u64, row, 6),
                .priority = try Pg.intCell(u8, row, 7),
                .run_at_ms = try Pg.intCell(i64, row, 8),
                .context_json = try textCell(row, 9),
            };
        }
        const n = rows.rows.len;
        try self.c.execSimple("COMMIT");
        self.claim = rows;
        return n;
    }

    fn heartbeatImpl(self: *Pg, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) !void {
        _ = queue;
        if (ids.len == 0) return;
        var ids_buf: [512]u8 = undefined;
        var ep_buf: [512]u8 = undefined;
        const ids_arr = try idArray(&ids_buf, ids);
        const ep_arr = try epochArray(&ep_buf, epochs);
        var lbuf: [24]u8 = undefined;
        const lms = try std.fmt.bufPrint(&lbuf, "{d}", .{lease_ms});
        var rows = try self.c.query(SQL_HB, &.{ ids_arr, ep_arr, lms });
        rows.deinit();
    }

    fn idArray(buf: []u8, ids: []const i64) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeByte('{');
        for (ids, 0..) |id, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{d}", .{id});
        }
        try w.writeByte('}');
        return buf[0..fbs.pos];
    }

    fn epochArray(buf: []u8, epochs: []const u64) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeByte('{');
        for (epochs, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{d}", .{e});
        }
        try w.writeByte('}');
        return buf[0..fbs.pos];
    }

    fn finishImpl(self: *Pg, queue: []const u8, id: i64, lease_epoch: u64) !void {
        _ = queue;
        var pbuf: [2][24]u8 = undefined;
        const idstr = try std.fmt.bufPrint(&pbuf[0], "{d}", .{id});
        const epstr = try std.fmt.bufPrint(&pbuf[1], "{d}", .{lease_epoch});

        try self.c.execSimple("BEGIN");
        errdefer self.rollback();
        var rows = try self.c.query(SQL_FINISH, &.{ idstr, epstr });
        defer rows.deinit();
        const count = pg.Rows.rowCountFromTag(rows.command_tag) orelse 0;
        if (count == 0) {
            self.rollback();
            return error.StaleLease;
        }
        try self.insertEvent(id, "completed", "{}");
        try self.c.execSimple("COMMIT");
    }

    fn failImpl(self: *Pg, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, retryable: bool, retry_at_ms: i64, out: *b.FailOutcome) !void {
        _ = queue;
        var pbuf: [3][24]u8 = undefined;
        const idstr = try std.fmt.bufPrint(&pbuf[0], "{d}", .{id});
        const epstr = try std.fmt.bufPrint(&pbuf[1], "{d}", .{lease_epoch});
        const rstr = try std.fmt.bufPrint(&pbuf[2], "{d}", .{retry_at_ms});
        const retry_s: []const u8 = if (retryable) "true" else "false";

        try self.c.execSimple("BEGIN");
        errdefer self.rollback();
        var rows = try self.c.query(SQL_FAIL, &.{ idstr, epstr, retry_s, rstr });
        defer rows.deinit();
        if (rows.rows.len == 0) {
            self.rollback();
            return error.StaleLease;
        }
        const status_s = try textCell(rows.rows[0], 0);
        out.status = b.Status.fromSql(status_s) orelse return error.ProtocolViolation;
        out.attempts = try Pg.intCell(u32, rows.rows[0], 1);
        out.retry_at_ms = try Pg.intCell(i64, rows.rows[0], 2);

        const quoted_err = try self.quoteJson(err_name);
        defer self.alloc.free(quoted_err);
        var evbuf: [320]u8 = undefined;
        const evdata = try std.fmt.bufPrint(&evbuf, "{{\"error\":{s},\"retryable\":{s},\"next_run_at\":{d}}}", .{ quoted_err, retry_s, retry_at_ms });
        const ev_type: []const u8 = if (out.status == .dead) "dead" else "attempt_failed";
        try self.insertEvent(id, ev_type, evdata);
        try self.c.execSimple("COMMIT");
    }

    fn cancelImpl(self: *Pg, queue: []const u8, id: i64, lease_epoch: ?u64) !void {
        _ = queue;
        var idbuf: [24]u8 = undefined;
        const idstr = try std.fmt.bufPrint(&idbuf, "{d}", .{id});

        try self.c.execSimple("BEGIN");
        errdefer self.rollback();
        var rows = try self.c.query(SQL_CANCEL_PENDING, &.{idstr});
        const count = pg.Rows.rowCountFromTag(rows.command_tag) orelse 0;
        rows.deinit();
        if (count == 0) {
            var sr = try self.c.query(SQL_STATUS, &.{idstr});
            defer sr.deinit();
            if (sr.rows.len == 0) {
                self.rollback();
                return error.NotFound;
            }
            const status = b.Status.fromSql(try textCell(sr.rows[0], 0)) orelse .running;
            if (status == .running) {
                if (lease_epoch) |ep| {
                    var ebuf: [24]u8 = undefined;
                    const epstr = try std.fmt.bufPrint(&ebuf, "{d}", .{ep});
                    var rr = try self.c.query(SQL_CANCEL_RUNNING, &.{ idstr, epstr });
                    const rcount = pg.Rows.rowCountFromTag(rr.command_tag) orelse 0;
                    rr.deinit();
                    if (rcount > 0) {
                        try self.insertEvent(id, "cancelled", "{}");
                        try self.c.execSimple("COMMIT");
                        return;
                    }
                }
                self.rollback();
                return error.Running;
            }
            self.rollback();
            return error.Running;
        }
        try self.insertEvent(id, "cancelled", "{}");
        try self.c.execSimple("COMMIT");
    }

    fn promoteImpl(self: *Pg, queues: []const []const u8, limit: u32) !u32 {
        _ = queues;
        var buf: [24]u8 = undefined;
        const lim = try std.fmt.bufPrint(&buf, "{d}", .{limit});
        var rows = try self.c.query(SQL_PROMOTE, &.{lim});
        defer rows.deinit();
        const n = pg.Rows.rowCountFromTag(rows.command_tag) orelse 0;
        return @intCast(n);
    }

    fn reapImpl(self: *Pg, queues: []const []const u8, limit: u32) !u32 {
        _ = queues;
        var buf: [24]u8 = undefined;
        const lim = try std.fmt.bufPrint(&buf, "{d}", .{limit});

        try self.c.execSimple("BEGIN");
        errdefer self.rollback();
        var rows = try self.c.query(SQL_REAP, &.{lim});
        defer rows.deinit();
        const n: u32 = @intCast(rows.rows.len);
        if (n > 0) {
            for (rows.rows) |row| {
                const id = try Pg.intCell(i64, row, 0);
                const status_s = try textCell(row, 1);
                const attempts = try Pg.intCell(u32, row, 2);
                var evbuf: [160]u8 = undefined;
                const evdata = try std.fmt.bufPrint(&evbuf, "{{\"status\":\"{s}\",\"attempts\":{d}}}", .{ status_s, attempts });
                try self.insertEvent(id, "reaped", evdata);
            }
        }
        try self.c.execSimple("COMMIT");
        return n;
    }

    fn depthImpl(self: *Pg, queue: []const u8, out: *b.Depth) !void {
        var rows = try self.c.query(SQL_DEPTH, &.{queue});
        defer rows.deinit();
        if (rows.rows.len != 1) return error.ProtocolViolation;
        const row = rows.rows[0];
        out.* = .{
            .available = try Pg.intCell(u64, row, 0),
            .scheduled = try Pg.intCell(u64, row, 1),
            .running = try Pg.intCell(u64, row, 2),
            .dead = try Pg.intCell(u64, row, 3),
            .completed = try Pg.intCell(u64, row, 4),
            .cancelled = try Pg.intCell(u64, row, 5),
            .oldest_available_ms = try Pg.intCell(i64, row, 6),
        };
    }
};

fn enqueueCb(ctx: *anyopaque, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.enqueueImpl(kind, args_json, opts, out);
}

fn claimCb(ctx: *anyopaque, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []b.Claimed) anyerror!usize {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return try self.claimImpl(queue, limit, worker_id, lease_ms, out);
}

fn heartbeatCb(ctx: *anyopaque, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.heartbeatImpl(queue, ids, epochs, lease_ms);
}

fn finishCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.finishImpl(queue, id, lease_epoch);
}

fn failCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, retryable: bool, retry_at_ms: i64, out: *b.FailOutcome) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.failImpl(queue, id, lease_epoch, err_name, retryable, retry_at_ms, out);
}

fn cancelCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: ?u64) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.cancelImpl(queue, id, lease_epoch);
}

fn promoteCb(ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32 {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return try self.promoteImpl(queues, limit);
}

fn reapCb(ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32 {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return try self.reapImpl(queues, limit);
}

fn depthCb(ctx: *anyopaque, queue: []const u8, out: *b.Depth) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.depthImpl(queue, out);
}

fn capabilitiesCb() b.Capabilities {
    return .{ .transactional_enqueue = true, .pubsub_wakeups = false, .named_backend = "postgres" };
}

fn deinitCb(ctx: *anyopaque) void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    if (self.claim) |*r| r.deinit();
    self.read_arena.deinit();
    self.c.deinit();
    const alloc = self.alloc;
    alloc.destroy(self);
}

const SQL_LIST_BASE =
    \\SELECT id, queue, kind, args::text, status, priority,
    \\       (extract(epoch from run_at) * 1000)::bigint,
    \\        attempts, max_attempts, lease_epoch,
    \\       coalesce(worker_id, ''),
    \\       (extract(epoch from inserted_at) * 1000)::bigint,
    \\       coalesce((extract(epoch from started_at) * 1000)::bigint, 0),
    \\       coalesce((extract(epoch from finished_at) * 1000)::bigint, 0)
    \\FROM beanline_jobs
;

const SQL_GET_ONE = SQL_LIST_BASE ++ " WHERE id = $1";

const SQL_EVENTS =
    \\SELECT job_id, seq, type, data::text,
    \\       (extract(epoch from at) * 1000)::bigint
    \\FROM beanline_job_events WHERE job_id = $1 ORDER BY seq
;

const SQL_QUEUE_NAMES = "SELECT DISTINCT queue FROM beanline_jobs ORDER BY queue";

const SQL_PAUSE_QUEUE =
    \\INSERT INTO beanline_queue_state (queue, paused, changed_at)
    \\VALUES ($1, true, now())
    \\ON CONFLICT (queue) DO UPDATE SET paused = true, changed_at = now()
;

const SQL_RESUME_QUEUE =
    \\INSERT INTO beanline_queue_state (queue, paused, changed_at)
    \\VALUES ($1, false, now())
    \\ON CONFLICT (queue) DO UPDATE SET paused = false, changed_at = now()
;

const SQL_QUEUE_PAUSED = "SELECT paused FROM beanline_queue_state WHERE queue = $1";

const SQL_RETRY =
    \\UPDATE beanline_jobs SET status = 'available', run_at = now(),
    \\  attempts = 0, lock_expires_at = NULL
    \\WHERE id = $1 AND queue = $2 AND status IN ('dead','discarded','cancelled')
;

const SQL_DISCARD =
    \\UPDATE beanline_jobs SET status = 'discarded', finished_at = now(),
    \\  lock_expires_at = NULL
    \\WHERE id = $1 AND queue = $2 AND status IN ('dead','available','scheduled')
;

fn rowToJobRow(row: []?[]const u8) !b.JobRow {
    const status_s = try Pg.textCell(row, 4);
    return .{
        .id = try Pg.intCell(i64, row, 0),
        .queue = try Pg.textCell(row, 1),
        .kind = try Pg.textCell(row, 2),
        .args_json = try Pg.textCell(row, 3),
        .status = b.Status.fromSql(status_s) orelse return error.ProtocolViolation,
        .priority = try Pg.intCell(u8, row, 5),
        .run_at_ms = try Pg.intCell(i64, row, 6),
        .attempts = try Pg.intCell(u32, row, 7),
        .max_attempts = try Pg.intCell(u32, row, 8),
        .lease_epoch = try Pg.intCell(u64, row, 9),
        .worker_id = try Pg.textCell(row, 10),
        .inserted_ms = try Pg.intCell(i64, row, 11),
        .started_ms = try Pg.intCell(i64, row, 12),
        .finished_ms = try Pg.intCell(i64, row, 13),
    };
}

fn listJobsImpl(self: *Pg, alloc: std.mem.Allocator, filter: b.JobFilter, out: *std.ArrayList(b.JobRow)) !void {
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var sql = std.ArrayList(u8).init(alloc);
    defer sql.deinit();
    try sql.appendSlice(SQL_LIST_BASE);
    try sql.appendSlice(" WHERE 1=1");
    var params = std.ArrayList(?[]const u8).init(alloc);
    defer params.deinit();

    if (filter.queue) |q| {
        var buf: [32]u8 = undefined;
        const idx = try std.fmt.bufPrint(&buf, " AND queue = ${d}", .{params.items.len + 1});
        try sql.appendSlice(idx);
        try params.append(q);
    }
    if (filter.kind) |k| {
        var buf: [32]u8 = undefined;
        const idx = try std.fmt.bufPrint(&buf, " AND kind = ${d}", .{params.items.len + 1});
        try sql.appendSlice(idx);
        try params.append(k);
    }
    if (filter.status) |s| {
        var buf: [32]u8 = undefined;
        const idx = try std.fmt.bufPrint(&buf, " AND status = ${d}", .{params.items.len + 1});
        try sql.appendSlice(idx);
        try params.append(@tagName(s));
    }
    {
        var lbuf: [32]u8 = undefined;
        var obuf: [32]u8 = undefined;
        const lim = try std.fmt.bufPrint(&lbuf, "{d}", .{filter.limit});
        const off = try std.fmt.bufPrint(&obuf, "{d}", .{filter.offset});
        var ibuf: [64]u8 = undefined;
        const idx = try std.fmt.bufPrint(&ibuf, " ORDER BY id DESC LIMIT ${d} OFFSET ${d}", .{ params.items.len + 1, params.items.len + 2 });
        try sql.appendSlice(idx);
        try params.append(lim);
        try params.append(off);
    }

    var rows = try self.c.query(sql.items, params.items);
    defer rows.deinit();
    for (rows.rows) |row| {
        const jr = try rowToJobRow(row);
        const owned = b.JobRow{
            .id = jr.id,
            .queue = try ral.dupe(u8, jr.queue),
            .kind = try ral.dupe(u8, jr.kind),
            .args_json = try ral.dupe(u8, jr.args_json),
            .status = jr.status,
            .priority = jr.priority,
            .run_at_ms = jr.run_at_ms,
            .attempts = jr.attempts,
            .max_attempts = jr.max_attempts,
            .lease_epoch = jr.lease_epoch,
            .worker_id = try ral.dupe(u8, jr.worker_id),
            .inserted_ms = jr.inserted_ms,
            .started_ms = jr.started_ms,
            .finished_ms = jr.finished_ms,
        };
        try out.append(owned);
    }
}

fn getJobImpl(self: *Pg, alloc: std.mem.Allocator, id: i64, out: *?b.JobRow) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var rows = try self.c.query(SQL_GET_ONE, &.{ids});
    defer rows.deinit();
    if (rows.rows.len == 0) {
        out.* = null;
        return;
    }
    const jr = try rowToJobRow(rows.rows[0]);
    out.* = b.JobRow{
        .id = jr.id,
        .queue = try ral.dupe(u8, jr.queue),
        .kind = try ral.dupe(u8, jr.kind),
        .args_json = try ral.dupe(u8, jr.args_json),
        .status = jr.status,
        .priority = jr.priority,
        .run_at_ms = jr.run_at_ms,
        .attempts = jr.attempts,
        .max_attempts = jr.max_attempts,
        .lease_epoch = jr.lease_epoch,
        .worker_id = try ral.dupe(u8, jr.worker_id),
        .inserted_ms = jr.inserted_ms,
        .started_ms = jr.started_ms,
        .finished_ms = jr.finished_ms,
    };
}

fn jobEventsImpl(self: *Pg, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(b.EventRow)) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var rows = try self.c.query(SQL_EVENTS, &.{ids});
    defer rows.deinit();
    for (rows.rows) |row| {
        try out.append(.{
            .job_id = try Pg.intCell(i64, row, 0),
            .seq = try Pg.intCell(i64, row, 1),
            .event_type = try ral.dupe(u8, try Pg.textCell(row, 2)),
            .data_json = try ral.dupe(u8, try Pg.textCell(row, 3)),
            .at_ms = try Pg.intCell(i64, row, 4),
        });
    }
}

fn queueNamesImpl(self: *Pg, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var rows = try self.c.query(SQL_QUEUE_NAMES, &.{});
    defer rows.deinit();
    for (rows.rows) |row| {
        try out.append(try ral.dupe(u8, try Pg.textCell(row, 0)));
    }
}

fn retryImpl(self: *Pg, queue: []const u8, id: i64) !void {
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var rows = try self.c.query(SQL_RETRY, &.{ ids, queue });
    defer rows.deinit();
    const count = pg.Rows.rowCountFromTag(rows.command_tag) orelse 0;
    if (count == 0) return error.NotFound;
    try self.insertEvent(id, "retried_by_operator", "{}");
}

fn discardImpl(self: *Pg, queue: []const u8, id: i64) !void {
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var rows = try self.c.query(SQL_DISCARD, &.{ ids, queue });
    defer rows.deinit();
    const count = pg.Rows.rowCountFromTag(rows.command_tag) orelse 0;
    if (count == 0) return error.NotFound;
    try self.insertEvent(id, "discarded_by_operator", "{}");
}

fn pauseQueueImpl(self: *Pg, queue: []const u8) !void {
    var rows = try self.c.query(SQL_PAUSE_QUEUE, &.{queue});
    rows.deinit();
}

fn resumeQueueImpl(self: *Pg, queue: []const u8) !void {
    var rows = try self.c.query(SQL_RESUME_QUEUE, &.{queue});
    rows.deinit();
}

fn queuePausedImpl(self: *Pg, queue: []const u8) !bool {
    var rows = try self.c.query(SQL_QUEUE_PAUSED, &.{queue});
    defer rows.deinit();
    if (rows.rows.len == 0) return false;
    const v = try Pg.textCell(rows.rows[0], 0);
    return v.len > 0 and (v[0] == 't' or v[0] == 'T' or v[0] == '1');
}

fn listJobsCb(ctx: *anyopaque, alloc: std.mem.Allocator, filter: b.JobFilter, out: *std.ArrayList(b.JobRow)) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try listJobsImpl(self, alloc, filter, out);
}

fn getJobCb(ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *?b.JobRow) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try getJobImpl(self, alloc, id, out);
}

fn jobEventsCb(ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(b.EventRow)) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try jobEventsImpl(self, alloc, id, out);
}

fn queueNamesCb(ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try queueNamesImpl(self, alloc, out);
}

fn retryCb(ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try retryImpl(self, queue, id);
}

fn discardCb(ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try discardImpl(self, queue, id);
}

fn pauseQueueCb(ctx: *anyopaque, queue: []const u8) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try pauseQueueImpl(self, queue);
}

fn resumeQueueCb(ctx: *anyopaque, queue: []const u8) anyerror!void {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try resumeQueueImpl(self, queue);
}

fn queuePausedCb(ctx: *anyopaque, queue: []const u8) anyerror!bool {
    const self: *Pg = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return queuePausedImpl(self, queue);
}

fn insertEventOnConn(alloc: std.mem.Allocator, c: *pg.Conn, job_id: i64, event_type: []const u8, data_json: []const u8) !void {
    var idbuf: [24]u8 = undefined;
    const idstr = try std.fmt.bufPrint(&idbuf, "{d}", .{job_id});
    var rows = try c.query(SQL_EVENT, &.{ idstr, event_type, data_json });
    rows.deinit();
    _ = alloc;
}

fn enqueueCore(alloc: std.mem.Allocator, c: *pg.Conn, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) !void {
    if (opts.unique == .replace) return error.UnsupportedUnique;
    var pbuf: [3][24]u8 = undefined;
    const pri = try std.fmt.bufPrint(&pbuf[0], "{d}", .{opts.priority});
    const rat = try std.fmt.bufPrint(&pbuf[1], "{d}", .{opts.run_at_ms});
    const ma = try std.fmt.bufPrint(&pbuf[2], "{d}", .{opts.max_attempts});
    const params = [_]?[]const u8{ opts.queue, kind, args_json, pri, rat, ma, opts.unique_key, opts.dedup_run_id, opts.context_json };

    const deduped_sql = opts.dedup_run_id != null;
    const maybe_id: ?i64 = blk: {
        var rows = try c.query(if (deduped_sql) SQL_INSERT_DEDUP else SQL_INSERT_UNIQUE, &params);
        defer rows.deinit();
        if (rows.rows.len == 0) break :blk null;
        break :blk try Pg.intCell(i64, rows.rows[0], 0);
    };

    if (maybe_id) |id| {
        const quoted_queue = try quoteJsonAlloc(alloc, opts.queue);
        defer alloc.free(quoted_queue);
        var evbuf: [256]u8 = undefined;
        const evdata = try std.fmt.bufPrint(&evbuf, "{{\"queue\":{s}}}", .{quoted_queue});
        try insertEventOnConn(alloc, c, id, "enqueued", evdata);
        out.* = .{ .id = id, .deduped = false, .replaced = false };
    } else {
        const existing: i64 = if (deduped_sql) blk: {
            var lr = try c.query(SQL_LOOKUP_DEDUP, &.{ kind, opts.dedup_run_id });
            defer lr.deinit();
            break :blk if (lr.rows.len > 0) try Pg.intCell(i64, lr.rows[0], 0) else 0;
        } else blk: {
            var lr = try c.query(SQL_LOOKUP_UNIQUE, &.{ opts.queue, kind, opts.unique_key });
            defer lr.deinit();
            break :blk if (lr.rows.len > 0) try Pg.intCell(i64, lr.rows[0], 0) else 0;
        };
        out.* = .{ .id = existing, .deduped = true, .replaced = false };
    }
}

/// Enqueue a job on the caller's already-open transaction (`conn`). The
/// caller owns BEGIN/COMMIT/ROLLBACK; this only runs the INSERT and the
/// enqueued-event insert on that connection. This is the transactional
/// outbox primitive (architecture.md 6.5).
pub fn enqueueInTx(conn: *pg.Conn, alloc: std.mem.Allocator, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) !void {
    try enqueueCore(alloc, conn, kind, args_json, opts, out);
}

fn quoteJsonAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try out.append('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            else => {
                if (ch < 0x20) {
                    var esc: [6]u8 = undefined;
                    const e = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{ch});
                    try out.appendSlice(e);
                } else {
                    try out.append(ch);
                }
            },
        }
    }
    try out.append('"');
    return try out.toOwnedSlice();
}

pub const vtable = b.VTable{
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
    .list_jobs = listJobsCb,
    .get_job = getJobCb,
    .job_events = jobEventsCb,
    .queue_names = queueNamesCb,
    .retry = retryCb,
    .discard = discardCb,
    .pause_queue = pauseQueueCb,
    .resume_queue = resumeQueueCb,
    .queue_paused = queuePausedCb,
};

pub fn open(alloc: std.mem.Allocator, dsn: []const u8, aging_interval_ms: u64) !*Pg {
    const cfg = try pg.parseDsn(alloc, dsn);
    defer cfg.free(alloc);
    const self = try alloc.create(Pg);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .c = try pg.Conn.connect(alloc, cfg), .read_arena = std.heap.ArenaAllocator.init(alloc), .aging_interval_ms = aging_interval_ms };
    return self;
}

pub fn toBroker(self: *Pg) b.Broker {
    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
}

/// Delete every job and event belonging to `queue`. Test-support helper used by
/// the contract suite in tests/contract to isolate each case in its own queue.
pub fn purgeQueue(br: b.Broker, queue: []const u8) !void {
    const self: *Pg = @ptrCast(@alignCast(br.ptr));
    self.mu.lock();
    defer self.mu.unlock();
    var rows = try self.c.query("DELETE FROM beanline_jobs WHERE queue = $1", &.{queue});
    rows.deinit();
}

test "id and epoch arrays build postgres literals" {
    var buf: [64]u8 = undefined;
    const ids = try Pg.idArray(&buf, &.{ 7, 123, -4 });
    try std.testing.expectEqualStrings("{7,123,-4}", ids);
    var ebuf: [64]u8 = undefined;
    const eps = try Pg.epochArray(&ebuf, &.{ 1, 2 });
    try std.testing.expectEqualStrings("{1,2}", eps);
    var empty: [8]u8 = undefined;
    const none = try Pg.idArray(&empty, &.{});
    try std.testing.expectEqualStrings("{}", none);
}

test "json quoting escapes" {
    var p = Pg{ .alloc = std.testing.allocator, .c = undefined, .read_arena = std.heap.ArenaAllocator.init(std.testing.allocator), .aging_interval_ms = 5 * 60 * 1000 };
    const q = try p.quoteJson("a\"b\\c");
    defer p.alloc.free(q);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", q);
    const q2 = try p.quoteJson("plain");
    defer p.alloc.free(q2);
    try std.testing.expectEqualStrings("\"plain\"", q2);
}

test "live broker round trip" {
    const alloc = std.testing.allocator;
    const dsn = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_DSN") catch return;
    defer alloc.free(dsn);

    const p = try open(alloc, dsn, 5 * 60 * 1000);
    const br = toBroker(p);
    defer br.deinit();
    defer p.c.execSimple("DELETE FROM beanline_jobs WHERE queue = 'live-test'") catch {};
    try p.c.execSimple("DELETE FROM beanline_jobs WHERE queue = 'live-test'");

    const now_ms: i64 = 0;

    var enq = b.Enqueued{};
    try br.enqueue("test.ping", "{\"n\":1}", .{
        .queue = "live-test",
        .unique_key = "rt-1",
        .run_at_ms = now_ms,
    }, &enq);
    try std.testing.expect(enq.id > 0);
    try std.testing.expect(!enq.deduped);

    var enq2 = b.Enqueued{};
    try br.enqueue("test.ping", "{\"n\":1}", .{
        .queue = "live-test",
        .unique_key = "rt-1",
        .run_at_ms = now_ms,
    }, &enq2);
    try std.testing.expect(enq2.deduped);
    try std.testing.expectEqual(enq.id, enq2.id);

    var claimed: [8]b.Claimed = undefined;
    const n = try br.claim("live-test", 8, "host:1:boot", 60000, &claimed);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(enq.id, claimed[0].id);
    try std.testing.expectEqualStrings("test.ping", claimed[0].kind);
    try std.testing.expectEqual(@as(u32, 1), claimed[0].attempts);
    try std.testing.expect(claimed[0].lease_epoch >= 1);

    try br.finish("live-test", claimed[0].id, claimed[0].lease_epoch);

    try std.testing.expectError(error.StaleLease, br.finish("live-test", claimed[0].id, claimed[0].lease_epoch));

    var depth = b.Depth{};
    try br.depth("live-test", &depth);
    try std.testing.expectEqual(@as(u64, 0), depth.available);
    try std.testing.expectEqual(@as(u64, 1), depth.completed);

    var enq3 = b.Enqueued{};
    try br.enqueue("test.retry", "{}", .{ .queue = "live-test", .run_at_ms = 0 }, &enq3);
    var claimed2: [4]b.Claimed = undefined;
    const n2 = try br.claim("live-test", 4, "host:1:boot", 60000, &claimed2);
    try std.testing.expectEqual(@as(usize, 1), n2);

    var fail_out = b.FailOutcome{};
    try br.fail("live-test", claimed2[0].id, claimed2[0].lease_epoch, "Timeout", true, 0, &fail_out);
    try std.testing.expectEqual(b.Status.available, fail_out.status);
    try std.testing.expectEqual(@as(u32, 1), fail_out.attempts);

    const n3 = try br.claim("live-test", 4, "host:1:boot", 1, &claimed2);
    try std.testing.expectEqual(@as(usize, 1), n3);
    var fail_out2 = b.FailOutcome{};
    try br.fail("live-test", claimed2[0].id, claimed2[0].lease_epoch, "AddressInvalid", false, 0, &fail_out2);
    try std.testing.expectEqual(b.Status.dead, fail_out2.status);

    var enq4 = b.Enqueued{};
    const soon_ms: i64 = std.time.milliTimestamp() + 250;
    try br.enqueue("test.later", "{}", .{ .queue = "live-test", .run_at_ms = soon_ms }, &enq4);
    try std.testing.expectEqual(@as(u32, 0), try br.promote(&.{"live-test"}, 10));
    std.time.sleep(400 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), try br.promote(&.{"live-test"}, 10));

    const reaped = try br.reap(&.{"live-test"}, 10);
    _ = reaped;

    try std.testing.expectEqual(b.Capabilities{
        .transactional_enqueue = true,
        .pubsub_wakeups = false,
        .named_backend = "postgres",
    }, br.capabilities());
}
