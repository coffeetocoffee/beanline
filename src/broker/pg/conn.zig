const std = @import("std");
const proto = @import("proto.zig");
const scram = @import("scram.zig");
const Md5 = std.crypto.hash.Md5;
const b64 = std.base64.standard;

pub const Config = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    pub fn free(self: Config, alloc: std.mem.Allocator) void {
        alloc.free(self.host);
        alloc.free(self.user);
        alloc.free(self.password);
        alloc.free(self.database);
    }
};

pub fn parseDsn(alloc: std.mem.Allocator, dsn: []const u8) !Config {
    var rest = dsn;
    if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else {
        return error.BadDsn;
    }

    var user: []const u8 = "postgres";
    var password: []const u8 = "";
    var hostport = rest;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        hostport = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            user = userinfo[0..colon];
            password = userinfo[colon + 1 ..];
        } else {
            user = userinfo;
        }
    }

    var host = hostport;
    var port: u16 = 5432;
    if (std.mem.indexOfScalar(u8, hostport, '/')) |slash| {
        host = hostport[0..slash];
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, host, ':') != std.mem.lastIndexOfScalar(u8, host, ':')) return error.BadDsn;
        port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return error.BadDsn;
        host = host[0..colon];
    }

    var database: []const u8 = "postgres";
    if (std.mem.indexOfScalar(u8, hostport, '/')) |slash| {
        var db = hostport[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, db, '?')) |q| db = db[0..q];
        if (db.len > 0) database = db;
    }

    if (host.len == 0 or user.len == 0) return error.BadDsn;
    if (std.mem.startsWith(u8, host, "[")) return error.BadDsn;

    return .{
        .host = try alloc.dupe(u8, host),
        .port = port,
        .user = try alloc.dupe(u8, user),
        .password = try alloc.dupe(u8, password),
        .database = try alloc.dupe(u8, database),
    };
}

pub const RemoteError = struct {
    sqlstate: []const u8,
    message: []const u8,
    severity: []const u8,

    pub fn deinit(self: RemoteError, alloc: std.mem.Allocator) void {
        alloc.free(self.sqlstate);
        alloc.free(self.message);
        alloc.free(self.severity);
    }
};

pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    columns: []proto.Column,
    rows: [][]?[]const u8,
    command_tag: []const u8,

    pub fn deinit(self: *Rows) void {
        self.arena.deinit();
    }

    pub fn rowCountFromTag(tag: []const u8) ?u64 {
        const idx = std.mem.lastIndexOfScalar(u8, tag, ' ') orelse return null;
        return std.fmt.parseInt(u64, tag[idx + 1 ..], 10) catch null;
    }
};

pub const Conn = struct {
    stream: std.net.Stream,
    alloc: std.mem.Allocator,
    in: std.ArrayList(u8),
    read_pos: usize = 0,
    last_error: ?RemoteError = null,
    cf_buf: [512]u8 = undefined,
    cf: ?scram.ClientFirst = null,
    server_sig: [44]u8 = undefined,
    md5_buf: [40]u8 = undefined,

    pub fn connect(alloc: std.mem.Allocator, cfg: Config) !Conn {
        const stream = try std.net.tcpConnectToHost(alloc, cfg.host, cfg.port);
        var c = Conn{
            .stream = stream,
            .alloc = alloc,
            .in = std.ArrayList(u8).init(alloc),
        };
        errdefer c.deinit();

        var out = std.ArrayList(u8).init(alloc);
        defer out.deinit();
        try proto.startup(&out, cfg.user, cfg.database);
        try c.stream.writeAll(out.items);
        try c.authenticate(cfg);
        return c;
    }

    pub fn deinit(self: *Conn) void {
        if (self.last_error) |e| {
            e.deinit(self.alloc);
            self.last_error = null;
        }
        var term = std.ArrayList(u8).init(self.alloc);
        defer term.deinit();
        proto.terminate(&term) catch {};
        self.stream.writeAll(term.items) catch {};
        self.stream.close();
        self.in.deinit();
    }

    pub fn lastError(self: *Conn) ?RemoteError {
        return self.last_error;
    }

    pub fn rollbackBestEffort(self: *Conn) void {
        self.execSimple("ROLLBACK") catch {};
    }

    fn clearLastError(self: *Conn) void {
        if (self.last_error) |e| {
            e.deinit(self.alloc);
            self.last_error = null;
        }
    }

    fn setLastError(self: *Conn, e: proto.PgError) void {
        self.clearLastError();
        self.last_error = RemoteError{
            .sqlstate = self.alloc.dupe(u8, e.sqlstate) catch "",
            .message = self.alloc.dupe(u8, e.message) catch "",
            .severity = self.alloc.dupe(u8, e.severity) catch "",
        };
    }

    fn fill(self: *Conn) !void {
        var tmp: [16384]u8 = undefined;
        const n = try self.stream.read(&tmp);
        if (n == 0) return error.ConnectionClosed;
        try self.in.appendSlice(tmp[0..n]);
    }

    fn compact(self: *Conn) void {
        if (self.read_pos == 0) return;
        std.mem.copyForwards(u8, self.in.items[0 .. self.in.items.len - self.read_pos], self.in.items[self.read_pos..]);
        self.in.items.len -= self.read_pos;
        self.read_pos = 0;
    }

    fn nextFrame(self: *Conn) !proto.Frame {
        while (true) {
            self.compact();
            if (proto.peekFrame(self.in.items)) |f| return f;
            try self.fill();
        }
    }

    fn consume(self: *Conn, f: proto.Frame) void {
        self.read_pos += f.total;
        if (self.read_pos >= self.in.items.len) {
            self.in.clearRetainingCapacity();
            self.read_pos = 0;
        }
    }

    fn authenticate(self: *Conn, cfg: Config) !void {
        var mechs: [8][]const u8 = undefined;
        var got_error = false;
        while (true) {
            const f = try self.nextFrame();
            defer self.consume(f);
            switch (f.tag) {
                'R' => {
                    const auth = proto.parseAuth(f.data, &mechs);
                    switch (auth) {
                        .ok => {},
                        .cleartext_password => {
                            var out = std.ArrayList(u8).init(self.alloc);
                            defer out.deinit();
                            try proto.passwordMessage(&out, cfg.password);
                            try self.stream.writeAll(out.items);
                        },
                        .md5 => |salt| {
                            const pw = try self.md5Password(cfg, salt);
                            var out = std.ArrayList(u8).init(self.alloc);
                            defer out.deinit();
                            try proto.passwordMessage(&out, pw);
                            try self.stream.writeAll(out.items);
                        },
                        .sasl_mechanisms => |list| {
                            var has = false;
                            for (list) |m| {
                                if (std.mem.eql(u8, m, "SCRAM-SHA-256")) {
                                    has = true;
                                    break;
                                }
                            }
                            if (!has) return error.UnsupportedAuth;
                            var raw: [18]u8 = undefined;
                            std.crypto.random.bytes(&raw);
                            var nonce_buf: [32]u8 = undefined;
                            const nonce = b64.Encoder.encode(&nonce_buf, &raw);
                            self.cf = scram.buildClientFirst(cfg.user, nonce, &self.cf_buf);
                            var out = std.ArrayList(u8).init(self.alloc);
                            defer out.deinit();
                            try proto.saslInitialResponse(&out, "SCRAM-SHA-256", self.cf.?.full);
                            try self.stream.writeAll(out.items);
                        },
                        .sasl_continue => |server_first| {
                            const cf = self.cf orelse return error.ProtocolViolation;
                            const ridx = std.mem.indexOf(u8, cf.bare, ",r=") orelse return error.ProtocolViolation;
                            const client_nonce = cf.bare[ridx + 3 ..];
                            const fin = try scram.computeFinal(cfg.password, client_nonce, cf.bare, server_first);
                            self.server_sig = fin.server_sig;
                            var out = std.ArrayList(u8).init(self.alloc);
                            defer out.deinit();
                            try proto.saslResponse(&out, fin.fullMessage());
                            try self.stream.writeAll(out.items);
                        },
                        .sasl_final => |data| {
                            if (data.len < 2) return error.ProtocolViolation;
                            if (data[0] == 'e') return error.SaslError;
                            if (data[0] != 'v') return error.ProtocolViolation;
                            const sig = data[2..];
                            if (sig.len != 44 or !std.mem.eql(u8, sig, self.server_sig[0..44])) return error.SaslSignatureMismatch;
                        },
                        .unsupported => return error.UnsupportedAuth,
                    }
                },
                'S', 'K' => {},
                'Z' => {
                    if (got_error) return error.Remote;
                    return;
                },
                'E' => {
                    const e = proto.parseErrorFields(f.data);
                    self.setLastError(e);
                    got_error = true;
                },
                else => return error.ProtocolViolation,
            }
        }
    }

    fn md5Password(self: *Conn, cfg: Config, salt: [4]u8) ![]const u8 {
        var stage: [320]u8 = undefined;
        const pw_user = std.fmt.bufPrint(&stage, "{s}{s}", .{ cfg.password, cfg.user }) catch return error.CredentialsTooLong;
        var inner: [16]u8 = undefined;
        Md5.hash(pw_user, &inner, .{});
        const hex1 = std.fmt.bytesToHex(inner, .lower);
        var stage2: [4 + 32 + 4]u8 = undefined;
        @memcpy(stage2[0..3], "md5");
        @memcpy(stage2[3..35], &hex1);
        @memcpy(stage2[35..39], &salt);
        var outer: [16]u8 = undefined;
        Md5.hash(stage2[0..39], &outer, .{});
        const hex2 = std.fmt.bytesToHex(outer, .lower);
        @memcpy(self.md5_buf[0..3], "md5");
        @memcpy(self.md5_buf[3..35], &hex2);
        return self.md5_buf[0..35];
    }

    pub fn execSimple(self: *Conn, sql: []const u8) !void {
        self.clearLastError();
        var out = std.ArrayList(u8).init(self.alloc);
        defer out.deinit();
        try proto.simpleQuery(&out, sql);
        try self.stream.writeAll(out.items);

        var got_error = false;
        while (true) {
            const f = try self.nextFrame();
            defer self.consume(f);
            switch (f.tag) {
                'E' => {
                    const e = proto.parseErrorFields(f.data);
                    self.setLastError(e);
                    got_error = true;
                },
                'Z' => {
                    if (got_error) return error.Remote;
                    return;
                },
                'C', 'T', 'D', 'N', 'S', 'I', '1', '2' => {},
                else => return error.ProtocolViolation,
            }
        }
    }

    pub fn query(self: *Conn, sql: []const u8, params: []const ?[]const u8) !Rows {
        self.clearLastError();
        var out = std.ArrayList(u8).init(self.alloc);
        defer out.deinit();
        try proto.parse(&out, "", sql);
        try proto.bind(&out, "", "", params);
        try proto.describe(&out, 'P', "");
        try proto.execute(&out, "", 0);
        try proto.sync(&out);
        try self.stream.writeAll(out.items);

        var rows = Rows{
            .arena = std.heap.ArenaAllocator.init(self.alloc),
            .columns = &.{},
            .rows = &.{},
            .command_tag = "",
        };
        errdefer rows.deinit();
        var rowlist = std.ArrayList([]?[]const u8).init(rows.arena.allocator());

        var got_error = false;
        while (true) {
            const f = try self.nextFrame();
            defer self.consume(f);
            switch (f.tag) {
                'T' => rows.columns = try proto.parseRowDescription(f.data, rows.arena.allocator()),
                'D' => try rowlist.append(try proto.parseDataRow(f.data, rows.arena.allocator())),
                'C' => {
                    const raw = std.mem.sliceTo(f.data, 0);
                    rows.command_tag = try rows.arena.allocator().dupe(u8, raw);
                },
                'E' => {
                    const e = proto.parseErrorFields(f.data);
                    self.setLastError(e);
                    got_error = true;
                },
                'Z' => {
                    if (got_error) return error.Remote;
                    rows.rows = try rowlist.toOwnedSlice();
                    return rows;
                },
                '1', '2', 'n', 'N', 'S', 'I' => {},
                else => return error.ProtocolViolation,
            }
        }
    }
};

test "dsn parsing" {
    const alloc = std.testing.allocator;

    var c = try parseDsn(alloc, "postgres://alice:s3cret@db.example.com:5433/jobs?sslmode=require");
    defer c.free(alloc);
    try std.testing.expectEqualStrings("db.example.com", c.host);
    try std.testing.expectEqual(@as(u16, 5433), c.port);
    try std.testing.expectEqualStrings("alice", c.user);
    try std.testing.expectEqualStrings("s3cret", c.password);
    try std.testing.expectEqualStrings("jobs", c.database);
}

test "dsn parsing with defaults" {
    const alloc = std.testing.allocator;
    var c = try parseDsn(alloc, "postgresql://127.0.0.1/bean");
    try std.testing.expectEqualStrings("127.0.0.1", c.host);
    try std.testing.expectEqual(@as(u16, 5432), c.port);
    try std.testing.expectEqualStrings("postgres", c.user);
    try std.testing.expectEqualStrings("bean", c.database);
    c.free(alloc);

    c = try parseDsn(alloc, "postgres://builder@localhost");
    try std.testing.expectEqualStrings("localhost", c.host);
    try std.testing.expectEqualStrings("postgres", c.database);
    c.free(alloc);
}

test "dsn parsing rejects malformed input" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BadDsn, parseDsn(alloc, "mysql://x/y"));
    try std.testing.expectError(error.BadDsn, parseDsn(alloc, "postgres://host:0db/x"));
    try std.testing.expectError(error.BadDsn, parseDsn(alloc, "postgres://::1/x"));
}

test "row count from command tag" {
    try std.testing.expectEqual(@as(?u64, 3), Rows.rowCountFromTag("UPDATE 3"));
    try std.testing.expectEqual(@as(?u64, 1), Rows.rowCountFromTag("INSERT 0 1"));
    try std.testing.expectEqual(@as(?u64, 7), Rows.rowCountFromTag("SELECT 7"));
    try std.testing.expect(Rows.rowCountFromTag("CREATE TABLE") == null);
}

test "frames survive partial refills and compaction" {
    const alloc = std.testing.allocator;
    var stream_buf = std.ArrayList(u8).init(alloc);
    defer stream_buf.deinit();
    try proto.simpleQuery(&stream_buf, "SELECT 1");
    try proto.simpleQuery(&stream_buf, "SELECT 2");

    var in = std.ArrayList(u8).init(alloc);
    defer in.deinit();
    var read_pos: usize = 0;

    try in.appendSlice(stream_buf.items[0..7]);
    try std.testing.expect(proto.peekFrame(in.items) == null);
    try in.appendSlice(stream_buf.items[7..]);
    const f1 = proto.peekFrame(in.items).?;
    try std.testing.expectEqualStrings("SELECT 1\x00", f1.data);
    read_pos += f1.total;
    std.mem.copyForwards(u8, in.items[0 .. in.items.len - read_pos], in.items[read_pos..]);
    in.items.len -= read_pos;
    read_pos = 0;
    const f2 = proto.peekFrame(in.items).?;
    try std.testing.expectEqualStrings("SELECT 2\x00", f2.data);
}
