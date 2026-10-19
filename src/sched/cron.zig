const std = @import("std");
const tz = @import("tz.zig");

pub const Field = struct {
    mask: u64,
    star: bool,

    pub fn has(self: Field, value: u32) bool {
        const bit = @as(u64, 1) << @intCast(value);
        return self.mask & bit != 0;
    }
};

pub const Civil = struct { year: u32, month: u32, day: u32 };

pub const Schedule = struct {
    minute: Field,
    hour: Field,
    dom: Field,
    month: Field,
    dow: Field,

    pub fn parse(expr: []const u8) error{InvalidCron}!Schedule {
        const expanded = try expandDescriptor(expr);
        var tokens: [5][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, expanded, " \t");
        while (it.next()) |tok| : (n += 1) {
            if (n >= tokens.len) return error.InvalidCron;
            tokens[n] = tok;
        }
        if (n != 5) return error.InvalidCron;

        const minute = try parseField(tokens[0], 0, 59);
        const hour = try parseField(tokens[1], 0, 23);
        const dom = try parseField(tokens[2], 1, 31);
        const month = try parseField(tokens[3], 1, 12);
        var dow = try parseField(tokens[4], 0, 7);
        const sunday_alias = dow.mask & (@as(u64, 1) << 7) != 0;
        if (sunday_alias) {
            dow.mask &= ~(@as(u64, 1) << 7);
            dow.mask |= @as(u64, 1) << 0;
        }

        return .{
            .minute = minute,
            .hour = hour,
            .dom = dom,
            .month = month,
            .dow = dow,
        };
    }

    pub fn matchesAt(self: Schedule, ts: i64) bool {
        if (floorMod(ts, 60) != 0) return false;
        const day_idx = floorDiv(ts, 86400);
        const rem = floorMod(ts, 86400);
        const civil = civilFromDays(day_idx);
        if (!self.month.has(civil.month)) return false;
        if (!self.dayMatches(day_idx, civil)) return false;
        if (!self.hour.has(@intCast(@divTrunc(rem, 3600)))) return false;
        if (!self.minute.has(@intCast(@divTrunc(@mod(rem, 3600), 60)))) return false;
        return true;
    }

    /// True when the month set contains at least one month in which `day`
    /// can occur (day <= 28 always can; 29 needs Feb or a 30/31-day month;
    /// 30/31 need a matching long month).
    fn monthCanHold(month: Field, day: u32) bool {
        if (day <= 28) return true;
        if (day == 29) {
            // Feb (leap years) or any 30/31-day month works.
            return month.has(2) or month.has(1) or month.has(3) or month.has(4) or
                month.has(5) or month.has(6) or month.has(7) or month.has(8) or
                month.has(9) or month.has(10) or month.has(11) or month.has(12);
        }
        if (day == 30) {
            var m: u32 = 1;
            while (m <= 12) : (m += 1) {
                if (m != 2 and month.has(m)) return true;
            }
            return false;
        }
        // day 31: needs a 31-day month.
        for ([_]u32{ 1, 3, 5, 7, 8, 10, 12 }) |m| {
            if (month.has(m)) return true;
        }
        return false;
    }

    pub fn next(self: Schedule, after: i64) ?i64 {
        // Fast reject for day-of-month values that can never occur (e.g.
        // Feb 30/31): without this, a day that exists in no selected month
        // spins the day-step all the way to the 2100 limit — ~10M iterations
        // per call, and nextIn() repeats the scan up to 100k times. When
        // both dom and dow are restricted, either one matching is enough
        // (crontab OR semantics), so only reject when neither can fire.
        if (!self.dom.star and !self.dow.star) {
            var dom_possible = false;
            var d: u32 = 1;
            while (d <= 31) : (d += 1) {
                if (self.dom.has(d) and monthCanHold(self.month, d)) {
                    dom_possible = true;
                    break;
                }
            }
            if (!dom_possible) {
                var dow_possible = false;
                var w: u32 = 0;
                while (w <= 6) : (w += 1) {
                    if (self.dow.has(w)) {
                        dow_possible = true;
                        break;
                    }
                }
                if (!dow_possible) return null;
            }
        } else if (!self.dom.star) {
            var dom_possible = false;
            var d: u32 = 1;
            while (d <= 31) : (d += 1) {
                if (self.dom.has(d) and monthCanHold(self.month, d)) {
                    dom_possible = true;
                    break;
                }
            }
            if (!dom_possible) return null;
        }
        var t = after - floorMod(after, 60) + 60;
        const limit = daysFromCivil(2100, 1, 1) * 86400;
        var guard: u64 = 0;
        while (t <= limit) : (guard += 1) {
            if (guard > 10_000_000) return null;
            const day_idx = floorDiv(t, 86400);
            const rem = floorMod(t, 86400);
            const civil = civilFromDays(day_idx);

            if (!self.month.has(civil.month)) {
                var ny: i64 = @intCast(civil.year);
                var nm: i64 = @as(i64, @intCast(civil.month)) + 1;
                if (nm > 12) {
                    nm = 1;
                    ny += 1;
                }
                t = daysFromCivil(ny, nm, 1) * 86400;
                continue;
            }

            if (!self.dayMatches(day_idx, civil)) {
                t = (day_idx + 1) * 86400;
                continue;
            }

            const hour: u32 = @intCast(@divTrunc(rem, 3600));
            if (!self.hour.has(hour)) {
                var h: u32 = hour + 1;
                var found: ?u32 = null;
                while (h < 24) : (h += 1) {
                    if (self.hour.has(h)) {
                        found = h;
                        break;
                    }
                }
                t = if (found) |h2|
                    day_idx * 86400 + @as(i64, h2) * 3600
                else
                    (day_idx + 1) * 86400;
                continue;
            }

            const min: u32 = @intCast(@divTrunc(@mod(rem, 3600), 60));
            if (!self.minute.has(min)) {
                var m2: u32 = min + 1;
                var found: ?u32 = null;
                while (m2 < 60) : (m2 += 1) {
                    if (self.minute.has(m2)) {
                        found = m2;
                        break;
                    }
                }
                t = if (found) |mf|
                    day_idx * 86400 + @as(i64, hour) * 3600 + @as(i64, mf) * 60
                else
                    day_idx * 86400 + @as(i64, hour + 1) * 3600;
                continue;
            }

            return t;
        }
        return null;
    }

    fn dayMatches(self: Schedule, day_idx: i64, civil: Civil) bool {
        const wd: u32 = @intCast(floorMod(day_idx + 4, 7));
        if (self.dom.star and self.dow.star) return true;
        if (!self.dom.star and !self.dow.star) {
            return self.dom.has(civil.day) or self.dow.has(wd);
        }
        if (!self.dom.star) return self.dom.has(civil.day);
        return self.dow.has(wd);
    }

    pub fn nextIn(self: Schedule, zone: *const tz.Zone, after_utc: i64) ?i64 {
        var l = zone.toLocal(after_utc).wall;
        var guard: usize = 0;
        while (guard < 100_000) : (guard += 1) {
            const lc = self.next(l) orelse return null;
            l = lc;
            const inst = zone.fromLocalWall(lc);
            if (inst.count == 0) continue;
            var k: usize = 0;
            while (k < inst.count) : (k += 1) {
                const u = if (k == 0) inst.first else inst.second;
                if (u > after_utc) return u;
            }
        }
        return null;
    }
};

fn expandDescriptor(expr: []const u8) error{InvalidCron}![]const u8 {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len > 0 and trimmed[0] == '@') {
        const map = [_]struct { []const u8, []const u8 }{
            .{ "@hourly", "0 * * * *" },
            .{ "@daily", "0 0 * * *" },
            .{ "@midnight", "0 0 * * *" },
            .{ "@weekly", "0 0 * * 0" },
            .{ "@monthly", "0 0 1 * *" },
            .{ "@yearly", "0 0 1 1 *" },
            .{ "@annually", "0 0 1 1 *" },
        };
        for (map) |entry| {
            if (std.mem.eql(u8, trimmed, entry[0])) return entry[1];
        }
        return error.InvalidCron;
    }
    return trimmed;
}

fn parseField(expr: []const u8, lo: u32, hi: u32) error{InvalidCron}!Field {
    var mask: u64 = 0;
    const star = std.mem.eql(u8, expr, "*");
    var parts = std.mem.splitScalar(u8, expr, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidCron;
        var body = part;
        var step: u32 = 1;
        var has_step = false;
        if (std.mem.indexOfScalar(u8, part, '/')) |si| {
            body = part[0..si];
            step = std.fmt.parseInt(u32, part[si + 1 ..], 10) catch return error.InvalidCron;
            if (step == 0) return error.InvalidCron;
            has_step = true;
        }
        var seg_lo: u32 = undefined;
        var seg_hi: u32 = undefined;
        if (std.mem.eql(u8, body, "*")) {
            seg_lo = lo;
            seg_hi = hi;
        } else if (std.mem.indexOfScalar(u8, body, '-')) |di| {
            seg_lo = std.fmt.parseInt(u32, body[0..di], 10) catch return error.InvalidCron;
            seg_hi = std.fmt.parseInt(u32, body[di + 1 ..], 10) catch return error.InvalidCron;
        } else {
            seg_lo = std.fmt.parseInt(u32, body, 10) catch return error.InvalidCron;
            seg_hi = if (has_step) hi else seg_lo;
        }
        if (seg_lo < lo or seg_hi > hi or seg_lo > seg_hi) return error.InvalidCron;
        var v: u32 = seg_lo;
        while (v <= seg_hi) : (v += step) {
            mask |= @as(u64, 1) << @intCast(v);
            if (v > seg_hi - @min(step, seg_hi)) break;
        }
    }
    if (mask == 0) return error.InvalidCron;
    return .{ .mask = mask, .star = star };
}

fn floorDiv(a: i64, b: i64) i64 {
    var q = @divTrunc(a, b);
    if (@mod(a, b) != 0 and ((a < 0) != (b < 0))) q -= 1;
    return q;
}

fn floorMod(a: i64, b: i64) i64 {
    return @mod(a, b);
}

pub fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y: i64 = if (m <= 2) y0 - 1 else y0;
    const era: i64 = @divTrunc((if (y >= 0) y else y - 399), 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(z: i64) Civil {
    const z2 = z + 719468;
    const era: i64 = @divTrunc((if (z2 >= 0) z2 else z2 - 146096), 146097);
    const doe: i64 = z2 - era * 146097;
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: i64 = @divTrunc(5 * doy + 2, 153);
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const y2: i64 = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0));
    return .{ .year = @intCast(y2), .month = @intCast(m), .day = @intCast(d) };
}

const jan1_2026: i64 = 1767225600;

fn expectNext(expr: []const u8, after: i64, expected: i64) !void {
    const s = try Schedule.parse(expr);
    const got = s.next(after);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(expected, got.?);
    try std.testing.expect(got.? > after);
    try std.testing.expect(s.matchesAt(got.?));
    try std.testing.expect(!s.matchesAt(got.? - 60));
}

test "every quarter hour" {
    try expectNext("*/15 * * * *", jan1_2026, jan1_2026 + 900);
}

test "daily midnight" {
    try expectNext("0 0 * * *", jan1_2026, jan1_2026 + 86400);
    try expectNext("0 0 * * *", jan1_2026 + 1, jan1_2026 + 86400);
}

test "daily at 02:30" {
    try expectNext("30 2 * * *", jan1_2026, jan1_2026 + 2 * 3600 + 30 * 60);
}

test "weekly sunday noon" {
    try expectNext("0 12 * * 0", jan1_2026, jan1_2026 + 3 * 86400 + 12 * 3600);
}

test "monthly first midnight" {
    try expectNext("0 0 1 * *", jan1_2026, jan1_2026 + 31 * 86400);
}

test "feb 29 next leap year" {
    try expectNext("0 0 29 2 *", jan1_2026, daysFromCivil(2028, 2, 29) * 86400);
}

test "dom or dow fires on either" {
    try expectNext("0 0 13 * 5", jan1_2026, jan1_2026 + 86400);
}

test "descriptors expand" {
    const daily = try Schedule.parse("@daily");
    const explicit = try Schedule.parse("0 0 * * *");
    try std.testing.expectEqual(explicit.minute.mask, daily.minute.mask);
    try std.testing.expectEqual(explicit.hour.mask, daily.hour.mask);
    try std.testing.expectEqual(explicit.dom.mask, daily.dom.mask);
    try std.testing.expectEqual(explicit.month.mask, daily.month.mask);
    try std.testing.expectEqual(explicit.dow.mask, daily.dow.mask);
    try std.testing.expect(error.InvalidCron == Schedule.parse("@reboot"));
}

test "sunday alias 7" {
    const a = try Schedule.parse("0 0 * * 7");
    const b = try Schedule.parse("0 0 * * 0");
    try std.testing.expectEqual(b.dow.mask, a.dow.mask);
}

test "ranges lists and steps parse" {
    const s = try Schedule.parse("0-10,20,30-40/5 8-18/2 * 1,6-8 *");
    try std.testing.expect(s.minute.has(0));
    try std.testing.expect(s.minute.has(7));
    try std.testing.expect(!s.minute.has(15));
    try std.testing.expect(s.minute.has(20));
    try std.testing.expect(s.minute.has(30));
    try std.testing.expect(s.minute.has(35));
    try std.testing.expect(!s.minute.has(45));
    try std.testing.expect(s.hour.has(8));
    try std.testing.expect(s.hour.has(10));
    try std.testing.expect(!s.hour.has(9));
    try std.testing.expect(s.hour.has(18));
    try std.testing.expect(s.month.has(1));
    try std.testing.expect(s.month.has(7));
    try std.testing.expect(!s.month.has(2));
}

test "invalid expressions rejected" {
    const bad = [_][]const u8{
        "",
        "60 * * * *",
        "* * * *",
        "0 24 * * *",
        "0 0 0 * *",
        "0 0 32 * *",
        "0 0 15-5 * *",
        "*/0 * * * *",
        "0 0 * * 8",
        "* * * * * * *",
        "@reboot",
        "@nope",
        "abc * * * *",
        "1,,2 * * * *",
    };
    for (bad) |expr| {
        if (Schedule.parse(expr)) |_| {
            std.debug.print("expected rejection for: {s}\n", .{expr});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "impossible date returns null" {
    const s = try Schedule.parse("0 0 30 2 *");
    try std.testing.expect(s.next(jan1_2026) == null);
}

test "impossible dates return null fast" {
    // Feb 30/31 and 31st-of-a-30-day-month can never occur. They must be
    // rejected up front: the day-step scan would otherwise walk to the 2100
    // limit (~10M iterations), and nextIn() repeats the scan per candidate.
    // The timer keeps the suite honest — this whole table must resolve in
    // milliseconds, not minutes.
    const t0 = std.time.milliTimestamp();
    const cases = [_][]const u8{
        "0 0 30 2 *",
        "0 0 31 2 *",
        "0 0 31 4 *",
        "0 0 31 6 *",
        "0 0 31 9 *",
        "0 0 31 11 *",
        "0 0 31 2,4,6,9,11 *",
    };
    for (cases) |expr| {
        const s = try Schedule.parse(expr);
        try std.testing.expect(s.next(0) == null);
    }
    // OR semantics still work: a valid dow saves an impossible dom.
    {
        const s = try Schedule.parse("0 0 31 2 3");
        try std.testing.expect(s.next(0) != null);
    }
    // Feb 29 is possible (leap years) and still resolves via the scan.
    {
        const s = try Schedule.parse("0 0 29 2 *");
        try std.testing.expect(s.next(0) != null);
    }
    const dt = std.time.milliTimestamp() - t0;
    try std.testing.expect(dt < 5000);
}

test "civil round trip" {
    const ms = [_]u32{ 1, 2, 3, 12 };
    var y: i64 = 1969;
    while (y <= 2100) : (y += 7) {
        for (ms) |m| {
            const d = daysFromCivil(y, @intCast(m), 15);
            const c = civilFromDays(d);
            try std.testing.expectEqual(y, @as(i64, @intCast(c.year)));
            try std.testing.expectEqual(m, c.month);
            try std.testing.expectEqual(@as(u32, 15), c.day);
        }
    }
}

test "nextIn skips the dst spring-forward gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const berlin = (try tz.load(arena.allocator(), "Europe/Berlin")).?;

    const s = try Schedule.parse("30 2 * * *");
    const after_utc = jan1_2026 + 87 * 86400;
    const got = s.nextIn(&berlin, after_utc).?;
    try std.testing.expectEqual(jan1_2026 + 88 * 86400 + 1800, got);

    const r = berlin.fromLocalWall(berlin.toLocal(got).wall);
    try std.testing.expect(r.count >= 1);
}

test "nextIn fires ambiguous fold time once (earliest)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const berlin = (try tz.load(arena.allocator(), "Europe/Berlin")).?;

    const s = try Schedule.parse("30 2 * * *");
    const oct25_utc = jan1_2026 + 297 * 86400;
    const first = s.nextIn(&berlin, oct25_utc - 60).?;
    try std.testing.expectEqual(oct25_utc + 1800, first);

    const next_day = s.nextIn(&berlin, first).?;
    try std.testing.expectEqual(jan1_2026 + 298 * 86400 + 5400, next_day);

    const from_fold = s.nextIn(&berlin, oct25_utc + 4000).?;
    try std.testing.expectEqual(oct25_utc + 5400, from_fold);
}

test "nextIn hourly monotonic across a new york year" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ny = (try tz.load(arena.allocator(), "America/New_York")).?;

    const s = try Schedule.parse("0 * * * *");
    var t: i64 = 1735689600;
    var count: usize = 0;
    while (t < 1735689600 + 366 * 86400 and count < 9000) {
        const nx = s.nextIn(&ny, t).?;
        try std.testing.expect(nx > t);
        try std.testing.expect(nx - t <= 7300);
        try std.testing.expect(nx - t >= 2300);
        t = nx;
        count += 1;
    }
    try std.testing.expect(count > 8000);
}
