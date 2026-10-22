const std = @import("std");
const job = @import("job.zig");
const backoff_mod = @import("../runtime/backoff.zig");

pub const RegisterError = error{DuplicateKind} || std.mem.Allocator.Error;

/// A registered kind, resolved into the shape the runtime needs.
///
/// The payload schema and the error classification are already baked into
/// `runner`: the runtime never parses a payload itself and never matches an
/// error name against a list.
pub const Entry = struct {
    /// The kind name, as it appears in `job.kind`.
    name: []const u8,
    /// The queue this kind runs on by default.
    queue: []const u8,
    /// Attempts before the job dead-letters, unless the error is classified
    /// as dead (which dead-letters immediately).
    max_attempts: u8,
    /// Cooperative per-execution deadline in ms; 0 disables.
    timeout_ms: u32,
    /// Retry backoff for this kind. `null` means "use the worker's default".
    retry: ?backoff_mod.Backoff,
    /// Fused parse-and-run for this kind.
    runner: job.Runner,
    /// Payload-only check, for rejecting an enqueue the worker could never run.
    validator: job.Validator,
    /// Payload redactor, for the dashboard and the logs.
    masker: job.Masker,
};

/// Resolve a kind into its type-erased registry entry.
pub fn entryFor(comptime KindType: type, k: KindType) Entry {
    return .{
        .name = k.name,
        .queue = k.queue,
        .max_attempts = k.max_attempts,
        .timeout_ms = k.timeout_ms,
        .retry = k.retry,
        .runner = k.runner,
        .validator = k.validator,
        .masker = k.masker,
    };
}

pub const Registry = struct {
    map: std.StringHashMap(Entry),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .map = std.StringHashMap(Entry).init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.map.deinit();
    }

    pub fn register(self: *Registry, e: Entry) RegisterError!void {
        if (self.map.contains(e.name)) return error.DuplicateKind;
        try self.map.put(e.name, e);
    }

    pub fn get(self: *const Registry, name: []const u8) ?Entry {
        return self.map.get(name);
    }

    pub fn count(self: *const Registry) usize {
        return self.map.count();
    }
};

test "register and lookup" {
    const Args = struct { to: []const u8 };
    const E = error{};
    const k = job.Kind(Args, E).new(.{
        .name = "emails.send",
        .handle = struct {
            fn run(_: *job.Context, _: Args) E!void {}
        }.run,
    });

    var r = Registry.init(std.testing.allocator);
    defer r.deinit();

    try r.register(entryFor(@TypeOf(k), k));
    try std.testing.expect(r.get("emails.send") != null);
    try std.testing.expect(r.get("emails.other") == null);
    try std.testing.expectEqual(@as(usize, 1), r.count());
    try std.testing.expectEqualStrings("emails.send", r.get("emails.send").?.name);
}

test "duplicate kind rejected" {
    const Args = struct { to: []const u8 };
    const E = error{};
    const k = job.Kind(Args, E).new(.{
        .name = "dup",
        .handle = struct {
            fn run(_: *job.Context, _: Args) E!void {}
        }.run,
    });

    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    try r.register(entryFor(@TypeOf(k), k));
    try std.testing.expectError(error.DuplicateKind, r.register(entryFor(@TypeOf(k), k)));
}
