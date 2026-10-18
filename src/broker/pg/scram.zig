const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const pbkdf2 = std.crypto.pwhash.pbkdf2;
const b64 = std.base64.standard;

pub const ClientFirst = struct {
    full: []const u8,
    bare: []const u8,
};

pub fn buildClientFirst(username: []const u8, nonce: []const u8, buf: *[512]u8) ClientFirst {
    const bare = std.fmt.bufPrint(buf[3..], "n={s},r={s}", .{ username, nonce }) catch unreachable;
    @memcpy(buf[0..3], "n,,");
    return .{ .full = buf[0 .. 3 + bare.len], .bare = bare };
}

pub const ServerFirst = struct {
    full_nonce: []const u8,
    salt: []const u8,
    iterations: u32,
};

pub fn parseServerFirst(data: []const u8) !ServerFirst {
    var full_nonce: []const u8 = "";
    var salt: []const u8 = "";
    var iterations: u32 = 0;
    var it = std.mem.splitScalar(u8, data, ',');
    while (it.next()) |part| {
        if (part.len < 2 or part[1] != '=') continue;
        const val = part[2..];
        if (part[0] == 'r') {
            full_nonce = val;
        } else if (part[0] == 's') {
            salt = val;
        } else if (part[0] == 'i') {
            iterations = std.fmt.parseInt(u32, val, 10) catch return error.BadScramMessage;
        }
    }
    if (full_nonce.len == 0 or salt.len == 0 or iterations == 0) return error.BadScramMessage;
    return .{ .full_nonce = full_nonce, .salt = salt, .iterations = iterations };
}

pub const ClientFinal = struct {
    without_proof: [512]u8 = undefined,
    without_proof_len: usize = 0,
    msg: [563]u8 = undefined,
    msg_len: usize = 0,
    proof: [44]u8 = undefined,
    server_sig: [44]u8 = undefined,

    pub fn withoutProof(self: *const ClientFinal) []const u8 {
        return self.without_proof[0..self.without_proof_len];
    }

    pub fn fullMessage(self: *const ClientFinal) []const u8 {
        return self.msg[0..self.msg_len];
    }
};

pub fn computeFinal(
    password: []const u8,
    client_nonce: []const u8,
    client_bare: []const u8,
    server_first: []const u8,
) !ClientFinal {
    var out = ClientFinal{};
    const sf = try parseServerFirst(server_first);
    if (!std.mem.startsWith(u8, sf.full_nonce, client_nonce)) return error.BadScramMessage;
    const without = std.fmt.bufPrint(&out.without_proof, "c=biws,r={s}", .{sf.full_nonce}) catch unreachable;
    out.without_proof_len = without.len;

    var salt_buf: [64]u8 = undefined;
    const salt_len = b64.Decoder.calcSizeForSlice(sf.salt) catch return error.BadScramMessage;
    if (salt_len > salt_buf.len) return error.BadScramMessage;
    try b64.Decoder.decode(salt_buf[0..salt_len], sf.salt);

    var salted: [32]u8 = undefined;
    try pbkdf2(&salted, password, salt_buf[0..salt_len], sf.iterations, HmacSha256);

    var client_key: [32]u8 = undefined;
    HmacSha256.create(&client_key, "Client Key", &salted);
    var stored_key: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});

    var auth_buf: [1024]u8 = undefined;
    const auth_len = blk: {
        var fbs = std.io.fixedBufferStream(&auth_buf);
        const w = fbs.writer();
        w.writeAll(client_bare) catch unreachable;
        w.writeAll(",") catch unreachable;
        w.writeAll(server_first) catch unreachable;
        w.writeAll(",") catch unreachable;
        w.writeAll(without) catch unreachable;
        break :blk fbs.pos;
    };

    var client_sig: [32]u8 = undefined;
    HmacSha256.create(&client_sig, auth_buf[0..auth_len], &stored_key);
    var proof: [32]u8 = undefined;
    for (&proof, client_key, client_sig) |*p, ck, cs| {
        p.* = ck ^ cs;
    }

    const proof_len = b64.Encoder.calcSize(proof.len);
    _ = b64.Encoder.encode(out.proof[0..proof_len], &proof);
    @memset(out.proof[proof_len..], 0);
    @memcpy(out.msg[0..without.len], without);
    @memcpy(out.msg[without.len .. without.len + 3], ",p=");
    @memcpy(out.msg[without.len + 3 .. without.len + 3 + proof_len], out.proof[0..proof_len]);
    out.msg_len = without.len + 3 + proof_len;

    var server_key: [32]u8 = undefined;
    HmacSha256.create(&server_key, "Server Key", &salted);
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, auth_buf[0..auth_len], &server_key);
    const sig_len = b64.Encoder.calcSize(sig.len);
    _ = b64.Encoder.encode(out.server_sig[0..sig_len], &sig);
    @memset(out.server_sig[sig_len..], 0);

    return out;
}

test "client first message" {
    var buf: [512]u8 = undefined;
    const cf = buildClientFirst("user", "abc123", &buf);
    const bs: []const u8 = &buf;
    try std.testing.expectEqualStrings("n,,n=user,r=abc123", cf.full);
    try std.testing.expectEqualStrings("n=user,r=abc123", cf.bare);
    try std.testing.expect(cf.full.ptr == bs.ptr);
    try std.testing.expect(cf.bare.ptr == bs.ptr + 3);
}

test "rfc 7677 scram sha 256 vector" {
    const client_nonce = "rOprNGfwEbeRWgbNEkqO";
    const full_nonce = "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
    const server_first = "r=" ++ full_nonce ++ ",s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const client_bare = "n=user,r=" ++ client_nonce;

    const sf = try parseServerFirst(server_first);
    try std.testing.expectEqualStrings(full_nonce, sf.full_nonce);
    try std.testing.expectEqualStrings("W22ZaJ0SNY7soEsUEjb6gQ==", sf.salt);
    try std.testing.expectEqual(@as(u32, 4096), sf.iterations);

    const fin = try computeFinal("pencil", client_nonce, client_bare, server_first);
    try std.testing.expectEqualStrings(
        "c=biws,r=" ++ full_nonce,
        fin.withoutProof(),
    );
    try std.testing.expectEqualStrings(
        "c=biws,r=" ++ full_nonce ++ ",p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        fin.fullMessage(),
    );
    try std.testing.expectEqualStrings(
        "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        fin.proof[0..44],
    );
    try std.testing.expectEqualStrings(
        "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
        fin.server_sig[0..44],
    );
}

test "bad server first rejected" {
    try std.testing.expectError(error.BadScramMessage, parseServerFirst("r=onlynonce"));
    try std.testing.expectError(error.BadScramMessage, parseServerFirst("x=1,y=2,z=3"));
}

test "nonce mismatch rejected" {
    var buf: [512]u8 = undefined;
    const cf = buildClientFirst("user", "client123", &buf);
    const server_first = "r=OTHER%ext,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    try std.testing.expectError(error.BadScramMessage, computeFinal("pw", "client123", cf.bare, server_first));
}
