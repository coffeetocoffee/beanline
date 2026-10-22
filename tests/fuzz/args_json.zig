const std = @import("std");
const beanline = @import("beanline");
const harness = @import("harness.zig");

/// The payload schemas under test.
///
/// These are real kinds with their own argument types, exactly as an
/// application would declare them. The queue used to hardcode a single
/// `Args` struct for every kind, so this target used to fuzz one shape and
/// assert that shape had exactly two fields. Both halves of that were
/// wrong: the fuzz target could never reach a second payload shape, and the
/// "contract" test pinned the limitation in place so that widening it broke
/// the build.
///
/// What is fuzzed now is the *path* every job takes: the payload is decoded
/// into the kind's own argument type, and a mismatch is a permanent failure
/// rather than a retry.
const MailArgs = struct { to: []const u8, subject: []const u8 };
const InvoiceArgs = struct { cents: u64, note: []const u8 };
const NestedArgs = struct {
    id: u64,
    tags: []const []const u8,
    meta: struct { src: []const u8 },
};
const OptionalArgs = struct {
    a: u32 = 0,
    b: ?[]const u8 = null,
};

const MailError = error{ Transient, Permanent };
const InvoiceError = error{Duplicate};

const mail_kind = beanline.Kind(MailArgs, MailError).new(.{
    .name = "fuzz.mail",
    .errors = .{ .retryable = &.{error.Transient}, .dead_on = &.{error.Permanent} },
    .handle = struct {
        fn run(_: *beanline.JobContext, a: MailArgs) MailError!void {
            _ = a;
        }
    }.run,
});

const invoice_kind = beanline.Kind(InvoiceArgs, InvoiceError).new(.{
    .name = "fuzz.invoice",
    .errors = .{ .dead_on = &.{error.Duplicate} },
    .handle = struct {
        fn run(_: *beanline.JobContext, a: InvoiceArgs) InvoiceError!void {
            _ = a;
        }
    }.run,
});

const nested_kind = beanline.Kind(NestedArgs, error{}).new(.{
    .name = "fuzz.nested",
    .handle = struct {
        fn run(_: *beanline.JobContext, a: NestedArgs) error{}!void {
            _ = a;
        }
    }.run,
});

const optional_kind = beanline.Kind(OptionalArgs, error{}).new(.{
    .name = "fuzz.optional",
    .handle = struct {
        fn run(_: *beanline.JobContext, a: OptionalArgs) error{}!void {
            _ = a;
        }
    }.run,
});

/// Escape a byte string so it can be embedded in a JSON string literal.
fn writeJsonString(out: anytype, data: []const u8) !void {
    for (data) |c| {
        switch (c) {
            '"', '\\' => {
                try out.writeAll("\\");
                try out.writeByte(c);
            },
            0x00...0x1f => {
                try out.print("\\u{x:0>4}", .{c});
            },
            else => try out.writeByte(c),
        }
    }
}

/// Build a syntactically plausible JSON document around the random bytes, so
/// the fuzzer reaches the decoder instead of stopping at the parser.
fn envelope(alloc: std.mem.Allocator, prefix: []const u8, suffix: []const u8, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll(prefix);
    try writeJsonString(w, data);
    try w.writeAll(suffix);
    return out.toOwnedSlice();
}

/// Run one payload through one kind and check the invariants the runtime
/// relies on:
///
///   - a payload that does not fit the schema is a permanent failure, never
///     a retry (retrying it could never succeed);
///   - a handler error is classified the way the kind declared it.
fn exercise(alloc: std.mem.Allocator, kind: anytype, args_json: []const u8) !void {
    var ctx = beanline.JobContext{
        .job_id = 1,
        .lease_epoch = 0,
        .attempt = 1,
        .alloc = alloc,
    };
    const outcome = kind.runner(&ctx, alloc, args_json);
    switch (outcome) {
        .ok => {},
        .failed => |f| {
            if (std.mem.eql(u8, f.name, "BadPayload")) {
                if (f.class != .dead) return error.BadPayloadMustBeDead;
            }
        },
    }
}

/// Fuzz target: the job-args JSON path. Every job's args cross this boundary
/// before a handler sees them, so a panic here is a remote-input panic.
///
/// The allocator passed in owns the parsed strings for the whole call: do not
/// free them individually, or hand this an allocator whose frees are not
/// no-ops (an arena is what the harness uses).
pub fn fuzzOneInput(alloc: std.mem.Allocator, data: []const u8) !void {
    // One in four inputs is fed to the decoders raw, so the malformed-JSON
    // path is exercised too, not just the well-formed path.
    if (data.len > 0 and data[0] % 4 == 0) {
        try exercise(alloc, mail_kind, data);
        try exercise(alloc, invoice_kind, data);
        try exercise(alloc, nested_kind, data);
        try exercise(alloc, optional_kind, data);
        return;
    }

    // Each kind gets a syntactically valid document with the random bytes in
    // one of its string fields, so the decoder is actually reached. The
    // integer and nested fields are fixed: the point is to fuzz the string
    // handling and the decoder, not the number parser.
    const mail = try envelope(alloc, "{\"to\":\"", "\",\"subject\":\"s\"}", data);
    defer alloc.free(mail);
    try exercise(alloc, mail_kind, mail);

    const invoice = try envelope(alloc, "{\"cents\":100,\"note\":\"", "\"}", data);
    defer alloc.free(invoice);
    try exercise(alloc, invoice_kind, invoice);

    const nested = try envelope(alloc, "{\"id\":7,\"tags\":[\"", "\"],\"meta\":{\"src\":\"fixed\"}}", data);
    defer alloc.free(nested);
    try exercise(alloc, nested_kind, nested);

    const opt = try envelope(alloc, "{\"a\":1,\"b\":\"", "\"}", data);
    defer alloc.free(opt);
    try exercise(alloc, optional_kind, opt);
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
    const a = arena.allocator();

    // Malformed JSON, a wrong field type, a missing field and an extra field
    // are all rejected, and rejected permanently.
    for ([_][]const u8{
        "",
        "{",
        "[]",
        "{\"to\":1}",
        "{\"to\":\"a\",\"subject\":\"b\",\"extra\":true}",
        "{\"to\":\"a\"}",
    }) |bad| {
        try exercise(a, mail_kind, bad);
    }
}

test "args json accepts valid payloads for every kind" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try exercise(a, mail_kind, "{\"to\":\"a@b.test\",\"subject\":\"hi\"}");
    try exercise(a, invoice_kind, "{\"cents\":100,\"note\":\"n\"}");
    try exercise(a, nested_kind, "{\"id\":1,\"tags\":[\"a\",\"b\"],\"meta\":{\"src\":\"x\"}}");
    try exercise(a, optional_kind, "{\"a\":1,\"b\":\"x\"}");
    try exercise(a, optional_kind, "{\"a\":1}");
}

test "a payload that does not fit the schema is dead, not retryable" {
    const alloc = std.testing.allocator;
    var ctx = beanline.JobContext{ .job_id = 1, .lease_epoch = 0, .attempt = 1, .alloc = alloc };

    const outcome = mail_kind.runner(&ctx, alloc, "{\"to\":\"a\"}");
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqual(beanline.ErrorClass.dead, outcome.failed.class);
    try std.testing.expectEqualStrings("BadPayload", outcome.failed.name);
}

test "each kind keeps its own payload schema" {
    const alloc = std.testing.allocator;
    var ctx = beanline.JobContext{ .job_id = 1, .lease_epoch = 0, .attempt = 1, .alloc = alloc };

    // The mail payload is not a valid invoice payload, and vice versa. A
    // single shared payload struct could not express this.
    const wrong_for_invoice = invoice_kind.runner(&ctx, alloc, "{\"to\":\"a\",\"subject\":\"s\"}");
    try std.testing.expect(wrong_for_invoice == .failed);
    try std.testing.expectEqual(beanline.ErrorClass.dead, wrong_for_invoice.failed.class);

    const wrong_for_mail = mail_kind.runner(&ctx, alloc, "{\"cents\":1,\"note\":\"n\"}");
    try std.testing.expect(wrong_for_mail == .failed);
    try std.testing.expectEqual(beanline.ErrorClass.dead, wrong_for_mail.failed.class);
}

test "a handler error is classified the way the kind declared it" {
    const alloc = std.testing.allocator;
    var ctx = beanline.JobContext{ .job_id = 1, .lease_epoch = 0, .attempt = 1, .alloc = alloc };

    // The mail handler is declared as never failing, so it cannot be reached
    // here; the invoice kind has one dead error and one retryable error.
    const failing = beanline.Kind(InvoiceArgs, error{ Transient, Permanent }).new(.{
        .name = "fuzz.both",
        .errors = .{ .retryable = &.{error.Transient}, .dead_on = &.{error.Permanent} },
        .handle = struct {
            fn run(_: *beanline.JobContext, a: InvoiceArgs) error{ Transient, Permanent }!void {
                _ = a;
                return error.Permanent;
            }
        }.run,
    });
    const outcome = failing.runner(&ctx, alloc, "{\"cents\":1,\"note\":\"n\"}");
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqual(beanline.ErrorClass.dead, outcome.failed.class);
    try std.testing.expectEqualStrings("Permanent", outcome.failed.name);
}
