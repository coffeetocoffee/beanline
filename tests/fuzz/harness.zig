const std = @import("std");

/// Shared driver for the deterministic fuzz targets. Zig's built-in fuzzing
/// (`std.testing.fuzz`) is still unstable, so each target exposes
/// `fuzzOneInput` and this harness drives it with a seeded PRNG. That keeps the
/// gate reproducible in CI while exercising the same code paths a coverage
/// fuzzer would.
pub const Corpus = struct {
    seed: u64,
    max_len: usize,

    pub fn init(seed: u64, max_len: usize) Corpus {
        return .{ .seed = seed, .max_len = max_len };
    }
};

pub const Report = struct {
    iterations: u64 = 0,
    interesting: u64 = 0,
    /// Inputs that were accepted by the parser (not an error).
    accepted: u64 = 0,
};

pub const TargetFn = *const fn (ctx: *const std.mem.Allocator, data: []const u8) anyerror!void;

/// Run `target` over pseudo-random inputs. A crash (panic) fails the gate; a
/// returned error is a normal outcome for a parser under fuzz. The summary is
/// printed to stdout so CI logs record the coverage the gate got.
pub fn drive(ctx: *const std.mem.Allocator, target: TargetFn, corpus: Corpus, iterations: u64, report: *Report) !void {
    var prng = std.Random.Xoshiro256.init(corpus.seed);
    var buf: [4096]u8 = undefined;

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        // Vary the shape: sometimes tiny, sometimes full length, sometimes a
        // biased alphabet of protocol-significant bytes.
        const len = switch (prng.random().uintLessThan(u8, 4)) {
            0 => prng.random().uintLessThan(usize, 8) + 1,
            1 => prng.random().uintLessThan(usize, 64) + 1,
            2 => prng.random().uintLessThan(usize, 512) + 1,
            else => prng.random().uintLessThan(usize, corpus.max_len) + 1,
        };
        const biased = prng.random().uintLessThan(u8, 2) == 0;
        const alphabet = if (biased) "0123456789\r\n$*+-:.,{}[]\"\\ abcXYZ" else "abcdefghijklmnopqrstuvwxyz0123456789";
        var n: usize = 0;
        while (n < len) : (n += 1) {
            buf[n] = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
        }

        report.iterations += 1;
        target(ctx, buf[0..len]) catch {
            report.interesting += 1;
            continue;
        };
        report.accepted += 1;
    }
    // No printing here: the test runner uses stdout for its IPC handshake, so
    // a target that writes to stdout would corrupt the protocol. Callers print
    // the report themselves.
}

/// Parse `--iterations N` and `--seed N` from argv.
pub const Options = struct {
    iterations: u64 = 50_000,
    seed: u64 = 0xc0ffee,
    max_len: usize = 4096,
};

pub fn options(argv: [][:0]u8) Options {
    var o = Options{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--iterations") and i + 1 < argv.len) {
            i += 1;
            o.iterations = std.fmt.parseInt(u64, argv[i], 10) catch o.iterations;
        } else if (std.mem.eql(u8, argv[i], "--seed") and i + 1 < argv.len) {
            i += 1;
            o.seed = std.fmt.parseInt(u64, argv[i], 10) catch o.seed;
        } else if (std.mem.eql(u8, argv[i], "--max-len") and i + 1 < argv.len) {
            i += 1;
            o.max_len = std.fmt.parseInt(usize, argv[i], 10) catch o.max_len;
        }
    }
    return o;
}

test "harness reports the requested iteration count" {
    var report = Report{};
    const Ctx = struct {
        fn t(_: *const std.mem.Allocator, data: []const u8) anyerror!void {
            if (data.len % 2 == 0) return error.Whatever;
        }
    };
    const a = std.heap.page_allocator;
    try drive(&a, Ctx.t, Corpus.init(1, 64), 25, &report);
    try std.testing.expectEqual(@as(u64, 25), report.iterations);
    try std.testing.expectEqual(@as(u64, 25), report.accepted + report.interesting);
}
