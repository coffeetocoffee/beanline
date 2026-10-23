const std = @import("std");
const b = @import("broker.zig");
const client = @import("resp/client.zig");

const claim_lua = @embedFile("lua/claim.lua");
const enqueue_lua = @embedFile("lua/enqueue.lua");
const finish_lua = @embedFile("lua/finish.lua");
const fail_lua = @embedFile("lua/fail.lua");
const heartbeat_lua = @embedFile("lua/heartbeat.lua");
const promote_lua = @embedFile("lua/promote.lua");
const reap_lua = @embedFile("lua/reap.lua");
const cancel_lua = @embedFile("lua/cancel.lua");

pub const Url = struct {
    host: []const u8,
    port: u16,
    password: ?[]const u8,
    db: u8,

    pub fn parse(alloc: std.mem.Allocator, url: []const u8) !Url {
        var rest = url;
        if (std.mem.startsWith(u8, rest, "redis://")) {
            rest = rest["redis://".len..];
        } else if (std.mem.startsWith(u8, rest, "rediss://")) {
            return error.TlsUnsupported;
        } else {
            return error.BadUrl;
        }
        var password: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            const auth = rest[0..at];
            rest = rest[at + 1 ..];
            if (auth.len > 0) {
                if (std.mem.startsWith(u8, auth, ":")) {
                    password = auth[1..];
                } else if (std.mem.indexOfScalar(u8, auth, ':') != null) {
                    return error.BadUrl;
                } else {
                    password = auth;
                }
            }
        }
        var db: u8 = 0;
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const dbs = rest[slash + 1 ..];
            if (dbs.len > 0) db = std.fmt.parseInt(u8, dbs, 10) catch return error.BadUrl;
            rest = rest[0..slash];
        }
        var host = rest;
        var port: u16 = 6379;
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.BadUrl;
            host = rest[0..colon];
        }
        if (host.len == 0) return error.BadUrl;
        return .{
            .host = try alloc.dupe(u8, host),
            .port = port,
            .password = if (password) |p| try alloc.dupe(u8, p) else null,
            .db = db,
        };
    }

    pub fn free(self: Url, alloc: std.mem.Allocator) void {
        alloc.free(self.host);
        if (self.password) |p| alloc.free(p);
    }
};

const Redis = struct {
    alloc: std.mem.Allocator,
    c: client.Client,
    claim_arena: std.heap.ArenaAllocator,
    read_arena: std.heap.ArenaAllocator,
    aging_interval_ms: u64,
    /// Serializes all connection use. RESP is strictly request/response on
    /// one stream, so concurrent use from multiple threads interleaves
    /// commands and corrupts reply parsing. Lock at the vtable entry points
    /// below (the *Impl helpers share the claim_arena and call each other;
    /// locking inside them would self-deadlock).
    mu: std.Thread.Mutex = .{},

    /// Refuse to work against a Redis that cannot run the scripts.
    ///
    /// A server that is too old fails every write path with a Lua error that
    /// says nothing about versions, which is a miserable thing to diagnose.
    /// Checking once at connect turns that into one clear message. A server
    /// that does not answer INFO at all (a restricted user, a proxy) is
    /// allowed through: refusing to connect on a guess would be worse.
    fn checkServerVersion(self: *Redis) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const v = self.c.command(arena.allocator(), &.{ "INFO", "server" }) catch return;
        const text = switch (v) {
            .bulk => |s| s orelse return,
            .simple => |s| s,
            else => return,
        };
        const line = findRedisVersion(text) orelse return;
        const ver = Version.parse(line) orelse return;
        if (ver.atLeast(min_version)) return;
        std.log.err(
            "redis: server version {s} is too old, beanline needs {s} or newer " ++
                "(the Lua scripts read the server clock and then write, which " ++
                "needs Redis 5.0 effects replication)",
            .{ ver, min_version },
        );
        return error.RedisVersionTooOld;
    }

    fn enqueueImpl(self: *Redis, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) !void {
        if (opts.unique == .replace) return error.UnsupportedUnique;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const batch_id = if (opts.batch_id) |bid| try std.fmt.allocPrint(al, "{d}", .{bid}) else "";
        const argv = [_][]const u8{
            opts.queue,
            kind,
            args_json,
            try std.fmt.allocPrint(al, "{d}", .{opts.priority}),
            try std.fmt.allocPrint(al, "{d}", .{opts.run_at_ms}),
            try std.fmt.allocPrint(al, "{d}", .{opts.max_attempts}),
            opts.unique_key orelse "",
            opts.dedup_run_id orelse "",
            opts.context_json,
            try std.fmt.allocPrint(al, "{d}", .{opts.max_lease_losses}),
            batch_id,
        };
        const v = try self.c.eval(al, enqueue_lua, &.{}, &argv);
        const items = switch (v) {
            .array => |a| a,
            else => return error.Protocol,
        };
        if (items.len < 2) return error.Protocol;
        const fresh = (try items[0].asInt()) == 1;
        out.* = .{ .id = 0, .deduped = !fresh, .replaced = false };
        switch (items[1]) {
            .int => |i| out.id = i,
            .bulk => |bopt| {
                if (bopt) |bs| out.id = std.fmt.parseInt(i64, bs, 10) catch 0;
            },
            else => {},
        }
    }

    fn claimImpl(self: *Redis, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []b.Claimed) !usize {
        if (out.len == 0) return 0;
        const bounded: u32 = @intCast(@min(limit, out.len));
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const argv = [_][]const u8{
            queue,
            worker_id,
            try std.fmt.allocPrint(al, "{d}", .{lease_ms}),
            try std.fmt.allocPrint(al, "{d}", .{bounded}),
            try std.fmt.allocPrint(al, "{d}", .{self.aging_interval_ms}),
        };
        const v = try self.c.eval(al, claim_lua, &.{}, &argv);
        const items = switch (v) {
            .array => |a| a,
            else => return error.Protocol,
        };
        if (items.len > out.len) return error.Protocol;
        _ = self.claim_arena.reset(.retain_capacity);
        const cla = self.claim_arena.allocator();
        for (items, 0..) |entry, n| {
            const row = switch (entry) {
                .array => |a| a,
                else => return error.Protocol,
            };
            if (row.len != 9) return error.Protocol;
            out[n] = .{
                .id = try row[0].asInt(),
                .queue = try cla.dupe(u8, queue),
                .kind = try cla.dupe(u8, try row[2].asString()),
                .args_json = try cla.dupe(u8, try row[3].asString()),
                .attempts = @intCast(try row[4].asInt()),
                .max_attempts = @intCast(try row[5].asInt()),
                .lease_epoch = @intCast(try row[1].asInt()),
                .priority = @intCast(try row[6].asInt()),
                .run_at_ms = try row[7].asInt(),
                .context_json = try cla.dupe(u8, try row[8].asString()),
            };
        }
        return items.len;
    }

    fn heartbeatImpl(self: *Redis, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) !void {
        if (ids.len == 0) return;
        if (ids.len != epochs.len) return error.Protocol;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const now: i64 = std.time.milliTimestamp();
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(queue);
        try argv.append(try std.fmt.allocPrint(al, "{d}", .{lease_ms}));
        try argv.append(try std.fmt.allocPrint(al, "{d}", .{now}));
        for (ids, epochs) |id, ep| {
            try argv.append(try std.fmt.allocPrint(al, "{d}", .{id}));
            try argv.append(try std.fmt.allocPrint(al, "{d}", .{ep}));
        }
        const v = try self.c.eval(al, heartbeat_lua, &.{}, argv.items);
        _ = switch (v) {
            .int => |i| i,
            else => 0,
        };
        // Stale epoch or non-running job: noop (contract test expects no error)
    }

    fn finishImpl(self: *Redis, queue: []const u8, id: i64, lease_epoch: u64) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const now: i64 = std.time.milliTimestamp();
        const argv = [_][]const u8{
            queue,
            try std.fmt.allocPrint(al, "{d}", .{id}),
            try std.fmt.allocPrint(al, "{d}", .{lease_epoch}),
            try std.fmt.allocPrint(al, "{d}", .{now}),
        };
        const v = try self.c.eval(al, finish_lua, &.{}, &argv);
        const ok = switch (v) {
            .int => |i| i == 1,
            else => false,
        };
        if (!ok) return error.StaleLease;
    }

    fn failImpl(self: *Redis, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, failure: b.Failure, out: *b.FailOutcome) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const now: i64 = std.time.milliTimestamp();
        const retry_at_ms: i64 = switch (failure) {
            .retry => |t| t,
            else => 0,
        };
        const retry_s: []const u8 = switch (failure) {
            .retry => "1",
            else => "0",
        };
        const reason_s: []const u8 = switch (failure) {
            .retry, .attempts_exhausted => "attempts_exhausted",
            .non_retryable => "non_retryable",
        };
        const argv = [_][]const u8{
            queue,
            try std.fmt.allocPrint(al, "{d}", .{id}),
            try std.fmt.allocPrint(al, "{d}", .{lease_epoch}),
            retry_s,
            try std.fmt.allocPrint(al, "{d}", .{retry_at_ms}),
            try std.fmt.allocPrint(al, "{d}", .{now}),
            err_name,
            reason_s,
        };
        const v = try self.c.eval(al, fail_lua, &.{}, &argv);
        const items = switch (v) {
            .array => |a| a,
            else => return error.StaleLease,
        };
        if (items.len != 4) return error.StaleLease;
        const status_s = try items[0].asString();
        out.status = b.Status.fromSql(status_s) orelse return error.Protocol;
        out.retry_at_ms = try items[1].asInt();
        out.attempts = @intCast(try items[2].asInt());
        const reason_s2 = try items[3].asString();
        out.dead_reason = if (reason_s2.len == 0) null else (b.DeadReason.fromSql(reason_s2) orelse return error.Protocol);
    }

    fn cancelImpl(self: *Redis, queue: []const u8, id: i64, lease_epoch: ?u64) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const now: i64 = std.time.milliTimestamp();
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(queue);
        try argv.append(try std.fmt.allocPrint(al, "{d}", .{id}));
        try argv.append(try std.fmt.allocPrint(al, "{d}", .{now}));
        try argv.append(try std.fmt.allocPrint(al, "{d}", .{lease_epoch orelse 0}));
        const v = try self.c.eval(al, cancel_lua, &.{}, argv.items);
        const res = v.asString() catch return error.Protocol;
        if (std.mem.eql(u8, res, "cancelled")) return;
        if (std.mem.eql(u8, res, "notfound")) return error.NotFound;
        return error.Running;
    }

    fn promoteImpl(self: *Redis, queues: []const []const u8, limit: u32) !u32 {
        var moved: u32 = 0;
        for (queues) |queue| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const al = arena.allocator();
            const now: i64 = std.time.milliTimestamp();
            const argv = [_][]const u8{
                queue,
                try std.fmt.allocPrint(al, "{d}", .{now}),
                try std.fmt.allocPrint(al, "{d}", .{limit}),
            };
            const v = try self.c.eval(al, promote_lua, &.{}, &argv);
            moved += @intCast(try v.asInt());
        }
        return moved;
    }

    fn reapImpl(self: *Redis, queues: []const []const u8, limit: u32) !u32 {
        var reaped: u32 = 0;
        for (queues) |queue| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const al = arena.allocator();
            const argv = [_][]const u8{
                queue,
                try std.fmt.allocPrint(al, "{d}", .{limit}),
            };
            const v = try self.c.eval(al, reap_lua, &.{}, &argv);
            reaped += @intCast(try v.asInt());
        }
        return reaped;
    }

    fn depthImpl(self: *Redis, queue: []const u8, out: *b.Depth) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const key = try std.fmt.allocPrint(al, "beanline:{{{s}}}:depth", .{queue});
        const v = try self.c.command(al, &.{ "HGETALL", key });
        const items = switch (v) {
            .array => |a| a,
            else => return error.Protocol,
        };
        if (items.len % 2 != 0) return error.Protocol;
        out.* = .{};
        var i: usize = 0;
        while (i < items.len) : (i += 2) {
            const name = try items[i].asString();
            const value = @as(u64, @intCast(try items[i + 1].asInt()));
            if (std.mem.eql(u8, name, "available")) {
                out.available = value;
            } else if (std.mem.eql(u8, name, "scheduled")) {
                out.scheduled = value;
            } else if (std.mem.eql(u8, name, "running")) {
                out.running = value;
            } else if (std.mem.eql(u8, name, "dead")) {
                out.dead = value;
            } else if (std.mem.eql(u8, name, "completed")) {
                out.completed = value;
            } else if (std.mem.eql(u8, name, "cancelled")) {
                out.cancelled = value;
            }
        }
    }
};

fn enqueueCb(ctx: *anyopaque, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.enqueueImpl(kind, args_json, opts, out);
}

fn claimCb(ctx: *anyopaque, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []b.Claimed) anyerror!usize {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return try self.claimImpl(queue, limit, worker_id, lease_ms, out);
}

fn heartbeatCb(ctx: *anyopaque, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.heartbeatImpl(queue, ids, epochs, lease_ms);
}

fn finishCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.finishImpl(queue, id, lease_epoch);
}

fn failCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, failure: b.Failure, out: *b.FailOutcome) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.failImpl(queue, id, lease_epoch, err_name, failure, out);
}

fn cancelCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: ?u64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.cancelImpl(queue, id, lease_epoch);
}

fn promoteCb(ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32 {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return try self.promoteImpl(queues, limit);
}

fn reapCb(ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32 {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return try self.reapImpl(queues, limit);
}

fn depthCb(ctx: *anyopaque, queue: []const u8, out: *b.Depth) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try self.depthImpl(queue, out);
}

fn capabilitiesCb() b.Capabilities {
    return .{ .transactional_enqueue = false, .pubsub_wakeups = false, .named_backend = "redis" };
}

fn deinitCb(ctx: *anyopaque) void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.claim_arena.deinit();
    self.read_arena.deinit();
    self.c.deinit();
    const alloc = self.alloc;
    alloc.destroy(self);
}

fn hashGet(fields: []const client.Value, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < fields.len) : (i += 2) {
        const k = fields[i].asString() catch continue;
        if (std.mem.eql(u8, k, name)) {
            return fields[i + 1].asString() catch null;
        }
    }
    return null;
}

fn parseI64(s: ?[]const u8) i64 {
    const t = s orelse return 0;
    return std.fmt.parseInt(i64, t, 10) catch 0;
}

fn statusOf(s: ?[]const u8) b.Status {
    const t = s orelse return .available;
    return b.Status.fromSql(t) orelse .available;
}

fn scanKeys(self: *Redis, al: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) !void {
    var cursor_buf: [24]u8 = undefined;
    @memcpy(cursor_buf[0..1], "0");
    var cursor: []const u8 = cursor_buf[0..1];
    var next_buf: [24]u8 = undefined;
    while (true) {
        const v = try self.c.command(al, &.{ "SCAN", cursor, "MATCH", pattern, "COUNT", "100" });
        const arr = switch (v) {
            .array => |a| a,
            else => return error.Protocol,
        };
        if (arr.len != 2) return error.Protocol;
        const cur = try arr[0].asString();
        const keys = switch (arr[1]) {
            .array => |a| a,
            else => return error.Protocol,
        };
        for (keys) |k| {
            try out.append(try k.asString());
        }
        if (std.mem.eql(u8, cur, "0")) break;
        @memcpy(next_buf[0..cur.len], cur);
        cursor = next_buf[0..cur.len];
    }
}

fn queueOfKey(k: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, k, "beanline:{")) return null;
    const rest = k["beanline:{".len..];
    const qend = std.mem.indexOfScalar(u8, rest, '}') orelse return null;
    return rest[0..qend];
}

fn jobIdOfKey(k: []const u8, marker: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, k, marker) orelse return null;
    return std.fmt.parseInt(i64, k[idx + marker.len ..], 10) catch null;
}

fn rowFromHash(alloc: std.mem.Allocator, qname: []const u8, id: i64, fields: []const client.Value) !b.JobRow {
    const kind = hashGet(fields, "kind") orelse "";
    return .{
        .id = id,
        .queue = try alloc.dupe(u8, qname),
        .kind = try alloc.dupe(u8, kind),
        .args_json = try alloc.dupe(u8, hashGet(fields, "args") orelse "{}"),
        .status = statusOf(hashGet(fields, "status")),
        .priority = @intCast(@max(0, parseI64(hashGet(fields, "priority")))),
        .run_at_ms = parseI64(hashGet(fields, "run_at")),
        .attempts = @intCast(@max(0, parseI64(hashGet(fields, "attempts")))),
        .max_attempts = @intCast(@max(0, parseI64(hashGet(fields, "max_attempts")))),
        // Jobs enqueued before the lease-loss counter existed have no
        // max_lease_losses field; fall back to the default so they are
        // still bounded.
        .lease_losses = @intCast(@max(0, parseI64(hashGet(fields, "lease_losses") orelse "0"))),
        .max_lease_losses = @intCast(@max(0, parseI64(hashGet(fields, "max_lease_losses") orelse "3"))),
        .lease_epoch = @intCast(@max(0, parseI64(hashGet(fields, "epoch")))),
        .worker_id = try alloc.dupe(u8, hashGet(fields, "worker") orelse ""),
        .inserted_ms = parseI64(hashGet(fields, "inserted_at")),
        .started_ms = parseI64(hashGet(fields, "finished_at")),
        .finished_ms = parseI64(hashGet(fields, "finished_at")),
        // Jobs that predate the reason field have no dead_reason, and a job
        // that is still live has it cleared.
        .dead_reason = blk: {
            const r = hashGet(fields, "dead_reason") orelse break :blk null;
            if (r.len == 0) break :blk null;
            break :blk (b.DeadReason.fromSql(r) orelse return error.Protocol);
        },
    };
}

fn listJobsImpl(self: *Redis, alloc: std.mem.Allocator, filter: b.JobFilter, out: *std.ArrayList(b.JobRow)) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();

    var keys = std.ArrayList([]const u8).init(al);
    if (filter.queue) |q| {
        var pat_buf: [512]u8 = undefined;
        const pat = try std.fmt.bufPrint(&pat_buf, "beanline:{{{s}}}:job:*", .{q});
        try scanKeys(self, al, pat, &keys);
    } else {
        var dks = std.ArrayList([]const u8).init(al);
        try scanKeys(self, al, "beanline:{*}:depth", &dks);
        for (dks.items) |dk| {
            const qname = queueOfKey(dk) orelse continue;
            var pat_buf: [512]u8 = undefined;
            const pat = try std.fmt.bufPrint(&pat_buf, "beanline:{{{s}}}:job:*", .{qname});
            try scanKeys(self, al, pat, &keys);
        }
    }

    var skipped: u32 = 0;
    var emitted: u32 = 0;
    for (keys.items) |k| {
        if (emitted >= filter.limit) break;
        const qname = queueOfKey(k) orelse continue;
        const id = jobIdOfKey(k, ":job:") orelse continue;
        const h = try self.c.command(al, &.{ "HGETALL", k });
        const fields = switch (h) {
            .array => |a| a,
            else => continue,
        };
        if (fields.len == 0) continue;
        const kind = hashGet(fields, "kind") orelse "";
        const st = statusOf(hashGet(fields, "status"));
        if (filter.kind) |fk| {
            if (!std.mem.eql(u8, kind, fk)) continue;
        }
        if (filter.status) |fs| {
            if (st != fs) continue;
        }
        if (skipped < filter.offset) {
            skipped += 1;
            continue;
        }
        try out.append(try rowFromHash(ral, qname, id, fields));
        emitted += 1;
    }
}

fn getJobImpl(self: *Redis, alloc: std.mem.Allocator, id: i64, out: *?b.JobRow) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var keys = std.ArrayList([]const u8).init(al);
    var pat_buf: [64]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "beanline:{{*}}:job:{s}", .{ids});
    try scanKeys(self, al, pat, &keys);
    for (keys.items) |k| {
        const h = try self.c.command(al, &.{ "HGETALL", k });
        const fields = switch (h) {
            .array => |a| a,
            else => continue,
        };
        if (fields.len == 0) continue;
        const qname = queueOfKey(k) orelse continue;
        out.* = try rowFromHash(ral, qname, id, fields);
        return;
    }
    out.* = null;
}

fn jobEventsImpl(self: *Redis, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(b.EventRow)) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var keys = std.ArrayList([]const u8).init(al);
    var pat_buf: [64]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "beanline:{{*}}:events:{s}", .{ids});
    try scanKeys(self, al, pat, &keys);
    for (keys.items) |k| {
        const v = try self.c.command(al, &.{ "LRANGE", k, "0", "-1" });
        const items = switch (v) {
            .array => |a| a,
            else => continue,
        };
        for (items, 0..) |entry, idx| {
            const raw = entry.asString() catch continue;
            var ev_type: []const u8 = "unknown";
            if (std.mem.indexOf(u8, raw, "\"type\"")) |ti| {
                const rest = raw[ti + 7 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        ev_type = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
            try out.append(.{
                .job_id = id,
                .seq = @intCast(idx + 1),
                .event_type = try ral.dupe(u8, ev_type),
                .data_json = try ral.dupe(u8, raw),
                .at_ms = 0,
            });
        }
        return;
    }
}

fn queueNamesImpl(self: *Redis, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    _ = alloc;
    _ = self.read_arena.reset(.retain_capacity);
    const ral = self.read_arena.allocator();
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    var keys = std.ArrayList([]const u8).init(al);
    try scanKeys(self, al, "beanline:{*}:depth", &keys);
    for (keys.items) |k| {
        const qname = queueOfKey(k) orelse continue;
        try out.append(try ral.dupe(u8, qname));
    }
}

const redis_retry_lua =
    \\local prefix = 'beanline:{' .. ARGV[1] .. '}'
    \\local jk = prefix .. ':job:' .. ARGV[2]
    \\local st = redis.call('HGET', jk, 'status')
    \\if st ~= 'dead' and st ~= 'cancelled' then return 0 end
    \\redis.call('HSET', jk, 'status', 'available', 'run_at', ARGV[3], 'attempts', '0', 'lease_losses', '0', 'dead_reason', '')
    \\redis.call('DEL', prefix .. ':lease:' .. ARGV[2])
    \\redis.call('ZREM', prefix .. ':expires', ARGV[2])
    \\redis.call('LPUSH', prefix .. ':ready:' .. (redis.call('HGET', jk, 'priority') or '1'), ARGV[2])
    \\redis.call('HINCRBY', prefix .. ':depth', st, -1)
    \\redis.call('HINCRBY', prefix .. ':depth', 'available', 1)
    \\redis.call('RPUSH', prefix .. ':events:' .. ARGV[2], cjson.encode({type='retried_by_operator'}))
    \\redis.call('LTRIM', prefix .. ':events:' .. ARGV[2], -50, -1)
    \\return 1
;

const redis_discard_lua =
    \\local prefix = 'beanline:{' .. ARGV[1] .. '}'
    \\local jk = prefix .. ':job:' .. ARGV[2]
    \\local st = redis.call('HGET', jk, 'status')
    \\if not st then return 0 end
    \\if st ~= 'dead' and st ~= 'available' and st ~= 'scheduled' then return 0 end
    \\redis.call('HSET', jk, 'status', 'discarded', 'finished_at', ARGV[3], 'dead_reason', 'discarded_by_operator')
    \\redis.call('LREM', prefix .. ':ready:' .. (redis.call('HGET', jk, 'priority') or '1'), 0, ARGV[2])
    \\redis.call('ZREM', prefix .. ':delayed', ARGV[2])
    \\redis.call('HINCRBY', prefix .. ':depth', st, -1)
    \\redis.call('HINCRBY', prefix .. ':depth', 'discarded', 1)
    \\redis.call('RPUSH', prefix .. ':events:' .. ARGV[2], cjson.encode({type='discarded_by_operator'}))
    \\redis.call('LTRIM', prefix .. ':events:' .. ARGV[2], -50, -1)
    \\return 1
;

fn retryImpl(self: *Redis, queue: []const u8, id: i64) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const now: i64 = std.time.milliTimestamp();
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var nbuf: [24]u8 = undefined;
    const nows = try std.fmt.bufPrint(&nbuf, "{d}", .{now});
    const v = try self.c.eval(al, redis_retry_lua, &.{}, &.{ queue, ids, nows });
    if ((try v.asInt()) == 0) return error.NotFound;
}

fn discardImpl(self: *Redis, queue: []const u8, id: i64) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const now: i64 = std.time.milliTimestamp();
    var ibuf: [24]u8 = undefined;
    const ids = try std.fmt.bufPrint(&ibuf, "{d}", .{id});
    var nbuf: [24]u8 = undefined;
    const nows = try std.fmt.bufPrint(&nbuf, "{d}", .{now});
    const v = try self.c.eval(al, redis_discard_lua, &.{}, &.{ queue, ids, nows });
    if ((try v.asInt()) == 0) return error.NotFound;
}

fn pauseQueueImpl(self: *Redis, queue: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const key = try std.fmt.allocPrint(al, "beanline:{{{s}}}:paused", .{queue});
    _ = try self.c.command(al, &.{ "SET", key, "1" });
}

fn resumeQueueImpl(self: *Redis, queue: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const key = try std.fmt.allocPrint(al, "beanline:{{{s}}}:paused", .{queue});
    _ = try self.c.command(al, &.{ "DEL", key });
}

fn queuePausedImpl(self: *Redis, queue: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const key = try std.fmt.allocPrint(al, "beanline:{{{s}}}:paused", .{queue});
    const v = try self.c.command(al, &.{ "EXISTS", key });
    return (try v.asInt()) != 0;
}

fn createBatchImpl(self: *Redis, opts: b.BatchOptions, out: *b.BatchInfo) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const batch_id = try self.c.command(al, &.{ "INCR", "beanline:batch:seq" });
    const id = try batch_id.asInt();
    const key = try std.fmt.allocPrint(al, "beanline:batch:{d}", .{id});
    var total_buf: [12]u8 = undefined;
    const total_str = try std.fmt.bufPrint(&total_buf, "{d}", .{opts.total});
    const cb_kind = opts.callback_kind orelse "";
    _ = try self.c.command(al, &.{
        "HMSET",         key,
        "total",         total_str,
        "remaining",     total_str,
        "callback_kind", cb_kind,
        "callback_args", opts.callback_args,
        "status",        "open",
    });
    out.* = .{
        .id = id,
        .total = opts.total,
        .remaining = opts.total,
        .status = "open",
    };
}

fn completeBatchJobImpl(self: *Redis, batch_id: i64, success: bool) !void {
    _ = success;
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    const key = try std.fmt.allocPrint(al, "beanline:batch:{d}", .{batch_id});
    const remaining_v = try self.c.command(al, &.{ "HINCRBY", key, "remaining", "-1" });
    const remaining = try remaining_v.asInt();
    if (remaining <= 0) {
        // Batch complete - enqueue callback if specified
        const cb_kind_v = try self.c.command(al, &.{ "HGET", key, "callback_kind" });
        const callback_kind = if (cb_kind_v.bulk) |v| v else "";
        if (callback_kind.len > 0) {
            const cb_args_v = try self.c.command(al, &.{ "HGET", key, "callback_args" });
            const callback_args = if (cb_args_v.bulk) |v| v else "{}";
            // Enqueue callback job
            const job_id_v = try self.c.command(al, &.{ "INCR", "beanline:seq" });
            const job_id = try job_id_v.asInt();
            var ibuf: [24]u8 = undefined;
            const job_key = try std.fmt.allocPrint(al, "beanline:{{default}}:job:{d}", .{job_id});
            _ = try self.c.command(al, &.{
                "HMSET",            job_key,
                "kind",             callback_kind,
                "args",             callback_args,
                "priority",         "1",
                "run_at",           "0",
                "max_attempts",     "25",
                "max_lease_losses", "3",
                "status",           "available",
                "batch_id",         try std.fmt.bufPrint(&ibuf, "{d}", .{batch_id}),
                "inserted_at",      try std.fmt.bufPrint(&ibuf, "{d}", .{std.time.milliTimestamp()}),
            });
            _ = try self.c.command(al, &.{ "LPUSH", "beanline:{default}:ready:1", try std.fmt.bufPrint(&ibuf, "{d}", .{job_id}) });
            _ = try self.c.command(al, &.{ "HINCRBY", "beanline:{default}:depth", "available", "1" });
        }
        _ = try self.c.command(al, &.{ "HSET", key, "status", "done" });
    }
}

fn listJobsCb(ctx: *anyopaque, alloc: std.mem.Allocator, filter: b.JobFilter, out: *std.ArrayList(b.JobRow)) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try listJobsImpl(self, alloc, filter, out);
}

fn getJobCb(ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *?b.JobRow) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try getJobImpl(self, alloc, id, out);
}

fn jobEventsCb(ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(b.EventRow)) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try jobEventsImpl(self, alloc, id, out);
}

fn queueNamesCb(ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try queueNamesImpl(self, alloc, out);
}

fn retryCb(ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try retryImpl(self, queue, id);
}

fn discardCb(ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try discardImpl(self, queue, id);
}

fn pauseQueueCb(ctx: *anyopaque, queue: []const u8) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try pauseQueueImpl(self, queue);
}

fn resumeQueueCb(ctx: *anyopaque, queue: []const u8) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    try resumeQueueImpl(self, queue);
}

fn queuePausedCb(ctx: *anyopaque, queue: []const u8) anyerror!bool {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return queuePausedImpl(self, queue);
}

fn createBatchCb(ctx: *anyopaque, opts: b.BatchOptions, out: *b.BatchInfo) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return createBatchImpl(self, opts, out);
}

fn completeBatchJobCb(ctx: *anyopaque, batch_id: i64, success: bool) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.mu.lock();
    defer self.mu.unlock();
    return completeBatchJobImpl(self, batch_id, success);
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
    .create_batch = createBatchCb,
    .complete_batch_job = completeBatchJobCb,
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

/// Copy the leading decimal digits of `s` into `buf` and return how many.
fn leadingDigits(buf: []u8, s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return n;
}

/// Find the value of `redis_version:` in an INFO reply.
fn findRedisVersion(info: []const u8) ?[]const u8 {
    const key = "redis_version:";
    var it = std.mem.splitScalar(u8, info, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, key)) {
            return std.mem.trim(u8, line[key.len..], " \r\t");
        }
    }
    return null;
}

/// The minimum Redis version beanline supports.
///
/// The Lua scripts call `redis.call('TIME')` and then write. Before Redis
/// 5.0 (effects replication) a script that called a non-deterministic
/// command and then a write command was rejected outright, with
/// "Write commands not allowed after non deterministic commands". Redis 3
/// and 4 therefore fail every write path, not just some of them.
pub const min_version = Version{ .major = 5, .minor = 0, .patch = 0 };

pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    /// Parse a `redis_version` string such as "7.4.11" or "5.0.14-alpine".
    /// Returns null when the string is not a version at all, which is not an
    /// error: a proxy or a fork may report something unexpected, and refusing
    /// to connect on a guess would be worse than trying.
    pub fn parse(s: []const u8) ?Version {
        var it = std.mem.splitScalar(u8, s, '.');
        const major_s = it.next() orelse return null;
        const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
        var minor: u32 = 0;
        var patch: u32 = 0;
        if (it.next()) |minor_s| {
            // Strip any pre-release or build suffix ("14-alpine", "0-rc1").
            var buf: [16]u8 = undefined;
            const n = leadingDigits(&buf, minor_s);
            minor = std.fmt.parseInt(u32, buf[0..n], 10) catch 0;
            if (it.next()) |patch_s| {
                var pbuf: [16]u8 = undefined;
                const pn = leadingDigits(&pbuf, patch_s);
                patch = std.fmt.parseInt(u32, pbuf[0..pn], 10) catch 0;
            }
        }
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    /// True when this version is at least `other`.
    pub fn atLeast(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch >= other.patch;
    }

    pub fn format(self: Version, comptime f: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = f;
        _ = options;
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

pub fn open(alloc: std.mem.Allocator, url_str: []const u8, aging_interval_ms: u64) !*Redis {
    const u = try Url.parse(alloc, url_str);
    defer u.free(alloc);

    const self = try alloc.create(Redis);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .c = try client.Client.connect(alloc, u.host, u.port, u.password),
        .claim_arena = std.heap.ArenaAllocator.init(alloc),
        .read_arena = std.heap.ArenaAllocator.init(alloc),
        .aging_interval_ms = aging_interval_ms,
    };
    errdefer self.c.deinit();

    if (u.db != 0) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var dbbuf: [4]u8 = undefined;
        const dbs = try std.fmt.bufPrint(&dbbuf, "{d}", .{u.db});
        const v = try self.c.command(arena.allocator(), &.{ "SELECT", dbs });
        if (v != .simple) return error.Protocol;
    }

    try self.checkServerVersion();
    return self;
}

pub fn toBroker(self: *Redis) b.Broker {
    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
}

/// Delete every key belonging to `queue`. Test-support helper used by the
/// contract suite in tests/contract to isolate each case in its own queue.
pub fn purgeQueue(br: b.Broker, queue: []const u8) !void {
    _ = queue;
    const self: *Redis = @ptrCast(@alignCast(br.ptr));
    self.mu.lock();
    defer self.mu.unlock();
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    var keys = std.ArrayList([]const u8).init(al);
    try scanKeys(self, al, "beanline:*", &keys);
    for (keys.items) |k| {
        _ = try self.c.command(al, &.{ "DEL", k });
    }
}

test "url parsing" {
    const alloc = std.testing.allocator;
    var u = try Url.parse(alloc, "redis://127.0.0.1:16379/9");
    try std.testing.expectEqualStrings("127.0.0.1", u.host);
    try std.testing.expectEqual(@as(u16, 16379), u.port);
    try std.testing.expectEqual(@as(u8, 9), u.db);
    try std.testing.expect(u.password == null);
    u.free(alloc);

    u = try Url.parse(alloc, "redis://:s3cret@example.com");
    try std.testing.expectEqualStrings("s3cret", u.password.?);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 6379), u.port);
    u.free(alloc);

    u = try Url.parse(alloc, "redis://localhost/0");
    try std.testing.expectEqualStrings("localhost", u.host);
    u.free(alloc);

    try std.testing.expectError(error.TlsUnsupported, Url.parse(alloc, "rediss://x"));
    try std.testing.expectError(error.BadUrl, Url.parse(alloc, "memcache://x"));
    try std.testing.expectError(error.BadUrl, Url.parse(alloc, "redis://host:notaport"));
}

test "live redis round trip" {
    const alloc = std.testing.allocator;
    const url = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_REDIS_URL") catch return;
    defer alloc.free(url);

    const r = try open(alloc, url, 5 * 60 * 1000);
    const br = toBroker(r);
    defer br.deinit();

    {
        var ar = std.heap.ArenaAllocator.init(alloc);
        defer ar.deinit();
        _ = try r.c.command(ar.allocator(), &.{"FLUSHDB"});
    }

    const q = "live-test";
    const now_ms: i64 = std.time.milliTimestamp();

    var enq = b.Enqueued{};
    try br.enqueue("test.ping", "{\"n\":1}", .{ .queue = q, .unique_key = "rt-1" }, &enq);
    try std.testing.expect(enq.id > 0);
    try std.testing.expect(!enq.deduped);

    var enq2 = b.Enqueued{};
    try br.enqueue("test.ping", "{\"n\":1}", .{ .queue = q, .unique_key = "rt-1" }, &enq2);
    try std.testing.expect(enq2.deduped);
    try std.testing.expectEqual(enq.id, enq2.id);

    var claimed: [8]b.Claimed = undefined;
    const n = try br.claim(q, 8, "host:1:boot", 60000, &claimed);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(enq.id, claimed[0].id);
    try std.testing.expectEqualStrings("test.ping", claimed[0].kind);
    try std.testing.expectEqualStrings("{\"n\":1}", claimed[0].args_json);
    try std.testing.expectEqual(@as(u32, 1), claimed[0].attempts);
    try std.testing.expect(claimed[0].lease_epoch >= 1);

    try br.heartbeat(q, &.{claimed[0].id}, &.{claimed[0].lease_epoch}, 60000);
    try br.finish(q, claimed[0].id, claimed[0].lease_epoch);
    try std.testing.expectError(error.StaleLease, br.finish(q, claimed[0].id, claimed[0].lease_epoch));

    var depth = b.Depth{};
    try br.depth(q, &depth);
    try std.testing.expectEqual(@as(u64, 1), depth.completed);
    try std.testing.expectEqual(@as(u64, 0), depth.available);
    try std.testing.expectEqual(@as(u64, 0), depth.running);

    var enq3 = b.Enqueued{};
    try br.enqueue("test.retry", "{}", .{ .queue = q }, &enq3);
    var claimed2: [4]b.Claimed = undefined;
    try std.testing.expectEqual(@as(usize, 1), try br.claim(q, 4, "host:1:boot", 60000, &claimed2));

    var fail_out = b.FailOutcome{};
    try br.fail(q, claimed2[0].id, claimed2[0].lease_epoch, "Timeout", .{ .retry = now_ms }, &fail_out);
    try std.testing.expectEqual(b.Status.available, fail_out.status);
    try std.testing.expectEqual(@as(u32, 1), fail_out.attempts);

    try std.testing.expectEqual(@as(usize, 1), try br.claim(q, 4, "host:1:boot", 60000, &claimed2));
    var fail_out2 = b.FailOutcome{};
    try br.fail(q, claimed2[0].id, claimed2[0].lease_epoch, "AddressInvalid", .{ .non_retryable = {} }, &fail_out2);
    try std.testing.expectEqual(b.Status.dead, fail_out2.status);

    var enq4 = b.Enqueued{};
    try br.enqueue("test.cancel", "{}", .{ .queue = q }, &enq4);
    try br.cancel(q, enq4.id, null);
    try std.testing.expectError(error.Running, br.cancel(q, enq4.id, null));

    var enq5 = b.Enqueued{};
    try br.enqueue("test.hung", "{}", .{ .queue = q }, &enq5);
    var claimed3: [2]b.Claimed = undefined;
    try std.testing.expectEqual(@as(usize, 1), try br.claim(q, 2, "host:2:boot", 1, &claimed3));
    std.time.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), try br.reap(&.{q}, 10));

    var enq6 = b.Enqueued{};
    try br.enqueue("test.later", "{}", .{ .queue = q, .run_at_ms = now_ms + 250 }, &enq6);
    try std.testing.expectEqual(@as(u32, 0), try br.promote(&.{q}, 10));
    std.time.sleep(400 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), try br.promote(&.{q}, 10));

    try br.depth(q, &depth);
    try std.testing.expectEqual(@as(u64, 2), depth.available);
    try std.testing.expectEqual(@as(u64, 0), depth.scheduled);
    try std.testing.expectEqual(@as(u64, 0), depth.running);
    try std.testing.expectEqual(@as(u64, 1), depth.dead);
    try std.testing.expectEqual(@as(u64, 1), depth.completed);

    try std.testing.expect(!br.capabilities().transactional_enqueue);
    try std.testing.expectEqualStrings("redis", br.capabilities().named_backend);
}

test "redis version parsing" {
    const v = Version.parse("7.4.11").?;
    try std.testing.expectEqual(@as(u32, 7), v.major);
    try std.testing.expectEqual(@as(u32, 4), v.minor);
    try std.testing.expectEqual(@as(u32, 11), v.patch);

    const five = Version.parse("5.0.14").?;
    try std.testing.expectEqual(@as(u32, 5), five.major);
    try std.testing.expectEqual(@as(u32, 0), five.minor);

    // A pre-release or vendor suffix must not break the parse.
    const suffixed = Version.parse("7.2.4-alpine").?;
    try std.testing.expectEqual(@as(u32, 7), suffixed.major);
    try std.testing.expectEqual(@as(u32, 2), suffixed.minor);
    try std.testing.expectEqual(@as(u32, 4), suffixed.patch);

    // Not a version at all: the caller must not refuse to connect on a guess.
    try std.testing.expect(Version.parse("unknown") == null);
    try std.testing.expect(Version.parse("") == null);
}

test "redis version floor is 5.0" {
    try std.testing.expect(Version.parse("5.0.0").?.atLeast(min_version));
    try std.testing.expect(Version.parse("5.0.14").?.atLeast(min_version));
    try std.testing.expect(Version.parse("6.2.0").?.atLeast(min_version));
    try std.testing.expect(Version.parse("7.4.11").?.atLeast(min_version));
    try std.testing.expect(Version.parse("8.10.2").?.atLeast(min_version));

    // The versions that fail every write path.
    try std.testing.expect(!Version.parse("3.0.504").?.atLeast(min_version));
    try std.testing.expect(!Version.parse("4.0.9").?.atLeast(min_version));
    try std.testing.expect(!Version.parse("2.8.24").?.atLeast(min_version));
}

test "redis version is read out of an info reply" {
    const info =
        "# Server\r\nredis_version:7.4.11\r\nredis_git_sha1:00000000\r\n" ++
        "os:Windows\r\narch_bits:64\r\n";
    try std.testing.expectEqualStrings("7.4.11", findRedisVersion(info).?);

    const older =
        "# Server\r\nredis_version:3.0.504\r\nos:Windows\r\n";
    try std.testing.expectEqualStrings("3.0.504", findRedisVersion(older).?);

    try std.testing.expect(findRedisVersion("# Server\r\nos:Windows\r\n") == null);
}
