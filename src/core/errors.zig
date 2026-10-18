const std = @import("std");
const backoff = @import("../runtime/backoff.zig");

pub const Class = enum { retryable, dead };

pub const RetryPolicy = struct {
    max_attempts: u8 = 25,
    backoff: backoff.Backoff = .{},
    default: Class = .retryable,
    dead_names: []const []const u8 = &.{},

    pub fn classOf(self: RetryPolicy, err_name: []const u8) Class {
        for (self.dead_names) |n| {
            if (std.mem.eql(u8, n, err_name)) return .dead;
        }
        return self.default;
    }

    pub fn isRetryable(self: RetryPolicy, err_name: []const u8) bool {
        return self.classOf(err_name) == .retryable;
    }
};

pub fn validatePartition(comptime E: type, comptime retryable: []const E, comptime dead: []const E) void {
    const info = @typeInfo(E);
    if (info != .error_set) @compileError("expected an error set, got " ++ @typeName(E));
    const fields = info.error_set orelse @compileError("anyerror cannot be classified exhaustively");
    inline for (fields) |f| {
        const e: E = @field(E, f.name);
        const in_retry = comptime indexOfE(E, retryable, e);
        const in_dead = comptime indexOfE(E, dead, e);
        if (in_retry and in_dead) @compileError("error '" ++ f.name ++ "' classified both retryable and dead");
        if (!in_retry and !in_dead) @compileError("error '" ++ f.name ++ "' not classified (must be in exactly one list)");
    }
}

fn indexOfE(comptime E: type, comptime hay: []const E, comptime needle: E) bool {
    for (hay) |e| {
        if (e == needle) return true;
    }
    return false;
}

test "classOf picks dead names" {
    const p = RetryPolicy{
        .dead_names = &.{ "AddressInvalid", "PayloadTooLarge" },
        .default = .retryable,
    };
    try std.testing.expectEqual(Class.dead, p.classOf("AddressInvalid"));
    try std.testing.expectEqual(Class.retryable, p.classOf("SmtpTransient"));
    try std.testing.expect(p.isRetryable("DnsTimeout"));
    try std.testing.expect(!p.isRetryable("PayloadTooLarge"));
}

test "default dead classification" {
    const p = RetryPolicy{ .default = .dead };
    try std.testing.expectEqual(Class.dead, p.classOf("Anything"));
}

test "partition validation passes for exhaustive split" {
    const E = error{ A, B, C };
    comptime validatePartition(E, &[_]E{ error.A, error.B }, &[_]E{error.C});
    try std.testing.expect(true);
}
