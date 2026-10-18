const std = @import("std");

const L = std.ArrayList(u8);

pub fn pushInt16(list: *L, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try list.appendSlice(&b);
}

pub fn pushInt32(list: *L, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try list.appendSlice(&b);
}

pub fn pushCstr(list: *L, s: []const u8) !void {
    try list.appendSlice(s);
    try list.append(0);
}

pub const Msg = struct {
    list: *L,
    len_pos: usize,

    pub fn begin(list: *L, tag: u8) !Msg {
        try list.append(tag);
        const len_pos = list.items.len;
        try list.appendNTimes(0, 4);
        return .{ .list = list, .len_pos = len_pos };
    }

    pub fn finish(m: Msg) void {
        const total: u32 = @intCast(m.list.items.len - m.len_pos);
        std.mem.writeInt(u32, m.list.items[m.len_pos .. m.len_pos + 4][0..4], total, .big);
    }
};

pub fn startup(out: *L, user: []const u8, database: []const u8) !void {
    try pushInt32(out, 0);
    try pushInt32(out, 196608);
    try pushCstr(out, "user");
    try pushCstr(out, user);
    try pushCstr(out, "database");
    try pushCstr(out, database);
    try pushCstr(out, "client_encoding");
    try pushCstr(out, "UTF8");
    try out.append(0);
    const len: u32 = @intCast(out.items.len);
    std.mem.writeInt(u32, out.items[0..4], len, .big);
}

pub fn passwordMessage(out: *L, password: []const u8) !void {
    const m = try Msg.begin(out, 'p');
    try pushCstr(out, password);
    m.finish();
}

pub fn saslInitialResponse(out: *L, mechanism: []const u8, initial: []const u8) !void {
    const m = try Msg.begin(out, 'p');
    try pushCstr(out, mechanism);
    try pushInt32(out, @intCast(initial.len));
    try out.appendSlice(initial);
    m.finish();
}

pub fn saslResponse(out: *L, data: []const u8) !void {
    const m = try Msg.begin(out, 'p');
    try out.appendSlice(data);
    m.finish();
}

pub fn simpleQuery(out: *L, sql: []const u8) !void {
    const m = try Msg.begin(out, 'Q');
    try pushCstr(out, sql);
    m.finish();
}

pub fn parse(out: *L, stmt: []const u8, sql: []const u8) !void {
    const m = try Msg.begin(out, 'P');
    try pushCstr(out, stmt);
    try pushCstr(out, sql);
    try pushInt16(out, 0);
    m.finish();
}

pub fn bind(out: *L, portal: []const u8, stmt: []const u8, params: []const ?[]const u8) !void {
    const m = try Msg.begin(out, 'B');
    try pushCstr(out, portal);
    try pushCstr(out, stmt);
    try pushInt16(out, 0);
    try pushInt16(out, @intCast(params.len));
    for (params) |p| {
        if (p) |bytes| {
            try pushInt32(out, @intCast(bytes.len));
            try out.appendSlice(bytes);
        } else {
            try pushInt32(out, 0xFFFF_FFFF);
        }
    }
    try pushInt16(out, 0);
    m.finish();
}

pub fn describe(out: *L, kind: u8, name: []const u8) !void {
    const m = try Msg.begin(out, 'D');
    try out.append(kind);
    try pushCstr(out, name);
    m.finish();
}

pub fn execute(out: *L, portal: []const u8, max_rows: u32) !void {
    const m = try Msg.begin(out, 'E');
    try pushCstr(out, portal);
    try pushInt32(out, max_rows);
    m.finish();
}

pub fn sync(out: *L) !void {
    const m = try Msg.begin(out, 'S');
    m.finish();
}

pub fn terminate(out: *L) !void {
    const m = try Msg.begin(out, 'X');
    m.finish();
}

pub const Frame = struct {
    tag: u8,
    data: []const u8,
    total: usize,
};

pub fn peekFrame(buf: []const u8) ?Frame {
    if (buf.len < 5) return null;
    const len: usize = @intCast(std.mem.readInt(u32, buf[1..5], .big));
    if (len < 4) return null;
    const total = len + 1;
    if (buf.len < total) return null;
    return .{ .tag = buf[0], .data = buf[5..total], .total = total };
}

pub const AuthMethod = union(enum) {
    ok,
    cleartext_password,
    md5: [4]u8,
    sasl_mechanisms: []const []const u8,
    sasl_continue: []const u8,
    sasl_final: []const u8,
    unsupported: u32,
};

pub fn parseAuth(data: []const u8, tmp: *[8][]const u8) AuthMethod {
    const code = std.mem.readInt(u32, data[0..4], .big);
    return switch (code) {
        0 => .ok,
        3 => .cleartext_password,
        5 => blk: {
            if (data.len < 8) return .{ .unsupported = 5 };
            var salt: [4]u8 = undefined;
            @memcpy(&salt, data[4..8]);
            break :blk .{ .md5 = salt };
        },
        10 => blk: {
            var n: usize = 0;
            var i: usize = 4;
            while (i < data.len and n < 8) {
                if (data[i] == 0) break;
                const start = i;
                while (i < data.len and data[i] != 0) : (i += 1) {}
                tmp[n] = data[start..i];
                n += 1;
                i += 1;
            }
            break :blk .{ .sasl_mechanisms = tmp[0..n] };
        },
        11 => .{ .sasl_continue = data[4..] },
        12 => .{ .sasl_final = data[4..] },
        else => .{ .unsupported = code },
    };
}

pub const PgError = struct {
    severity: []const u8 = "",
    sqlstate: []const u8 = "",
    message: []const u8 = "",
};

pub fn parseErrorFields(data: []const u8) PgError {
    var e = PgError{};
    var i: usize = 0;
    while (i < data.len and data[i] != 0) {
        const kind = data[i];
        i += 1;
        const start = i;
        while (i < data.len and data[i] != 0) : (i += 1) {}
        const val = data[start..i];
        i += 1;
        switch (kind) {
            'S' => {
                e.severity = val;
            },
            'C' => {
                e.sqlstate = val;
            },
            'M' => {
                e.message = val;
            },
            else => {},
        }
    }
    return e;
}

pub const Column = struct {
    name: []const u8,
    type_oid: u32,
};

pub fn parseRowDescription(data: []const u8, alloc: std.mem.Allocator) ![]Column {
    const n = std.mem.readInt(u16, data[0..2], .big);
    var cols = try alloc.alloc(Column, n);
    var i: usize = 2;
    var c: usize = 0;
    while (c < n) : (c += 1) {
        const name_start = i;
        while (i < data.len and data[i] != 0) : (i += 1) {}
        const name = try alloc.dupe(u8, data[name_start..i]);
        i += 1;
        _ = std.mem.readInt(u32, data[i..][0..4], .big);
        i += 4;
        _ = std.mem.readInt(u16, data[i..][0..2], .big);
        i += 2;
        const oid = std.mem.readInt(u32, data[i..][0..4], .big);
        i += 4;
        i += 2;
        i += 4;
        i += 2;
        cols[c] = .{ .name = name, .type_oid = oid };
    }
    return cols;
}

pub fn parseDataRow(data: []const u8, alloc: std.mem.Allocator) ![]?[]const u8 {
    const n = std.mem.readInt(u16, data[0..2], .big);
    var cells = try alloc.alloc(?[]const u8, n);
    var i: usize = 2;
    var c: usize = 0;
    while (c < n) : (c += 1) {
        const len: i32 = @bitCast(std.mem.readInt(u32, data[i..][0..4], .big));
        i += 4;
        if (len < 0) {
            cells[c] = null;
        } else {
            const l: usize = @intCast(len);
            cells[c] = try alloc.dupe(u8, data[i .. i + l]);
            i += l;
        }
    }
    return cells;
}

test "startup message layout" {
    var buf = L.init(std.testing.allocator);
    defer buf.deinit();
    try startup(&buf, "bean", "jobs");
    const items = buf.items;
    const len = std.mem.readInt(u32, items[0..4], .big);
    try std.testing.expectEqual(@as(usize, len), items.len);
    try std.testing.expectEqual(@as(u32, 196608), std.mem.readInt(u32, items[4..8], .big));
    try std.testing.expectEqualStrings("user", items[8..12]);
}

test "parameterized bind encodes text and nulls" {
    var buf = L.init(std.testing.allocator);
    defer buf.deinit();
    try bind(&buf, "", "", &.{ "hello", null, "5" });
    try std.testing.expectEqual(@as(u8, 'B'), buf.items[0]);
    const len = std.mem.readInt(u32, buf.items[1..5], .big);
    try std.testing.expectEqual(buf.items.len, len + 1);
    const nparams_at = 5 + 1 + 1 + 2;
    const n = std.mem.readInt(u16, buf.items[nparams_at .. nparams_at + 2], .big);
    try std.testing.expectEqual(@as(u16, 3), n);
    var i: usize = nparams_at + 2;
    const l1 = std.mem.readInt(u32, buf.items[i..][0..4], .big);
    i += 4;
    try std.testing.expectEqualStrings("hello", buf.items[i .. i + l1]);
    i += l1;
    const lnull = std.mem.readInt(u32, buf.items[i..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), lnull);
    i += 4;
    const l3 = std.mem.readInt(u32, buf.items[i..][0..4], .big);
    i += 4;
    try std.testing.expectEqualStrings("5", buf.items[i .. i + l3]);
}

test "frame peek handles partial and complete buffers" {
    var buf = L.init(std.testing.allocator);
    defer buf.deinit();
    try simpleQuery(&buf, "SELECT 1");
    const full = buf.items;
    try std.testing.expect(peekFrame(full[0..0]) == null);
    try std.testing.expect(peekFrame(full[0..3]) == null);
    try std.testing.expect(peekFrame(full[0 .. full.len - 1]) == null);
    const f = peekFrame(full).?;
    try std.testing.expectEqual(@as(u8, 'Q'), f.tag);
    try std.testing.expectEqualStrings("SELECT 1\x00", f.data);
    try std.testing.expectEqual(full.len, f.total);
}

test "auth requests parse" {
    var tmp: [8][]const u8 = undefined;
    var buf = L.init(std.testing.allocator);
    defer buf.deinit();
    try pushInt32(&buf, 0);
    try std.testing.expect(parseAuth(buf.items, &tmp) == .ok);

    buf.clearRetainingCapacity();
    try pushInt32(&buf, 5);
    try buf.appendSlice(&.{ 1, 2, 3, 4 });
    const md5m = parseAuth(buf.items, &tmp);
    try std.testing.expectEqual(@as(u8, 1), md5m.md5[0]);
    try std.testing.expectEqual(@as(u8, 4), md5m.md5[3]);

    buf.clearRetainingCapacity();
    try pushInt32(&buf, 10);
    try pushCstr(&buf, "SCRAM-SHA-256");
    try pushCstr(&buf, "SCRAM-SHA-256-PLUS");
    try buf.append(0);
    const sasl = parseAuth(buf.items, &tmp);
    try std.testing.expectEqual(@as(usize, 2), sasl.sasl_mechanisms.len);
    try std.testing.expectEqualStrings("SCRAM-SHA-256", sasl.sasl_mechanisms[0]);

    buf.clearRetainingCapacity();
    try pushInt32(&buf, 3);
    try std.testing.expect(parseAuth(buf.items, &tmp) == .cleartext_password);
}

test "error fields parse" {
    var buf = L.init(std.testing.allocator);
    defer buf.deinit();
    try buf.append('S');
    try pushCstr(&buf, "ERROR");
    try buf.append('C');
    try pushCstr(&buf, "XX000");
    try buf.append('M');
    try pushCstr(&buf, "relation \"x\" does not exist");
    try buf.append(0);
    const e = parseErrorFields(buf.items);
    try std.testing.expectEqualStrings("ERROR", e.severity);
    try std.testing.expectEqualStrings("XX000", e.sqlstate);
    try std.testing.expectEqualStrings("relation \"x\" does not exist", e.message);
}

test "row description and data row parse" {
    var buf = L.init(std.testing.allocator);
    defer buf.deinit();
    try pushInt16(&buf, 2);
    try pushCstr(&buf, "id");
    try pushInt32(&buf, 0);
    try pushInt16(&buf, 0);
    try pushInt32(&buf, 20);
    try pushInt16(&buf, 8);
    try pushInt32(&buf, 0xFFFFFFFF);
    try pushInt16(&buf, 0);
    try pushCstr(&buf, "name");
    try pushInt32(&buf, 0);
    try pushInt16(&buf, 0);
    try pushInt32(&buf, 25);
    try pushInt16(&buf, 0xFFFF);
    try pushInt32(&buf, 0xFFFFFFFF);
    try pushInt16(&buf, 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cols = try parseRowDescription(buf.items, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("id", cols[0].name);
    try std.testing.expectEqual(@as(u32, 20), cols[0].type_oid);
    try std.testing.expectEqualStrings("name", cols[1].name);

    var rowbuf = L.init(std.testing.allocator);
    defer rowbuf.deinit();
    try pushInt16(&rowbuf, 2);
    try pushInt32(&rowbuf, 3);
    try rowbuf.appendSlice("471");
    try pushInt32(&rowbuf, 0xFFFFFFFF);
    const cells = try parseDataRow(rowbuf.items, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    try std.testing.expectEqualStrings("471", cells[0].?);
    try std.testing.expect(cells[1] == null);
}
