const std = @import("std");
const civil = @import("civil.zig");
const tzstring = @import("tzstring.zig");

pub const ParseError = error{ BadTzif, OutOfMemory };
pub const Instant = struct { utc: i64, wall: i64, gmtoff: i32, isdst: bool, abbr: []const u8 };

pub const FromLocal = struct {
    count: u8 = 0,
    first: i64 = 0,
    second: i64 = 0,

    pub fn earliest(self: FromLocal) ?i64 {
        return if (self.count > 0) self.first else null;
    }
    pub fn latest(self: FromLocal) ?i64 {
        if (self.count == 2) return self.second;
        return if (self.count == 1) self.first else null;
    }
    pub fn isGap(self: FromLocal) bool {
        return self.count == 0;
    }
    pub fn isFold(self: FromLocal) bool {
        return self.count == 2;
    }
};

const LocalTime = struct { gmtoff: i32, isdst: bool, abbr: []const u8 };

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn be64(b: []const u8) i64 {
    return std.mem.readInt(i64, b[0..8], .big);
}

pub const Zone = struct {
    name: []const u8,
    transitions: []const i64 = &.{},
    local_indices: []const u8 = &.{},
    types: []const LocalTime = &.{},
    tz: tzstring.TzString = .{},
    has_tz: bool = false,

    pub fn free(self: *Zone, alloc: std.mem.Allocator) void {
        const t = @constCast(self.transitions);
        const i = @constCast(self.local_indices);
        const y = @constCast(self.types);
        alloc.free(t);
        alloc.free(i);
        alloc.free(y);
        self.* = .{ .name = "" };
    }

    pub fn parse(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8) ParseError!Zone {
        if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "TZif")) return error.BadTzif;

        var hpos: usize = 0;
        var wide = false;
        {
            const c0 = counts(bytes);
            const p2: usize = 44 + c0.tcnt * 4 + c0.tcnt + c0.lcnt * 6 + c0.cnt + c0.leap * 8 + c0.isstd + c0.isut * 4;
            if (p2 + 44 <= bytes.len and std.mem.eql(u8, bytes[p2..][0..4], "TZif")) {
                hpos = p2;
                wide = true;
            } else if (c0.ver >= '2') {
                hpos = 0;
                wide = true;
            } else {
                hpos = 0;
                wide = false;
            }
        }
        const c = counts(bytes[hpos..]);
        var pos: usize = hpos + 44;

        const trans_width: usize = if (wide) @as(usize, 8) else 4;
        if (pos + c.tcnt * trans_width > bytes.len) return error.BadTzif;
        const transitions = try alloc.alloc(i64, c.tcnt);
        errdefer alloc.free(transitions);
        for (0..c.tcnt) |i| {
            if (wide) {
                transitions[i] = be64(bytes[pos..]);
                pos += 8;
            } else {
                transitions[i] = @as(i32, @bitCast(be32(bytes[pos..])));
                pos += 4;
            }
        }
        if (pos + c.tcnt > bytes.len) return error.BadTzif;
        const local_indices = try alloc.dupe(u8, bytes[pos..][0..c.tcnt]);
        errdefer alloc.free(local_indices);
        pos += c.tcnt;

        if (pos + c.lcnt * 6 > bytes.len) return error.BadTzif;
        const abbr_off = pos + c.lcnt * 6;
        if (abbr_off + c.cnt > bytes.len) return error.BadTzif;
        const abbrs = bytes[abbr_off..][0..c.cnt];
        const types = try alloc.alloc(LocalTime, c.lcnt);
        errdefer alloc.free(types);
        for (0..c.lcnt) |i| {
            const off = pos + i * 6;
            const gmtoff: i32 = @bitCast(be32(bytes[off..]));
            const ai: usize = bytes[off + 5];
            if (ai >= abbrs.len) return error.BadTzif;
            const end = std.mem.indexOfScalarPos(u8, abbrs, ai, 0) orelse abbrs.len;
            types[i] = .{ .gmtoff = gmtoff, .isdst = bytes[off + 4] != 0, .abbr = abbrs[ai..end] };
        }

        var self = Zone{ .name = name, .transitions = transitions, .local_indices = local_indices, .types = types };

        const leap_size: usize = if (wide) @as(usize, 12) else 8;
        const end2 = abbr_off + c.cnt + c.leap * leap_size + c.isstd + c.isut * 4;
        if (end2 < bytes.len and bytes[end2] == '\n') {
            var line = bytes[end2 + 1 ..];
            if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
            if (tzstring.parse(std.mem.trim(u8, line, " \t")) catch null) |t| {
                self.tz = t;
                self.has_tz = true;
            }
        }
        return self;
    }

    const Counts = struct { ver: u8, isut: usize, isstd: usize, leap: usize, tcnt: usize, lcnt: usize, cnt: usize };

    fn counts(h: []const u8) Counts {
        return .{
            .ver = h[4],
            .isut = be32(h[20..24]),
            .isstd = be32(h[24..28]),
            .leap = be32(h[28..32]),
            .tcnt = be32(h[32..36]),
            .lcnt = be32(h[36..40]),
            .cnt = be32(h[40..44]),
        };
    }

    fn lastStdIndex(self: Zone) usize {
        for (self.types, 0..) |ty, i| {
            if (!ty.isdst) return i;
        }
        return 0;
    }

    fn typeAtTable(self: Zone, t: i64) usize {
        const tr = self.transitions;
        if (tr.len == 0) return self.lastStdIndex();
        if (t < tr[0]) return self.lastStdIndex();
        var lo: usize = 0;
        var hi: usize = tr.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (tr[mid] <= t) lo = mid else hi = mid - 1;
        }
        return self.local_indices[lo];
    }

    fn footerActive(self: Zone, t: i64) bool {
        if (!self.has_tz) return false;
        if (self.transitions.len == 0) return true;
        return t >= self.transitions[self.transitions.len - 1];
    }

    pub fn offsetUtc(self: Zone, t: i64) i32 {
        if (self.footerActive(t)) return self.tz.offAtUtc(t);
        return self.types[self.typeAtTable(t)].gmtoff;
    }

    pub fn toLocal(self: Zone, t: i64) Instant {
        if (self.footerActive(t)) {
            const off = self.tz.offAtUtc(t);
            const isdst = self.tz.dst and off == self.tz.dst_off;
            return .{ .utc = t, .wall = t + off, .gmtoff = off, .isdst = isdst, .abbr = if (isdst) self.tz.dst_abbr else self.tz.std_abbr };
        }
        const ty = self.types[self.typeAtTable(t)];
        return .{ .utc = t, .wall = t + ty.gmtoff, .gmtoff = ty.gmtoff, .isdst = ty.isdst, .abbr = ty.abbr };
    }

    fn stdOffset(self: Zone) i32 {
        if (self.transitions.len == 0 and self.has_tz) return self.tz.std_off;
        if (self.transitions.len == 0) return 0;
        return self.types[self.lastStdIndex()].gmtoff;
    }

    pub fn fromLocalWall(self: Zone, wall: i64) FromLocal {
        var out = FromLocal{};
        for ([_]i64{ wall, wall - 86400, wall + 86400, wall - self.stdOffset() }) |g| {
            const o = self.offsetUtc(g);
            const u = wall - o;
            if (self.offsetUtc(u) != o) continue;
            if (out.count == 0) {
                out.first = u;
                out.count = 1;
            } else if (u != out.first and out.count < 2) {
                out.second = u;
                out.count = 2;
            }
        }
        if (out.count == 2 and out.first > out.second) {
            const tmp = out.first;
            out.first = out.second;
            out.second = tmp;
        }
        return out;
    }
};

const ZoneDef = struct { name: []const u8, bytes: []const u8 };

pub const zones = [_]ZoneDef{
    .{ .name = "UTC", .bytes = @embedFile("tzdata/UTC") },
    .{ .name = "Europe/Berlin", .bytes = @embedFile("tzdata/Europe/Berlin") },
    .{ .name = "Europe/London", .bytes = @embedFile("tzdata/Europe/London") },
    .{ .name = "Europe/Amsterdam", .bytes = @embedFile("tzdata/Europe/Amsterdam") },
    .{ .name = "America/New_York", .bytes = @embedFile("tzdata/America/New_York") },
    .{ .name = "America/Los_Angeles", .bytes = @embedFile("tzdata/America/Los_Angeles") },
    .{ .name = "America/Santiago", .bytes = @embedFile("tzdata/America/Santiago") },
    .{ .name = "America/Sao_Paulo", .bytes = @embedFile("tzdata/America/Sao_Paulo") },
    .{ .name = "Asia/Jakarta", .bytes = @embedFile("tzdata/Asia/Jakarta") },
    .{ .name = "Asia/Kolkata", .bytes = @embedFile("tzdata/Asia/Kolkata") },
    .{ .name = "Asia/Tokyo", .bytes = @embedFile("tzdata/Asia/Tokyo") },
    .{ .name = "Asia/Seoul", .bytes = @embedFile("tzdata/Asia/Seoul") },
    .{ .name = "Asia/Shanghai", .bytes = @embedFile("tzdata/Asia/Shanghai") },
    .{ .name = "Australia/Lord_Howe", .bytes = @embedFile("tzdata/Australia/Lord_Howe") },
    .{ .name = "Pacific/Chatham", .bytes = @embedFile("tzdata/Pacific/Chatham") },
    .{ .name = "Africa/Cairo", .bytes = @embedFile("tzdata/Africa/Cairo") },
    .{ .name = "Pacific/Apia", .bytes = @embedFile("tzdata/Pacific/Apia") },
};

pub fn findBytes(name: []const u8) ?[]const u8 {
    for (zones) |z| {
        if (std.mem.eql(u8, z.name, name)) return z.bytes;
    }
    return null;
}

pub fn load(alloc: std.mem.Allocator, name: []const u8) ParseError!?Zone {
    const bytes = findBytes(name) orelse return null;
    return try Zone.parse(alloc, name, bytes);
}

const jan1_2026: i64 = 1767225600;
const mar29_2026 = jan1_2026 + 87 * 86400;
const oct25_2026 = jan1_2026 + 297 * 86400;
const jul1_2026 = jan1_2026 + 181 * 86400;

fn loadTestZone(arena: *std.heap.ArenaAllocator, name: []const u8) !Zone {
    return (try load(arena.allocator(), name)).?;
}

test "berlin footer-driven offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try loadTestZone(&arena, "Europe/Berlin");

    try std.testing.expectEqual(@as(i32, 3600), b.offsetUtc(jan1_2026));
    try std.testing.expectEqual(@as(i32, 7200), b.offsetUtc(jul1_2026));
    try std.testing.expectEqualStrings("CET", b.toLocal(jan1_2026).abbr);
    try std.testing.expectEqualStrings("CEST", b.toLocal(jul1_2026).abbr);
    try std.testing.expect(b.has_tz);

    try std.testing.expectEqual(@as(i32, 3600), b.offsetUtc(mar29_2026 + 3599));
    try std.testing.expectEqual(@as(i32, 7200), b.offsetUtc(mar29_2026 + 3600));
}

test "berlin 2026 gap and fold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try loadTestZone(&arena, "Europe/Berlin");

    const before = b.fromLocalWall(civil.wallOf(2026, 3, 29, 1, 59, 0));
    try std.testing.expectEqual(@as(u8, 1), before.count);

    try std.testing.expectEqual(@as(u8, 0), b.fromLocalWall(civil.wallOf(2026, 3, 29, 2, 30, 0)).count);
    try std.testing.expectEqual(@as(u8, 1), b.fromLocalWall(civil.wallOf(2026, 3, 29, 3, 30, 0)).count);

    const fold = b.fromLocalWall(civil.wallOf(2026, 10, 25, 2, 30, 0));
    try std.testing.expectEqual(@as(u8, 2), fold.count);
    try std.testing.expectEqual(oct25_2026 + 1800, fold.first);
    try std.testing.expectEqual(oct25_2026 + 5400, fold.second);
}

test "fixed and sub-hour zones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var jakarta = try loadTestZone(&arena, "Asia/Jakarta");
    try std.testing.expectEqual(@as(i32, 25200), jakarta.offsetUtc(jan1_2026));
    const r = jakarta.fromLocalWall(jan1_2026 + 25200);
    try std.testing.expectEqual(@as(u8, 1), r.count);
    try std.testing.expectEqual(jan1_2026, r.first);
    jakarta.free(al);

    var tokyo = try loadTestZone(&arena, "Asia/Tokyo");
    try std.testing.expectEqual(@as(i32, 32400), tokyo.offsetUtc(jan1_2026));
    tokyo.free(al);

    var lh = try loadTestZone(&arena, "Australia/Lord_Howe");
    try std.testing.expectEqual(@as(i32, 39600), lh.offsetUtc(jan1_2026));
    try std.testing.expectEqual(@as(i32, 37800), lh.offsetUtc(jul1_2026));
    lh.free(al);

    var ch = try loadTestZone(&arena, "Pacific/Chatham");
    try std.testing.expectEqual(@as(i32, 49500), ch.offsetUtc(jan1_2026));
    try std.testing.expectEqual(@as(i32, 45900), ch.offsetUtc(jul1_2026));
    ch.free(al);
}

test "apia skipped calendar day 2011-12-30" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const apia = try loadTestZone(&arena, "Pacific/Apia");

    try std.testing.expectEqual(@as(u8, 1), apia.fromLocalWall(civil.wallOf(2011, 12, 29, 12, 0, 0)).count);
    try std.testing.expectEqual(@as(u8, 0), apia.fromLocalWall(civil.wallOf(2011, 12, 30, 12, 0, 0)).count);
    try std.testing.expectEqual(@as(u8, 1), apia.fromLocalWall(civil.wallOf(2011, 12, 31, 12, 0, 0)).count);
    try std.testing.expectEqual(@as(i32, 50400), apia.offsetUtc(civil.wallOf(2011, 12, 31, 12, 0, 0) - 50400));
}

test "round trip property across every zone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    for (zones) |zdef| {
        var zone = try loadTestZone(&arena, zdef.name);
        var t: i64 = 63115200;
        while (t < 2524608000) : (t += 41 * 86400 + 61) {
            const inst = zone.toLocal(t);
            const r = zone.fromLocalWall(inst.wall);
            try std.testing.expect(r.count >= 1);
            try std.testing.expect(r.first <= t);
            try std.testing.expect(r.first == t or r.second == t);
            try std.testing.expectEqual(inst.wall, zone.toLocal(r.first).wall);
            if (r.count == 2) {
                try std.testing.expect(r.second > r.first);
                try std.testing.expectEqual(inst.wall, zone.toLocal(r.second).wall);
            }
        }
        zone.free(al);
    }
}

test "unknown zone, corrupt data" {
    try std.testing.expect(findBytes("Mars/Olympus_Mons") == null);
    try std.testing.expect((try load(std.testing.allocator, "Mars/Olympus_Mons")) == null);

    const utc_bytes = findBytes("UTC").?;
    try std.testing.expectError(error.BadTzif, Zone.parse(std.testing.allocator, "x", utc_bytes[0..20]));

    var bogus = [_]u8{0} ** 50;
    @memcpy(bogus[0..4], "TZif");
    std.mem.writeInt(u32, bogus[32..36], 2, .big);
    std.mem.writeInt(u32, bogus[36..40], 1, .big);
    std.mem.writeInt(u32, bogus[40..44], 4, .big);
    try std.testing.expectError(error.BadTzif, Zone.parse(std.testing.allocator, "x", &bogus));
}
