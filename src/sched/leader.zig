const std = @import("std");
const pg = @import("../broker/pg/conn.zig");
const client = @import("../broker/resp/client.zig");

pub const VTable = struct {
    acquire: *const fn (ctx: *anyopaque, role: []const u8, holder: []const u8, ttl_ms: u64, out_epoch: *u64) anyerror!bool,
    renew: *const fn (ctx: *anyopaque, role: []const u8, holder: []const u8, ttl_ms: u64) anyerror!bool,
    release: *const fn (ctx: *anyopaque, role: []const u8, holder: []const u8) anyerror!void,
};

pub const Lock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn acquire(self: Lock, role: []const u8, holder: []const u8, ttl_ms: u64, out_epoch: *u64) anyerror!bool {
        return self.vtable.acquire(self.ptr, role, holder, ttl_ms, out_epoch);
    }

    pub fn renew(self: Lock, role: []const u8, holder: []const u8, ttl_ms: u64) anyerror!bool {
        return self.vtable.renew(self.ptr, role, holder, ttl_ms);
    }

    pub fn release(self: Lock, role: []const u8, holder: []const u8) anyerror!void {
        return self.vtable.release(self.ptr, role, holder);
    }
};

const SQL_ACQUIRE =
    \\WITH ins AS (
    \\  INSERT INTO beanline_leaders (role, holder, epoch, expires_at)
    \\  VALUES ($1, $2, 1, now() + ($3::bigint * interval '1 millisecond'))
    \\  ON CONFLICT (role) DO UPDATE
    \\    SET holder = EXCLUDED.holder,
    \\        epoch = beanline_leaders.epoch + 1,
    \\        expires_at = EXCLUDED.expires_at
    \\  WHERE beanline_leaders.expires_at <= now() OR beanline_leaders.holder = EXCLUDED.holder
    \\  RETURNING epoch
    \\)
    \\SELECT epoch FROM ins
;

const SQL_RENEW =
    \\UPDATE beanline_leaders SET expires_at = now() + ($3::bigint * interval '1 millisecond')
    \\WHERE role = $1 AND holder = $2
    \\RETURNING epoch
;

const SQL_RELEASE = "UPDATE beanline_leaders SET expires_at = now() WHERE role = $1 AND holder = $2";

pub const PgLeader = struct {
    c: *pg.Conn,

    fn acquireImpl(self: *PgLeader, role: []const u8, holder: []const u8, ttl_ms: u64, out_epoch: *u64) !bool {
        var ttl_buf: [24]u8 = undefined;
        const ttl = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_ms});
        var rows = try self.c.query(SQL_ACQUIRE, &.{ role, holder, ttl });
        defer rows.deinit();
        if (rows.rows.len == 0) {
            out_epoch.* = 0;
            return false;
        }
        out_epoch.* = std.fmt.parseInt(u64, rows.rows[0][0].?, 10) catch return error.Protocol;
        return true;
    }

    fn renewImpl(self: *PgLeader, role: []const u8, holder: []const u8, ttl_ms: u64) !bool {
        var ttl_buf: [24]u8 = undefined;
        const ttl = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_ms});
        var rows = try self.c.query(SQL_RENEW, &.{ role, holder, ttl });
        defer rows.deinit();
        return rows.rows.len > 0;
    }

    fn releaseImpl(self: *PgLeader, role: []const u8, holder: []const u8) !void {
        var rows = try self.c.query(SQL_RELEASE, &.{ role, holder });
        rows.deinit();
    }

    fn acquireCb(ctx: *anyopaque, role: []const u8, holder: []const u8, ttl_ms: u64, out_epoch: *u64) anyerror!bool {
        const self: *PgLeader = @ptrCast(@alignCast(ctx));
        return self.acquireImpl(role, holder, ttl_ms, out_epoch);
    }

    fn renewCb(ctx: *anyopaque, role: []const u8, holder: []const u8, ttl_ms: u64) anyerror!bool {
        const self: *PgLeader = @ptrCast(@alignCast(ctx));
        return self.renewImpl(role, holder, ttl_ms);
    }

    fn releaseCb(ctx: *anyopaque, role: []const u8, holder: []const u8) anyerror!void {
        const self: *PgLeader = @ptrCast(@alignCast(ctx));
        return self.releaseImpl(role, holder);
    }

    const vt = VTable{ .acquire = acquireCb, .renew = renewCb, .release = releaseCb };

    pub fn lock(self: *PgLeader) Lock {
        return .{ .ptr = self, .vtable = &vt };
    }
};

const lua_acquire =
    \\local key = 'beanline:leader:' .. ARGV[1]
    \\local ep = 'beanline:leaderepoch:' .. ARGV[1]
    \\if redis.call('SET', key, ARGV[2], 'NX', 'PX', ARGV[3]) then
    \\  return { 1, redis.call('INCR', ep) }
    \\end
    \\if redis.call('GET', key) == ARGV[2] then
    \\  redis.call('PEXPIRE', key, tonumber(ARGV[3]))
    \\  local cur = redis.call('GET', ep)
    \\  return { 2, tonumber(cur or '0') }
    \\end
    \\return { 0, 0 }
;

const lua_release =
    \\local key = 'beanline:leader:' .. ARGV[1]
    \\if redis.call('GET', key) == ARGV[2] then
    \\  redis.call('DEL', key)
    \\  return 1
    \\end
    \\return 0
;

pub const RedisLeader = struct {
    c: *client.Client,
    alloc: std.mem.Allocator,

    fn evalAcquire(self: *RedisLeader, role: []const u8, holder: []const u8, ttl_ms: u64, out: *u64) !bool {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var ttl_buf: [24]u8 = undefined;
        const ttl = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_ms});
        const v = try self.c.eval(arena.allocator(), lua_acquire, &.{}, &.{ role, holder, ttl });
        const items = v.array;
        const code = try items[0].asInt();
        out.* = @intCast(@max(0, try items[1].asInt()));
        return code == 1 or code == 2;
    }

    fn acquireImpl(self: *RedisLeader, role: []const u8, holder: []const u8, ttl_ms: u64, out_epoch: *u64) !bool {
        return self.evalAcquire(role, holder, ttl_ms, out_epoch);
    }

    fn renewImpl(self: *RedisLeader, role: []const u8, holder: []const u8, ttl_ms: u64) !bool {
        var ep: u64 = 0;
        return self.evalAcquire(role, holder, ttl_ms, &ep);
    }

    fn releaseImpl(self: *RedisLeader, role: []const u8, holder: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        _ = try self.c.eval(arena.allocator(), lua_release, &.{}, &.{ role, holder });
    }

    fn acquireCb(ctx: *anyopaque, role: []const u8, holder: []const u8, ttl_ms: u64, out_epoch: *u64) anyerror!bool {
        const self: *RedisLeader = @ptrCast(@alignCast(ctx));
        return self.acquireImpl(role, holder, ttl_ms, out_epoch);
    }

    fn renewCb(ctx: *anyopaque, role: []const u8, holder: []const u8, ttl_ms: u64) anyerror!bool {
        const self: *RedisLeader = @ptrCast(@alignCast(ctx));
        return self.renewImpl(role, holder, ttl_ms);
    }

    fn releaseCb(ctx: *anyopaque, role: []const u8, holder: []const u8) anyerror!void {
        const self: *RedisLeader = @ptrCast(@alignCast(ctx));
        return self.releaseImpl(role, holder);
    }

    const vt = VTable{ .acquire = acquireCb, .renew = renewCb, .release = releaseCb };

    pub fn lock(self: *RedisLeader) Lock {
        return .{ .ptr = self, .vtable = &vt };
    }
};

fn verifyLockSemantics(lk: Lock, role: []const u8, alloc: std.mem.Allocator) !void {
    _ = alloc;
    var epoch: u64 = 0;

    try std.testing.expect(try lk.acquire(role, "h1", 60_000, &epoch));
    try std.testing.expectEqual(@as(u64, 1), epoch);

    try std.testing.expect(!(try lk.acquire(role, "h2", 60_000, &epoch)));

    try std.testing.expect(try lk.renew(role, "h1", 60_000));
    try std.testing.expect(!(try lk.renew(role, "h2", 60_000)));

    try lk.release(role, "h1");
    try std.testing.expect(try lk.acquire(role, "h2", 60_000, &epoch));
    try std.testing.expectEqual(@as(u64, 2), epoch);

    try std.testing.expect(try lk.acquire(role, "h2", 60_000, &epoch));

    try lk.release(role, "h2");
    try std.testing.expect(try lk.acquire(role, "h1", 300, &epoch));
    std.time.sleep(500 * std.time.ns_per_ms);
    try std.testing.expect(try lk.acquire(role, "h2", 60_000, &epoch));
    try lk.release(role, "h2");
}

test "live leader lease on postgres" {
    const alloc = std.testing.allocator;
    const dsn = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_DSN") catch return;
    defer alloc.free(dsn);
    const postgres = @import("../broker/postgres.zig");
    const p = postgres.open(alloc, dsn, 5 * 60 * 1000) catch return;
    defer alloc.destroy(p);
    defer p.c.deinit();
    try p.c.execSimple("DELETE FROM beanline_leaders WHERE role = 'beanline-test-role'");

    var leader = PgLeader{ .c = &p.c };
    try verifyLockSemantics(leader.lock(), "beanline-test-role", alloc);
    try p.c.execSimple("DELETE FROM beanline_leaders WHERE role = 'beanline-test-role'");
}

test "live leader lease on redis" {
    const alloc = std.testing.allocator;
    const url = std.process.getEnvVarOwned(alloc, "BEANLINE_TEST_REDIS_URL") catch return;
    defer alloc.free(url);
    const redis = @import("../broker/redis.zig");
    const r = redis.open(alloc, url, 5 * 60 * 1000) catch return;
    defer alloc.destroy(r);
    defer r.c.deinit();
    {
        var flush_arena = std.heap.ArenaAllocator.init(alloc);
        defer flush_arena.deinit();
        _ = try r.c.command(flush_arena.allocator(), &.{ "DEL", "beanline:leader:beanline-test-role", "beanline:leaderepoch:beanline-test-role" });
    }

    var leader = RedisLeader{ .c = &r.c, .alloc = alloc };
    try verifyLockSemantics(leader.lock(), "beanline-test-role", alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    _ = try r.c.command(arena.allocator(), &.{ "DEL", "beanline:leader:beanline-test-role", "beanline:leaderepoch:beanline-test-role" });
}
