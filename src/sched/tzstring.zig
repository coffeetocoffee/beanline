const std = @import("std");
const civil = @import("civil.zig");

pub const Rule = struct {
    month: u8 = 0,
    mode: u8 = 'M',
    week: u8 = 1,
    dow: u8 = 0,
    time_secs: i32 = 7200,
};

pub const Error = error{BadTzString};

pub const TzString = struct {
    std_abbr: []const u8 = "",
    std_off: i32 = 0,
    dst_abbr: []const u8 = "",
    dst_off: i32 = 0,
    dst: bool = false,
    start: Rule = .{},
    end: Rule = .{},

    pub fn startUtc(self: TzString, year: i64) ?i64 {
        if (!self.dst) return null;
        return ruleLocalSecs(self.start, year) - self.std_off;
    }

    pub fn endUtc(self: TzString, year: i64) ?i64 {
        if (!self.dst) return null;
        return ruleLocalSecs(self.end, year) - self.dst_off;
    }

    pub fn offAtUtc(self: TzString, t: i64) i32 {
        if (!self.dst) return self.std_off;
        const year = civil.civilFromDays(civil.floorDiv(t, 86400)).year;
        const su = self.startUtc(year) orelse return self.std_off;
        const eu = self.endUtc(year) orelse return self.std_off;
        if (su <= eu) {
            if (t >= su and t < eu) return self.dst_off;
        } else {
            if (t >= su or t < eu) return self.dst_off;
        }
        return self.std_off;
    }

    pub fn isDstAt(self: TzString, t: i64) bool {
        return self.offAtUtc(t) == self.dst_off and self.dst;
    }
};

fn readNum(s: []const u8) struct { val: u32, rest: []const u8 } {
    var v: u32 = 0;
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
    }
    return .{ .val = v, .rest = s[i..] };
}

fn parseName(s: []const u8) struct { name: []const u8, rest: []const u8 } {
    if (s.len > 0 and s[0] == '<') {
        const close = std.mem.indexOfScalar(u8, s, '>');
        if (close) |c| return .{ .name = s[1..c], .rest = s[c + 1 ..] };
        return .{ .name = "", .rest = s };
    }
    var i: usize = 0;
    while (i < s.len and s[i] != ',' and s[i] != '-' and s[i] != '+' and !(s[i] >= '0' and s[i] <= '9')) : (i += 1) {}
    return .{ .name = s[0..i], .rest = s[i..] };
}

fn parseTime(s: []const u8) struct { secs: i32, rest: []const u8 } {
    var t = s;
    var neg = false;
    if (t.len > 0 and t[0] == '-') {
        neg = true;
        t = t[1..];
    } else if (t.len > 0 and t[0] == '+') {
        t = t[1..];
    }
    const h = readNum(t);
    var secs: i32 = @intCast(h.val * 3600);
    t = h.rest;
    if (t.len > 0 and t[0] == ':') {
        const m = readNum(t[1..]);
        secs += @intCast(m.val * 60);
        t = m.rest;
        if (t.len > 0 and t[0] == ':') {
            const sec = readNum(t[1..]);
            secs += @intCast(sec.val);
            t = sec.rest;
        }
    }
    return .{ .secs = if (neg) -secs else secs, .rest = t };
}

fn parseRule(s: []const u8) Error!struct { rule: Rule, rest: []const u8 } {
    var rule = Rule{};
    var t = s;
    if (t.len > 0 and t[0] == 'M') {
        const m = readNum(t[1..]);
        if (m.val < 1 or m.val > 12) return error.BadTzString;
        rule.month = @intCast(m.val);
        t = m.rest;
        if (t.len > 0 and t[0] == '.') {
            const w = readNum(t[1..]);
            if (w.val < 1 or w.val > 5) return error.BadTzString;
            rule.week = @intCast(w.val);
            t = w.rest;
            if (t.len > 0 and t[0] == '.') {
                const d = readNum(t[1..]);
                rule.dow = @intCast(d.val);
                t = d.rest;
            }
        }
    } else if (t.len > 0 and t[0] == 'J') {
        rule.mode = 'J';
        const n = readNum(t[1..]);
        if (n.val < 1 or n.val > 365) return error.BadTzString;
        rule.week = @intCast(n.val);
        t = n.rest;
    } else if (t.len > 0 and t[0] >= '0' and t[0] <= '9') {
        rule.mode = 'N';
        const n = readNum(t);
        if (n.val > 365) return error.BadTzString;
        rule.week = @intCast(n.val);
        t = n.rest;
    } else {
        return error.BadTzString;
    }
    if (t.len > 0 and t[0] == '/') {
        const r = parseTime(t[1..]);
        rule.time_secs = r.secs;
        t = r.rest;
    }
    return .{ .rule = rule, .rest = t };
}

pub fn parse(s: []const u8) Error!TzString {
    var tz = TzString{};
    const n1 = parseName(s);
    if (n1.name.len == 0) return error.BadTzString;
    tz.std_abbr = n1.name;
    var t = n1.rest;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+' or (t[0] >= '0' and t[0] <= '9'))) {
        const off = parseTime(t);
        tz.std_off = -off.secs;
        t = off.rest;
    } else {
        return error.BadTzString;
    }
    const n2 = parseName(t);
    if (n2.name.len == 0) return tz;
    t = n2.rest;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+' or (t[0] >= '0' and t[0] <= '9'))) {
        const d = parseTime(t);
        tz.dst_off = -d.secs;
        t = d.rest;
    } else {
        tz.dst_off = tz.std_off + 3600;
    }
    tz.dst_abbr = n2.name;
    tz.dst = true;
    if (t.len > 0 and t[0] == ',') {
        const r1 = try parseRule(t[1..]);
        tz.start = r1.rule;
        t = r1.rest;
        if (t.len == 0 or t[0] != ',') return error.BadTzString;
        const r2 = try parseRule(t[1..]);
        tz.end = r2.rule;
        t = r2.rest;
        if (t.len != 0 and t[0] != '\n') return error.BadTzString;
    }
    return tz;
}

pub fn ruleLocalSecs(rule: Rule, year: i64) i64 {
    const jan1 = civil.daysFromCivil(year, 1, 1);
    var day: i64 = undefined;
    switch (rule.mode) {
        'M' => {
            const first = civil.daysFromCivil(year, rule.month, 1);
            const dow = civil.dowOfDays(first);
            var target = first + civil.floorMod(7 + @as(i64, rule.dow) - @as(i64, dow), 7);
            target += @as(i64, rule.week - 1) * 7;
            const dim: i64 = civil.daysInMonthOf(rule.month, year);
            if (target >= first + dim) target -= 7;
            day = target;
        },
        'J' => {
            var n: i64 = @intCast(rule.week);
            if (civil.isLeap(year) and n >= 60) n += 1;
            day = jan1 + n - 1;
        },
        else => {
            day = jan1 + @as(i64, rule.week);
        },
    }
    return day * 86400 + rule.time_secs;
}

test "posix offsets invert posix sign convention" {
    const berlin = try parse("CET-1CEST,M3.5.0,M10.5.0/3");
    try std.testing.expectEqual(@as(i32, 3600), berlin.std_off);
    try std.testing.expectEqual(@as(i32, 7200), berlin.dst_off);
    try std.testing.expectEqualStrings("CET", berlin.std_abbr);
    try std.testing.expectEqualStrings("CEST", berlin.dst_abbr);

    const ny = try parse("EST5EDT,M3.2.0,M11.1.0");
    try std.testing.expectEqual(@as(i32, -18000), ny.std_off);
    try std.testing.expectEqual(@as(i32, -14400), ny.dst_off);

    const utc = try parse("UTC0");
    try std.testing.expect(!utc.dst);
    try std.testing.expectEqual(@as(i32, 0), utc.std_off);
}

test "berlin 2026 transitions from posix rule" {
    const berlin = try parse("CET-1CEST,M3.5.0,M10.5.0/3");
    try std.testing.expectEqual(@as(i64, 1774746000), berlin.startUtc(2026).?);
    try std.testing.expectEqual(@as(i64, 1792890000), berlin.endUtc(2026).?);

    try std.testing.expectEqual(@as(i32, 3600), berlin.offAtUtc(1767225600));
    try std.testing.expectEqual(@as(i32, 7200), berlin.offAtUtc(1774746000));
    try std.testing.expectEqual(@as(i32, 3600), berlin.offAtUtc(1774745999));
    try std.testing.expectEqual(@as(i32, 3600), berlin.offAtUtc(1792890000));
    try std.testing.expect(berlin.isDstAt(1782864000));
    try std.testing.expect(!berlin.isDstAt(1767225600));
}

test "lord howe and chatham sub-hour rules" {
    const lh = try parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try std.testing.expectEqual(@as(i64, 1791043200), lh.startUtc(2026).?);
    try std.testing.expectEqual(@as(i32, 39600), lh.offAtUtc(1774746000));

    const ch = try parse("CHAST-12:45CHADT-13:45,M9.5.0/2,M4.1.0/3");
    try std.testing.expectEqual(@as(i32, 45900), ch.std_off);
    try std.testing.expectEqual(@as(i32, 49500), ch.dst_off);
}

test "J and N modes and defaults" {
    const n99 = ruleLocalSecs(.{ .mode = 'N', .week = 99, .time_secs = 0 }, 2025);
    try std.testing.expectEqual(@as(i64, 99) * 86400, n99 - civil.daysFromCivil(2025, 1, 1) * 86400);
    const j = ruleLocalSecs(.{ .mode = 'J', .week = 60, .time_secs = 0 }, 2025);
    const mar1 = civil.daysFromCivil(2025, 3, 1) * 86400;
    try std.testing.expectEqual(mar1, j);
}

test "malformed strings rejected" {
    try std.testing.expectError(error.BadTzString, parse("CET"));
    try std.testing.expectError(error.BadTzString, parse("CET-1CEST,M13.1.0,M10.1.0"));
    try std.testing.expectError(error.BadTzString, parse("CET-1CEST,M3.9.0,M10.1.0"));
    try std.testing.expectError(error.BadTzString, parse("CET-1CEST,M3.1.0"));
}
