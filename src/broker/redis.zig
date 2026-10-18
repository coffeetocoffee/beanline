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

    fn enqueueImpl(self: *Redis, kind: []const u8, args_json: []const u8, opts: b.EnqueueOptions, out: *b.Enqueued) !void {
        if (opts.unique == .replace) return error.UnsupportedUnique;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const now: i64 = std.time.milliTimestamp();
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
            try std.fmt.allocPrint(al, "{d}", .{now}),
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
        const now: i64 = std.time.milliTimestamp();
        const argv = [_][]const u8{
            queue,
            worker_id,
            try std.fmt.allocPrint(al, "{d}", .{now}),
            try std.fmt.allocPrint(al, "{d}", .{lease_ms}),
            try std.fmt.allocPrint(al, "{d}", .{bounded}),
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
        _ = try self.c.eval(al, heartbeat_lua, &.{}, argv.items);
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

    fn failImpl(self: *Redis, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, retryable: bool, retry_at_ms: i64, out: *b.FailOutcome) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const al = arena.allocator();
        const now: i64 = std.time.milliTimestamp();
        const retry_s: []const u8 = if (retryable) "1" else "0";
        const argv = [_][]const u8{
            queue,
            try std.fmt.allocPrint(al, "{d}", .{id}),
            try std.fmt.allocPrint(al, "{d}", .{lease_epoch}),
            retry_s,
            try std.fmt.allocPrint(al, "{d}", .{retry_at_ms}),
            try std.fmt.allocPrint(al, "{d}", .{now}),
            err_name,
        };
        const v = try self.c.eval(al, fail_lua, &.{}, &argv);
        const items = switch (v) {
            .array => |a| a,
            else => return error.StaleLease,
        };
        if (items.len != 3) return error.StaleLease;
        const status_s = try items[0].asString();
        out.status = b.Status.fromSql(status_s) orelse return error.Protocol;
        out.retry_at_ms = try items[1].asInt();
        out.attempts = @intCast(try items[2].asInt());
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
            const now: i64 = std.time.milliTimestamp();
            const argv = [_][]const u8{
                queue,
                try std.fmt.allocPrint(al, "{d}", .{now}),
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
    try self.enqueueImpl(kind, args_json, opts, out);
}

fn claimCb(ctx: *anyopaque, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []b.Claimed) anyerror!usize {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    return try self.claimImpl(queue, limit, worker_id, lease_ms, out);
}

fn heartbeatCb(ctx: *anyopaque, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try self.heartbeatImpl(queue, ids, epochs, lease_ms);
}

fn finishCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try self.finishImpl(queue, id, lease_epoch);
}

fn failCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, retryable: bool, retry_at_ms: i64, out: *b.FailOutcome) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try self.failImpl(queue, id, lease_epoch, err_name, retryable, retry_at_ms, out);
}

fn cancelCb(ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: ?u64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try self.cancelImpl(queue, id, lease_epoch);
}

fn promoteCb(ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32 {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    return try self.promoteImpl(queues, limit);
}

fn reapCb(ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32 {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    return try self.reapImpl(queues, limit);
}

fn depthCb(ctx: *anyopaque, queue: []const u8, out: *b.Depth) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try self.depthImpl(queue, out);
}

fn capabilitiesCb() b.Capabilities {
    return .{ .transactional_enqueue = false, .pubsub_wakeups = false, .named_backend = "redis" };
}

fn deinitCb(ctx: *anyopaque) void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    self.claim_arena.deinit();
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
        .lease_epoch = @intCast(@max(0, parseI64(hashGet(fields, "epoch")))),
        .worker_id = try alloc.dupe(u8, hashGet(fields, "worker") orelse ""),
        .inserted_ms = parseI64(hashGet(fields, "inserted_at")),
        .started_ms = parseI64(hashGet(fields, "finished_at")),
        .finished_ms = parseI64(hashGet(fields, "finished_at")),
    };
}

fn listJobsImpl(self: *Redis, alloc: std.mem.Allocator, filter: b.JobFilter, out: *std.ArrayList(b.JobRow)) !void {
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
        try out.append(try rowFromHash(alloc, qname, id, fields));
        emitted += 1;
    }
}

fn getJobImpl(self: *Redis, alloc: std.mem.Allocator, id: i64, out: *?b.JobRow) !void {
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
        out.* = try rowFromHash(alloc, qname, id, fields);
        return;
    }
    out.* = null;
}

fn jobEventsImpl(self: *Redis, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(b.EventRow)) !void {
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
                .event_type = try alloc.dupe(u8, ev_type),
                .data_json = try alloc.dupe(u8, raw),
                .at_ms = 0,
            });
        }
        return;
    }
}

fn queueNamesImpl(self: *Redis, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const al = arena.allocator();
    var keys = std.ArrayList([]const u8).init(al);
    try scanKeys(self, al, "beanline:{*}:depth", &keys);
    for (keys.items) |k| {
        const qname = queueOfKey(k) orelse continue;
        try out.append(try alloc.dupe(u8, qname));
    }
}

const redis_retry_lua =
    \\local prefix = 'beanline:{' .. ARGV[1] .. '}'
    \\local jk = prefix .. ':job:' .. ARGV[2]
    \\local st = redis.call('HGET', jk, 'status')
    \\if st ~= 'dead' and st ~= 'cancelled' then return 0 end
    \\redis.call('HSET', jk, 'status', 'available', 'run_at', ARGV[3], 'attempts', '0')
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
    \\redis.call('HSET', jk, 'status', 'discarded', 'finished_at', ARGV[3])
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

fn listJobsCb(ctx: *anyopaque, alloc: std.mem.Allocator, filter: b.JobFilter, out: *std.ArrayList(b.JobRow)) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try listJobsImpl(self, alloc, filter, out);
}

fn getJobCb(ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *?b.JobRow) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try getJobImpl(self, alloc, id, out);
}

fn jobEventsCb(ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(b.EventRow)) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try jobEventsImpl(self, alloc, id, out);
}

fn queueNamesCb(ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try queueNamesImpl(self, alloc, out);
}

fn retryCb(ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try retryImpl(self, queue, id);
}

fn discardCb(ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void {
    const self: *Redis = @ptrCast(@alignCast(ctx));
    try discardImpl(self, queue, id);
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
};

pub fn open(alloc: std.mem.Allocator, url_str: []const u8) !*Redis {
    const u = try Url.parse(alloc, url_str);
    defer u.free(alloc);

    const self = try alloc.create(Redis);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .c = try client.Client.connect(alloc, u.host, u.port, u.password),
        .claim_arena = std.heap.ArenaAllocator.init(alloc),
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
    return self;
}

pub fn toBroker(self: *Redis) b.Broker {
    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
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

    const r = try open(alloc, url);
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
    try br.fail(q, claimed2[0].id, claimed2[0].lease_epoch, "Timeout", true, now_ms, &fail_out);
    try std.testing.expectEqual(b.Status.available, fail_out.status);
    try std.testing.expectEqual(@as(u32, 1), fail_out.attempts);

    try std.testing.expectEqual(@as(usize, 1), try br.claim(q, 4, "host:1:boot", 60000, &claimed2));
    var fail_out2 = b.FailOutcome{};
    try br.fail(q, claimed2[0].id, claimed2[0].lease_epoch, "AddressInvalid", false, 0, &fail_out2);
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
