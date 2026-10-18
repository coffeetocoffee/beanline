const std = @import("std");

// Token bucket; rate 0 means unlimited.
pub const Limiter = struct {
    capacity: f64,
    tokens: f64,
    rate_per_s: f64,
    last_ms: i64 = 0,

    pub fn init(rate_per_s: f64, burst: u32, now_ms: i64) Limiter {
        const cap = @max(@as(f64, @floatFromInt(burst)), 1.0);
        const t = if (rate_per_s <= 0) @as(f64, std.math.inf(f64)) else cap;
        return .{ .capacity = cap, .tokens = t, .rate_per_s = rate_per_s, .last_ms = now_ms };
    }

    pub fn refill(self: *Limiter, now_ms: i64) void {
        if (self.rate_per_s <= 0) return;
        const dt = @as(f64, @floatFromInt(@max(now_ms - self.last_ms, 0))) / 1000.0;
        self.tokens = @min(self.capacity, self.tokens + dt * self.rate_per_s);
        self.last_ms = now_ms;
    }

    pub fn tryAcquire(self: *Limiter, now_ms: i64) bool {
        if (self.rate_per_s <= 0) return true;
        self.refill(now_ms);
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }

    pub fn waitMs(self: *Limiter, now_ms: i64) u64 {
        if (self.rate_per_s <= 0) return 0;
        self.refill(now_ms);
        if (self.tokens >= 1.0) return 0;
        const need = 1.0 - self.tokens;
        const secs = need / self.rate_per_s;
        return @intCast(@max(@as(i64, @intFromFloat(@ceil(secs * 1000.0))), 1));
    }
};

test "rate limit blocks over burst" {
    var l = Limiter.init(10, 3, 1000);
    try std.testing.expect(l.tryAcquire(1000));
    try std.testing.expect(l.tryAcquire(1000));
    try std.testing.expect(l.tryAcquire(1000));
    try std.testing.expect(!l.tryAcquire(1004));
    try std.testing.expect(l.waitMs(1004) <= 100 and l.waitMs(1004) >= 1);
    try std.testing.expect(l.tryAcquire(2100));
}

test "unlimited always allows" {
    var l = Limiter.init(0, 1, 0);
    var i: usize = 0;
    while (i < 100) : (i += 1) try std.testing.expect(l.tryAcquire(0));
}

test "burst capacity spans seconds" {
    var l = Limiter.init(1, 5, 0);
    var i: usize = 0;
    while (i < 5) : (i += 1) try std.testing.expect(l.tryAcquire(0));
    try std.testing.expect(!l.tryAcquire(0));
}
