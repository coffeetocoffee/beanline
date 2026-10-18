const std = @import("std");

pub const MAX_QUEUES = 16;

pub const Scheduler = struct {
    weights: [MAX_QUEUES]u32 = [_]u32{1} ** MAX_QUEUES,
    credit: [MAX_QUEUES]u64 = [_]u64{0} ** MAX_QUEUES,
    n: usize = 0,
    cursor: usize = 0,

    pub fn setWeights(self: *Scheduler, w: []const u32) void {
        std.debug.assert(w.len <= MAX_QUEUES);
        var i: usize = 0;
        while (i < w.len) : (i += 1) {
            self.weights[i] = if (w[i] == 0) 1 else w[i];
        }
        self.n = w.len;
        self.cursor = 0;
        self.credit = [_]u64{0} ** MAX_QUEUES;
    }

    pub fn pick(self: *Scheduler, has_work: []const bool) ?usize {
        if (self.n == 0) return null;
        var checked: usize = 0;
        while (checked < self.n) : (checked += 1) {
            const i = self.cursor;
            if (i < has_work.len and has_work[i]) {
                if (self.credit[i] == 0) self.credit[i] = self.weights[i];
                self.credit[i] -= 1;
                if (self.credit[i] == 0) self.cursor = (i + 1) % self.n;
                return i;
            }
            self.cursor = (i + 1) % self.n;
        }
        return null;
    }

    pub fn refill(self: *Scheduler, i: usize) void {
        self.credit[i] = self.weights[i];
    }
};

test "weighted proportion over a full round" {
    var s = Scheduler{};
    s.setWeights(&[_]u32{ 8, 1 });
    var count = [_]usize{ 0, 0 };
    var k: usize = 0;
    while (k < 9) : (k += 1) {
        const i = s.pick(&[_]bool{ true, true }).?;
        count[i] += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), count[0]);
    try std.testing.expectEqual(@as(usize, 1), count[1]);
}

test "starvation impossible for low weight queue" {
    var s = Scheduler{};
    s.setWeights(&[_]u32{ 100, 1 });
    var k: usize = 0;
    var served_b = false;
    while (k < 101) : (k += 1) {
        const i = s.pick(&[_]bool{ true, true }).?;
        if (i == 1) served_b = true;
    }
    try std.testing.expect(served_b);
}

test "idle queue does not accrue credit" {
    var s = Scheduler{};
    s.setWeights(&[_]u32{ 4, 1 });
    _ = s.pick(&[_]bool{ true, false }).?;
    try std.testing.expectEqual(@as(u64, 3), s.credit[0]);
    _ = s.pick(&[_]bool{ false, true }).?;
    _ = s.pick(&[_]bool{ false, true }).?;
    try std.testing.expectEqual(@as(u64, 3), s.credit[0]);
    _ = s.pick(&[_]bool{ true, false }).?;
    try std.testing.expectEqual(@as(u64, 2), s.credit[0]);
}

test "no work returns null" {
    var s = Scheduler{};
    s.setWeights(&[_]u32{ 2, 2 });
    try std.testing.expect(s.pick(&[_]bool{ false, false }) == null);
}

test "empty scheduler returns null" {
    var s = Scheduler{};
    try std.testing.expect(s.pick(&[_]bool{}) == null);
}

test "zero weight treated as one" {
    var s = Scheduler{};
    s.setWeights(&[_]u32{ 0, 3 });
    try std.testing.expectEqual(@as(u32, 1), s.weights[0]);
    var k: usize = 0;
    var count = [_]usize{ 0, 0 };
    while (k < 4) : (k += 1) {
        const i = s.pick(&[_]bool{ true, true }).?;
        count[i] += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count[0]);
    try std.testing.expectEqual(@as(usize, 3), count[1]);
}
