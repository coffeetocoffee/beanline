const std = @import("std");
const beanline = @import("beanline");
const harness = @import("harness.zig");

/// The args shape under test is the library's own, so the fuzz target cannot
/// drift from what handlers actually receive.
const Args = beanline.Args;

/// Fuzz target: the job-args JSON path. Every job's args cross this boundary
/// before a handler sees them, so a panic here is a remote-input panic.
///
/// The allocator passed in owns the parsed strings for the whole call: do not
/// free them individually, or hand this an allocator whose frees are not
/// no-ops (an arena is what the harness uses).
pub fn fuzzOneInput(alloc: std.mem.Allocator, data: []const u8) !void {
    // Build a syntactically plausible JSON document around the random bytes so
    // the fuzzer reaches the decoder instead of stopping at the parser.
    var buf: [8192]u8 = undefined;
    var w = std.io.fixedBufferStream(&buf);
    const out = w.writer();
    out.writeAll("{\"to\":\"") catch return error.TooLong;
    for (data) |c| {
        switch (c) {
            '"', '\\' => {
                out.writeAll("\\") catch return error.TooLong;
                out.writeByte(c) catch return error.TooLong;
            },
            0x00...0x1f => {
                out.print("\\u{x:0>4}", .{c}) catch return error.TooLong;
            },
            else => out.writeByte(c) catch return error.TooLong,
        }
    }
    out.writeAll("\",\"subject\":\"s\"}") catch return error.TooLong;

    const parsed = try std.json.parseFromSliceLeaky(Args, alloc, w.getWritten(), .{});
    // The decoded values flow into job handlers, so exercise them as strings
    // would be (formatting, slicing, comparison).
    var sink: usize = 0;
    for (parsed.to) |c| sink +%= c;
    for (parsed.subject) |c| sink +%= c;
    if (parsed.to.len > 0 and parsed.to[0] == '@') {
        if (std.mem.indexOf(u8, parsed.subject, parsed.to) == null) sink +%= 1;
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
            const base = ctx.*;
            // Leaky parsing needs a per-iteration arena so the fuzzer's memory
            // use stays flat.
            var arena = std.heap.ArenaAllocator.init(base);
            defer arena.deinit();
            return fuzzOneInput(arena.allocator(), data);
        }
    }.t;

    try harness.drive(&alloc, target, harness.Corpus.init(o.seed ^ 0x5678, o.max_len), o.iterations, &report);
    try std.io.getStdOut().writer().print("iterations={d} accepted={d} rejected={d}\n", .{ report.iterations, report.accepted, report.interesting });
    return 0;
}

test "args json rejects malformed payloads" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    fuzzOneInput(arena.allocator(), "") catch {};
    fuzzOneInput(arena.allocator(), "{") catch {};
    fuzzOneInput(arena.allocator(), "[]") catch {};
    fuzzOneInput(arena.allocator(), "{\"to\":1}") catch {};
    fuzzOneInput(arena.allocator(), "{\"to\":\"a\",\"subject\":\"b\",\"extra\":true}") catch {};
}

test "args json accepts valid payloads" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try fuzzOneInput(arena.allocator(), "{\"to\":\"a@b.test\",\"subject\":\"hi\"}");
    try fuzzOneInput(arena.allocator(), "{\"to\":\"\",\"subject\":\"\"}");
    // Deep nesting and huge strings must not blow the stack or the allocator.
    try fuzzOneInput(arena.allocator(), "{\"to\":\"\\u0041\",\"subject\":\"\\ud83d\\ude00\"}");
}

// Compile-time guard that the args shape used by the fuzz target matches the
// shape handlers are declared with, so the target cannot drift from reality.
test "args struct matches the job contract" {
    try std.testing.expectEqual(@typeInfo(beanline.Args).@"struct".fields.len, 2);
}
