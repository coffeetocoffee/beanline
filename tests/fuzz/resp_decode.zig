const std = @import("std");
const beanline = @import("beanline");
const resp = beanline.Resp;
const harness = @import("harness.zig");

/// Fuzz target: the RESP reply decoder used by the in-house Redis client, which
/// also parses the arrays our Lua claim scripts return. Panics here mean a
/// crafted server reply can crash a worker.
const Cursor = struct {
    data: []const u8,
    pos: usize = 0,
};

fn makeReader(data: []const u8) struct {
    cursor: Cursor,
    fn read(ptr: *anyopaque, dest: []u8) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.cursor.pos >= self.cursor.data.len) return 0;
        const n = @min(dest.len, self.cursor.data.len - self.cursor.pos);
        @memcpy(dest[0..n], self.cursor.data[self.cursor.pos .. self.cursor.pos + n]);
        self.cursor.pos += n;
        return n;
    }
    fn reader(self: *@This()) resp.ByteReader {
        return .{ .ptr = self, .read_fn = read };
    }
} {
    return .{ .cursor = .{ .data = data, .pos = 0 } };
}

/// One fuzz step: decode the input as a RESP reply, then walk the resulting
/// value through the accessors the broker uses, so type-confusion bugs in
/// asInt/asString are exercised too. A malformed reply is returned as an error
/// (the harness counts that as "rejected"); a crash is the failure we hunt.
pub fn fuzzOneInput(alloc: std.mem.Allocator, data: []const u8) !void {
    // Random text almost never starts with a RESP type byte, so prepend one:
    // this makes the decoder actually parse instead of rejecting everything.
    var prefixed: [4097]u8 = undefined;
    if (data.len + 1 > prefixed.len) return error.TooLong;
    const types = "+-$:*";
    prefixed[0] = types[data.len % types.len];
    @memcpy(prefixed[1..][0..data.len], data);

    var r = makeReader(prefixed[0 .. data.len + 1]);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try resp.parseReply(r.reader(), a);
    switch (v) {
        .array => |items| {
            for (items) |item| {
                _ = item.asInt() catch {};
                _ = item.asString() catch {};
                _ = item.isArray();
            }
        },
        else => {
            _ = v.asInt() catch {};
            _ = v.asString() catch {};
        },
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    const o = harness.options(argv);
    var report = harness.Report{};
    const target = struct {
        fn t(ctx: *const std.mem.Allocator, data: []const u8) anyerror!void {
            return fuzzOneInput(ctx.*, data);
        }
    }.t;

    try harness.drive(&alloc, target, harness.Corpus.init(o.seed, o.max_len), o.iterations, &report);
    try std.io.getStdOut().writer().print("iterations={d} accepted={d} rejected={d}\n", .{ report.iterations, report.accepted, report.interesting });
    return 0;
}

test "resp decoder accepts well formed replies" {
    const alloc = std.testing.allocator;
    try fuzzOneInput(alloc, "+OK\r\n");
    try fuzzOneInput(alloc, ":42\r\n");
    try fuzzOneInput(alloc, "$5\r\nhello\r\n");
    try fuzzOneInput(alloc, "$-1\r\n");
    try fuzzOneInput(alloc, "*2\r\n:1\r\n$2\r\nok\r\n");
}

test "resp decoder rejects garbage without crashing" {
    const alloc = std.testing.allocator;
    // These must fail to parse, not panic.
    fuzzOneInput(alloc, "") catch {};
    fuzzOneInput(alloc, "??\r\n") catch {};
    fuzzOneInput(alloc, "$99999\r\nshort") catch {};
    fuzzOneInput(alloc, "*1\r\n+unterminated") catch {};
    fuzzOneInput(alloc, ":notanumber\r\n") catch {};
}

test "accessors reject the wrong type" {
    const alloc = std.testing.allocator;
    var r = makeReader(":7\r\n");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = try resp.parseReply(r.reader(), arena.allocator());
    try std.testing.expectEqual(@as(i64, 7), try v.asInt());
    try std.testing.expectError(error.Protocol, v.asString());
}
