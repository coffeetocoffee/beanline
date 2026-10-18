const std = @import("std");

pub fn floorDiv(a: i64, b: i64) i64 {
    var q = @divTrunc(a, b);
    if (@mod(a, b) != 0 and ((a < 0) != (b < 0))) q -= 1;
    return q;
}

pub fn floorMod(a: i64, b: i64) i64 {
    return @mod(a, b);
}

pub const Civil = struct { year: i64, month: u32, day: u32 };

pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy: i64 = if (m <= 2) y - 1 else y;
    const era: i64 = floorDiv(yy, 400);
    const yoe: i64 = yy - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(z: i64) Civil {
    const z2 = z + 719468;
    const era = floorDiv(if (z2 >= 0) z2 else z2 - 146096, 146097);
    const doe = z2 - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

pub fn wallOf(y: i64, mo: i64, d: i64, hh: i64, mm: i64, ss: i64) i64 {
    return daysFromCivil(y, mo, d) * 86400 + (hh * 3600 + mm * 60 + ss);
}

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonthOf(mon: u32, year: i64) i32 {
    const table = [14]i32{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 0 };
    if (mon == 2 and isLeap(year)) return 29;
    return table[mon];
}

pub fn dowOfDays(days: i64) u8 {
    return @intCast(floorMod(days + 4, 7));
}

test "civil round trip and wall" {
    var y: i64 = 1969;
    while (y <= 2101) : (y += 9) {
        for ([_]i64{ 1, 2, 3, 12 }) |m| {
            const d = daysFromCivil(y, m, 15);
            const c = civilFromDays(d);
            try std.testing.expectEqual(y, c.year);
            try std.testing.expectEqual(@as(u32, @intCast(m)), c.month);
            try std.testing.expectEqual(@as(u32, 15), c.day);
        }
    }
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 1767225600), wallOf(2026, 1, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(i64, 21243), daysFromCivil(2028, 2, 29));
    try std.testing.expect(isLeap(2024) and !isLeap(2100) and isLeap(2000));
}
