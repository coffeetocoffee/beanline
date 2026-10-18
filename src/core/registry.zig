const std = @import("std");
const job = @import("job.zig");

pub const RegisterError = error{DuplicateKind} || std.mem.Allocator.Error;

pub const Registry = struct {
    map: std.StringHashMap(job.Job),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .map = std.StringHashMap(job.Job).init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.map.deinit();
    }

    pub fn register(self: *Registry, j: job.Job) RegisterError!void {
        if (self.map.contains(j.name)) return error.DuplicateKind;
        try self.map.put(j.name, j);
    }

    pub fn get(self: *const Registry, name: []const u8) ?job.Job {
        return self.map.get(name);
    }

    pub fn count(self: *const Registry) usize {
        return self.map.count();
    }
};

test "register and lookup" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();

    const j = job.Job{
        .name = "emails.send",
        .handle = struct {
            fn run(ctx: *job.Context, args: job.Args) anyerror!void {
                _ = ctx;
                _ = args;
            }
        }.run,
    };
    try r.register(j);
    try std.testing.expect(r.get("emails.send") != null);
    try std.testing.expect(r.get("emails.other") == null);
    try std.testing.expectEqual(@as(usize, 1), r.count());
}

test "duplicate kind rejected" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const j = job.Job{
        .name = "dup",
        .handle = struct {
            fn run(ctx: *job.Context, args: job.Args) anyerror!void {
                _ = ctx;
                _ = args;
            }
        }.run,
    };
    try r.register(j);
    try std.testing.expectError(error.DuplicateKind, r.register(j));
}
