const std = @import("std");

pub const Jitter = enum { none, full, equal, decorrelated };

pub const Backoff = struct {
    base_ms: u64 = 1000,
    cap_ms: u64 = 1800000,
    factor: f64 = 2.0,
    jitter: Jitter = .full,
    schedule: []const u64 = &.{},

    pub fn rawDelayMs(self: Backoff, attempts: u32) u64 {
        if (self.schedule.len > 0) {
            const a = @max(attempts, @as(u32, 1));
            const idx = @min(a, self.schedule.len) - 1;
            return self.schedule[idx];
        }
        const exp: u32 = if (attempts == 0) 0 else attempts - 1;
        const base: f64 = @floatFromInt(self.base_ms);
        const cap: f64 = @floatFromInt(self.cap_ms);
        const v = base * std.math.pow(f64, self.factor, @floatFromInt(exp));
        if (std.math.isNan(v) or v >= cap) return self.cap_ms;
        return @min(@as(u64, @intFromFloat(v)), self.cap_ms);
    }

    pub fn delayMs(self: Backoff, attempts: u32, prev_ms: u64, rng: std.Random) u64 {
        if (self.schedule.len > 0) return self.rawDelayMs(attempts);
        const raw = self.rawDelayMs(attempts);
        if (raw == 0) return 0;
        return switch (self.jitter) {
            .none => raw,
            .full => rng.uintLessThan(u64, raw),
            .equal => blk: {
                const half = raw / 2;
                break :blk half + rng.uintLessThan(u64, raw - half);
            },
            .decorrelated => blk: {
                const lo = self.base_ms;
                const prev_eff: u64 = if (prev_ms == 0) self.base_ms else prev_ms;
                const hi = @min(self.cap_ms, prev_eff *% 3);
                if (hi <= lo) break :blk lo;
                break :blk lo + rng.uintLessThan(u64, hi - lo + 1);
            },
        };
    }
};

test "exponential growth without jitter" {
    const b = Backoff{ .jitter = .none };
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    try std.testing.expectEqual(@as(u64, 1000), b.delayMs(1, 0, r));
    try std.testing.expectEqual(@as(u64, 2000), b.delayMs(2, 1000, r));
    try std.testing.expectEqual(@as(u64, 4000), b.delayMs(3, 2000, r));
    try std.testing.expectEqual(@as(u64, 8000), b.delayMs(4, 4000, r));
    try std.testing.expectEqual(@as(u64, 16000), b.delayMs(5, 8000, r));
    try std.testing.expectEqual(@as(u64, 32000), b.delayMs(6, 16000, r));
}

test "cap clamps exponential growth" {
    const b = Backoff{ .jitter = .none, .cap_ms = 5000 };
    var prng = std.Random.DefaultPrng.init(2);
    const r = prng.random();
    try std.testing.expectEqual(@as(u64, 4000), b.delayMs(3, 0, r));
    try std.testing.expectEqual(@as(u64, 5000), b.delayMs(4, 0, r));
    try std.testing.expectEqual(@as(u64, 5000), b.delayMs(50, 0, r));
}

test "literal schedule is exact and clamped" {
    const b = Backoff{ .schedule = &[_]u64{ 5000, 300000 }, .jitter = .full };
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    try std.testing.expectEqual(@as(u64, 5000), b.delayMs(1, 0, r));
    try std.testing.expectEqual(@as(u64, 300000), b.delayMs(2, 0, r));
    try std.testing.expectEqual(@as(u64, 300000), b.delayMs(9, 0, r));
}

test "full jitter stays in bounds" {
    const b = Backoff{ .jitter = .full };
    var prng = std.Random.DefaultPrng.init(4);
    const r = prng.random();
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const d = b.delayMs(4, 0, r);
        try std.testing.expect(d < 8000);
    }
}

test "equal jitter stays in bounds" {
    const b = Backoff{ .jitter = .equal };
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const d = b.delayMs(4, 0, r);
        try std.testing.expect(d >= 4000);
        try std.testing.expect(d < 8000);
    }
}

test "decorrelated jitter stays in bounds" {
    const b = Backoff{ .jitter = .decorrelated, .base_ms = 100 };
    var prng = std.Random.DefaultPrng.init(6);
    const r = prng.random();
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const d = b.delayMs(4, 1000, r);
        try std.testing.expect(d >= 100);
        try std.testing.expect(d <= 3000);
    }
    try std.testing.expect(b.delayMs(1, 0, r) >= 100);
    try std.testing.expect(b.delayMs(1, 0, r) <= 301);
}

test "zero base produces zero delay" {
    const b = Backoff{ .jitter = .none, .base_ms = 0 };
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    try std.testing.expectEqual(@as(u64, 0), b.delayMs(1, 0, r));
}
