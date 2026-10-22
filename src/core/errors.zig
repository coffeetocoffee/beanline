const std = @import("std");

/// How a handler failure is treated by the runtime.
pub const Class = enum {
    /// Worth trying again: the job goes back on the queue with a backoff.
    retryable,
    /// Permanent: the job dead-letters immediately, without burning the
    /// remaining attempt budget.
    dead,
};

/// The classification lists for one kind's error set.
///
/// Both lists are typed to the kind's own error set, so naming an error the
/// kind cannot return is a compile error. The two lists must partition the
/// error set exactly; `validatePartition` enforces that at compile time, so
/// "did we classify this error" is answered by the compiler rather than at
/// 3 a.m. by an exhausted attempt budget.
pub fn Policy(comptime E: type) type {
    return struct {
        /// Errors that are worth trying again.
        retryable: []const E = &.{},
        /// Errors that must dead-letter immediately.
        dead_on: []const E = &.{},
    };
}

/// True when `needle` is a member of `list`.
pub fn contains(comptime E: type, comptime list: []const E, needle: E) bool {
    for (list) |e| {
        if (e == needle) return true;
    }
    return false;
}

/// Compile-time check that `retryable` and `dead_on` partition `E` exactly:
/// every member of `E` appears in one list and only one list.
///
/// Call this from a comptime context (kind construction does it for you).
pub fn validatePartition(comptime E: type, comptime retryable: []const E, comptime dead_on: []const E) void {
    comptime {
        for (retryable) |e| {
            if (contains(E, dead_on, e)) {
                @compileError("error '" ++ @errorName(e) ++ "' is classified as both retryable and dead");
            }
        }
        for (@typeInfo(E).error_set.?) |f| {
            const e: E = @field(E, f.name);
            const in_retryable = contains(E, retryable, e);
            const in_dead = contains(E, dead_on, e);
            if (!in_retryable and !in_dead) {
                @compileError("error '" ++ f.name ++ "' is not classified: add it to .retryable or .dead_on");
            }
            if (in_retryable and in_dead) {
                @compileError("error '" ++ f.name ++ "' is classified as both retryable and dead");
            }
        }
    }
}

/// Classify one error of `E` against a kind's policy.
///
/// The comparison chain is unrolled at compile time, so this is a jump table
/// over the error set rather than a scan over a name list.
pub fn classify(comptime E: type, comptime retryable: []const E, comptime dead_on: []const E, e: E) Class {
    inline for (@typeInfo(E).error_set.?) |f| {
        const m: E = @field(E, f.name);
        if (e == m) {
            if (contains(E, dead_on, m)) return .dead;
            if (contains(E, retryable, m)) return .retryable;
            // Unreachable: validatePartition guarantees the partition. If it
            // ever is reached, retrying is the safe answer: a wrongly
            // dead-lettered job loses work, a wrongly retried one only costs
            // attempts.
            return .retryable;
        }
    }
    unreachable;
}

test "classify splits the error set" {
    const E = error{ Transient, Permanent };
    const retryable = [_]E{error.Transient};
    const dead_on = [_]E{error.Permanent};
    try std.testing.expectEqual(Class.retryable, classify(E, &retryable, &dead_on, error.Transient));
    try std.testing.expectEqual(Class.dead, classify(E, &retryable, &dead_on, error.Permanent));
}

test "policy lists are typed to the error set" {
    const E = error{Only};
    const p = Policy(E){ .retryable = &.{error.Only} };
    try std.testing.expectEqual(@as(usize, 1), p.retryable.len);
    try std.testing.expectEqual(@as(usize, 0), p.dead_on.len);
}
