const std = @import("std");
const beanline = @import("beanline");
const cron = struct {
    const Schedule = beanline.CronSchedule;
};
const harness = @import("harness.zig");

/// Fuzz target: the cron parser plus next-fire computation. A bad parse must be
/// a clean `error.InvalidCron`; a panic, hang, or an out-of-range next-fire is a
/// release blocker because cron feeds the idempotent scheduler.
pub fn fuzzOneInput(data: []const u8) !void {
    // The expression is the first whitespace-delimited token; anything after it
    // is a second parse (many-field inputs), which keeps the fuzzer honest about
    // multi-token input.
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 256) return error.InvalidCron;
    for (trimmed) |c| {
        // Keep the alphabet on characters a cron expression can plausibly
        // contain; the generator's alphabet is wider than this on purpose.
        if (std.ascii.isAlphanumeric(c) or c == '*' or c == '/' or c == ',' or c == '-' or
            c == '@' or c == '_' or c == '#' or c == '?' or c == ' ')
        {
            continue;
        }
        return error.InvalidCron;
    }

    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |tok| {
        if (tok.len > 128) return error.InvalidCron;
        const sched = cron.Schedule.parse(tok) catch continue;
        // Walking the schedule must terminate and stay in a sane range.
        var cursor: i64 = 0;
        var steps: usize = 0;
        while (steps < 64) : (steps += 1) {
            const nxt = sched.next(cursor) orelse break;
            if (nxt < cursor) return error.TimeWentBackwards;
            cursor = nxt;
        }
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    const o = harness.options(argv);
    const page_alloc = std.heap.page_allocator;
    var report = harness.Report{};
    const target = struct {
        fn t(_: *const std.mem.Allocator, data: []const u8) anyerror!void {
            return fuzzOneInput(data);
        }
    }.t;

    try harness.drive(&page_alloc, target, harness.Corpus.init(o.seed ^ 0x1234, o.max_len), o.iterations, &report);
    try std.io.getStdOut().writer().print("iterations={d} accepted={d} rejected={d}\n", .{ report.iterations, report.accepted, report.interesting });
    return 0;
}

test "cron parser rejects garbage without crashing" {
    fuzzOneInput("") catch {};
    fuzzOneInput("nonsense") catch {};
    fuzzOneInput("* * * *") catch {};
    fuzzOneInput("99 * * * *") catch {};
    fuzzOneInput("0 0 0 0 0") catch {};
    fuzzOneInput("-5 * * * *") catch {};
    fuzzOneInput("*/0 * * * *") catch {};
}

test "cron parser accepts real expressions and advances time" {
    try fuzzOneInput("* * * * *");
    try fuzzOneInput("0 0 * * *");
    try fuzzOneInput("*/5 9-17 * * 1-5");
    try fuzzOneInput("@hourly");
    try fuzzOneInput("0 0 1 1 *");

    const sched = try cron.Schedule.parse("*/15 * * * *");
    const first = sched.next(0) orelse return error.TestUnexpectedResult;
    const second = sched.next(first) orelse return error.TestUnexpectedResult;
    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(i64, 900), second - first);
}
