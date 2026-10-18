const std = @import("std");

pub const Value = union(enum) {
    simple: []const u8,
    err: []const u8,
    int: i64,
    bulk: ?[]const u8,
    array: []const Value,

    pub fn asString(self: Value) ![]const u8 {
        return switch (self) {
            .simple => |s| s,
            .bulk => |b| b orelse error.Protocol,
            else => error.Protocol,
        };
    }

    pub fn asInt(self: Value) !i64 {
        return switch (self) {
            .int => |i| i,
            .bulk => |b| std.fmt.parseInt(i64, b orelse return error.Protocol, 10) catch error.Protocol,
            else => error.Protocol,
        };
    }

    pub fn isArray(self: Value) bool {
        return switch (self) {
            .array => true,
            else => false,
        };
    }
};

pub fn encodeCommand(out: *std.ArrayList(u8), args: []const []const u8) !void {
    const w = out.writer();
    try w.print("*{d}\r\n", .{args.len});
    for (args) |a| {
        try w.print("${d}\r\n", .{a.len});
        try out.appendSlice(a);
        try out.appendSlice("\r\n");
    }
}

pub const ByteReader = struct {
    ptr: *anyopaque,
    read_fn: *const fn (ptr: *anyopaque, dest: []u8) anyerror!usize,

    pub fn read(self: ByteReader, dest: []u8) anyerror!usize {
        return self.read_fn(self.ptr, dest);
    }

    pub fn readNoEof(self: ByteReader, dest: []u8) !void {
        var n: usize = 0;
        while (n < dest.len) {
            const k = try self.read(dest[n..]);
            if (k == 0) return error.ConnectionClosed;
            n += k;
        }
    }
};

pub fn readLine(r: ByteReader, arena: std.mem.Allocator) ![]const u8 {
    var line = std.ArrayList(u8).init(arena);
    var one: [1]u8 = undefined;
    while (true) {
        try r.readNoEof(&one);
        if (one[0] == '\r') {
            try r.readNoEof(&one);
            if (one[0] != '\n') return error.Protocol;
            return try line.toOwnedSlice();
        }
        try line.append(one[0]);
    }
}

pub fn parseReply(r: ByteReader, arena: std.mem.Allocator) !Value {
    const line = try readLine(r, arena);
    if (line.len == 0) return error.Protocol;
    const body = line[1..];
    switch (line[0]) {
        '+' => return .{ .simple = body },
        '-' => return .{ .err = body },
        ':' => return .{ .int = std.fmt.parseInt(i64, body, 10) catch return error.Protocol },
        '$' => {
            if (std.mem.eql(u8, body, "-1")) return .{ .bulk = null };
            const len = std.fmt.parseInt(usize, body, 10) catch return error.Protocol;
            const buf = try arena.alloc(u8, len + 2);
            try r.readNoEof(buf);
            if (buf[len] != '\r' or buf[len + 1] != '\n') return error.Protocol;
            return .{ .bulk = buf[0..len] };
        },
        '*' => {
            if (std.mem.eql(u8, body, "-1")) return .{ .array = &.{} };
            const n = std.fmt.parseInt(usize, body, 10) catch return error.Protocol;
            if (n > 100_000) return error.Protocol;
            const items = try arena.alloc(Value, n);
            for (0..n) |i| {
                items[i] = try parseReply(r, arena);
            }
            return .{ .array = items };
        },
        else => return error.Protocol,
    }
}

pub const Client = struct {
    stream: std.net.Stream,
    rbuf: [16384]u8 = undefined,
    rpos: usize = 0,
    rlen: usize = 0,
    last_error: []const u8 = "",

    pub fn connect(alloc: std.mem.Allocator, host: []const u8, port: u16, password: ?[]const u8) !Client {
        var self = Client{ .stream = try std.net.tcpConnectToHost(alloc, host, port) };
        errdefer self.stream.close();
        if (password) |pw| {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const v = try self.command(arena.allocator(), &.{ "AUTH", pw });
            switch (v) {
                .simple => {},
                .err => |e| {
                    self.last_error = e;
                    return error.AuthFailed;
                },
                else => return error.Protocol,
            }
        }
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.stream.close();
    }

    fn socketRead(ptr: *anyopaque, dest: []u8) anyerror!usize {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (self.rpos >= self.rlen) {
            const n = try self.stream.read(&self.rbuf);
            if (n == 0) return error.ConnectionClosed;
            self.rpos = 0;
            self.rlen = n;
        }
        const k = @min(dest.len, self.rlen - self.rpos);
        @memcpy(dest[0..k], self.rbuf[self.rpos..][0..k]);
        self.rpos += k;
        return k;
    }

    fn reader(self: *Client) ByteReader {
        return .{ .ptr = self, .read_fn = socketRead };
    }

    pub fn command(self: *Client, arena: std.mem.Allocator, args: []const []const u8) !Value {
        var out = std.ArrayList(u8).init(arena);
        defer out.deinit();
        try encodeCommand(&out, args);
        try self.stream.writeAll(out.items);
        const v = try parseReply(self.reader(), arena);
        if (v == .err) {
            self.last_error = v.err;
            return error.RedisCommand;
        }
        return v;
    }

    pub fn eval(
        self: *Client,
        arena: std.mem.Allocator,
        script: []const u8,
        keys: []const []const u8,
        argv: []const []const u8,
    ) !Value {
        var args = std.ArrayList([]const u8).initCapacity(arena, 3 + keys.len + argv.len) catch return error.OutOfMemory;
        args.appendAssumeCapacity("EVAL");
        args.appendAssumeCapacity(script);
        var nbuf: [8]u8 = undefined;
        const nkeys = std.fmt.bufPrint(&nbuf, "{d}", .{keys.len}) catch unreachable;
        args.appendAssumeCapacity(nkeys);
        args.appendSlice(keys) catch return error.OutOfMemory;
        args.appendSlice(argv) catch return error.OutOfMemory;
        return self.command(arena, args.items);
    }
};

const TestBox = struct {
    fbs: std.io.FixedBufferStream([]const u8),

    fn br(ptr: *anyopaque, dest: []u8) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.fbs.read(dest) catch unreachable;
    }

    fn reader(self: *@This()) ByteReader {
        return .{ .ptr = self, .read_fn = @This().br };
    }
};

fn parseOne(data: []const u8, arena: std.mem.Allocator) !Value {
    var box = TestBox{ .fbs = std.io.fixedBufferStream(data) };
    return parseReply(box.reader(), arena);
}

test "encode command as RESP array" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try encodeCommand(&buf, &.{"PING"});
    try std.testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", buf.items);

    buf.clearRetainingCapacity();
    try encodeCommand(&buf, &.{ "SET", "k", "" });
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n", buf.items);
}

test "parse scalar replies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parseOne("+OK\r\n", a);
    try std.testing.expectEqualStrings("OK", ok.simple);

    const e = try parseOne("-ERR unknown\r\n", a);
    try std.testing.expectEqualStrings("ERR unknown", e.err);

    const i = try parseOne(":42\r\n", a);
    try std.testing.expectEqual(@as(i64, 42), i.int);

    const neg = try parseOne(":-1\r\n", a);
    try std.testing.expectEqual(@as(i64, -1), neg.int);

    const b = try parseOne("$5\r\nhello\r\n", a);
    try std.testing.expectEqualStrings("hello", b.bulk.?);

    const nullb = try parseOne("$-1\r\n", a);
    try std.testing.expect(nullb.bulk == null);

    const empty = try parseOne("$0\r\n\r\n", a);
    try std.testing.expectEqual(@as(usize, 0), empty.bulk.?.len);
}

test "parse nested arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOne("*2\r\n:1\r\n*2\r\n$2\r\nab\r\n$-1\r\n", a);
    try std.testing.expectEqual(@as(usize, 2), v.array.len);
    try std.testing.expectEqual(@as(i64, 1), v.array[0].int);
    try std.testing.expectEqualStrings("ab", v.array[1].array[0].bulk.?);
    try std.testing.expect(v.array[1].array[1].bulk == null);

    const empty_arr = try parseOne("*0\r\n", a);
    try std.testing.expectEqual(@as(usize, 0), empty_arr.array.len);
}

test "bulk containing CRLF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseOne("$6\r\na\r\nb\nc\r\n", a);
    try std.testing.expectEqualStrings("a\r\nb\nc", v.bulk.?);
}

test "asString and asInt helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try parseOne("$3\r\n123\r\n", a);
    try std.testing.expectEqualStrings("123", try b.asString());
    try std.testing.expectEqual(@as(i64, 123), try b.asInt());
    try std.testing.expectError(error.Protocol, (try parseOne("+OK\r\n", a)).asInt());
}
