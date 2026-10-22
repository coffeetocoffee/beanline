const std = @import("std");
const errors_mod = @import("errors.zig");
const backoff_mod = @import("../runtime/backoff.zig");

/// Per-execution context handed to a handler.
pub const Context = struct {
    job_id: i64,
    lease_epoch: u64,
    attempt: u8,
    alloc: std.mem.Allocator,

    /// Set by the runtime on cancel/timeout; handlers must poll and return.
    stop_flag: ?*const std.atomic.Value(bool) = null,
    deadline_ms: i64 = 0,

    /// True once the runtime asked this execution to stop (cancel or timeout).
    /// Cooperative: infinite handlers only stop if they poll this.
    pub fn stopped(self: *const Context) bool {
        if (self.stop_flag) |f| {
            if (f.load(.seq_cst)) return true;
        }
        return self.deadline_ms != 0 and std.time.milliTimestamp() > self.deadline_ms;
    }
};

/// Why an attempt failed.
pub const Failure = struct {
    /// Whether the runtime should try the job again.
    class: errors_mod.Class,
    /// The handler's error name, for the event trail and the dead letter.
    name: []const u8,
};

/// The result of one attempt.
pub const Outcome = union(enum) {
    ok,
    failed: Failure,
};

/// A kind's fused parse-and-run entry point.
///
/// `args_json` is decoded into the kind's own argument type before the
/// handler sees it. A payload that does not fit the schema is a permanent
/// failure (`BadPayload`, always dead): retrying it can never succeed.
pub const Runner = *const fn (ctx: *Context, alloc: std.mem.Allocator, args_json: []const u8) Outcome;

/// A kind's payload-only check. Returns `error.BadPayload` when the payload
/// does not fit the kind's schema, so an enqueue endpoint can reject a job
/// the worker would never be able to run.
pub const Validator = *const fn (alloc: std.mem.Allocator, args_json: []const u8) anyerror!void;

/// A kind's payload redactor. Returns a new JSON document with the kind's
/// sensitive fields replaced by "***". Caller owns the result.
pub const Masker = *const fn (alloc: std.mem.Allocator, args_json: []const u8) anyerror![]u8;

/// A registered job kind.
///
/// `Args` is the payload type the handler receives. `E` is the exact set of
/// errors the handler may return. Both are part of the kind's type, so the
/// payload schema and the retry classification are compile-time facts rather
/// than runtime conventions.
///
/// ```zig
/// const SendArgs = struct { to: []const u8, subject: []const u8 };
/// const SendError = error{ SmtpTransient, AddressInvalid };
///
/// const send_email = beanline.Kind(SendArgs, SendError).new(.{
///     .name = "emails.send",
///     .queue = "mailers",
///     .errors = .{
///         .retryable = &.{ error.SmtpTransient },
///         .dead_on = &.{ error.AddressInvalid },
///     },
///     .handle = struct {
///         fn run(ctx: *beanline.JobContext, a: SendArgs) SendError!void {
///             _ = ctx;
///             _ = a;
///         }
///     }.run,
/// });
/// ```
pub fn Kind(comptime Args: type, comptime E: type) type {
    return struct {
        pub const ArgsType = Args;
        pub const ErrorSet = E;
        pub const Handle = *const fn (ctx: *Context, args: Args) E!void;
        pub const Errors = errors_mod.Policy(E);

        /// The declaration of a kind. Every field is a compile-time fact: the
        /// spec is evaluated at compile time, so a mistyped error name or an
        /// unclassified error fails the build.
        pub const Spec = struct {
            /// The kind name, as it appears in `job.kind`.
            name: []const u8,
            /// The queue this kind runs on by default. Used when an enqueue
            /// does not name a queue. A worker only runs jobs from the
            /// queues it is configured to poll.
            queue: []const u8 = "default",
            /// Attempts before the job dead-letters, unless the error is
            /// classified as dead (which dead-letters immediately).
            ///
            /// This is an upper bound, and so is the budget stored on the job
            /// when it was enqueued. The effective budget is the smaller of
            /// the two. The worker enforces this one even when the producer
            /// did not know the kind, so a kind that says "three strikes and
            /// dead-letter" is never given more than three attempts.
            max_attempts: u8 = 25,
            /// Cooperative per-execution deadline in ms; 0 disables.
            timeout_ms: u32 = 0,
            /// Retry backoff for this kind. `null` uses the worker's default
            /// (BEANLINE_RETRY_*).
            retry: ?backoff_mod.Backoff = null,
            /// Which of the kind's errors are worth retrying. The two lists
            /// must partition the error set exactly.
            errors: Errors = .{},
            /// Field names whose values are redacted in the dashboard and
            /// stripped from logs.
            sensitive: []const []const u8 = &.{},
            /// The handler.
            handle: Handle,
        };

        name: []const u8,
        queue: []const u8,
        max_attempts: u8,
        timeout_ms: u32,
        retry: ?backoff_mod.Backoff,
        errors: Errors,
        sensitive: []const []const u8,
        handle: Handle,

        /// The fused parse-and-run function for this kind. Built at compile
        /// time; the payload schema and the error classification are already
        /// baked in.
        runner: Runner,
        /// The payload-only check for this kind.
        validator: Validator,
        /// The payload redactor for this kind.
        masker: Masker,

        /// Build a kind.
        ///
        /// The spec must be known at compile time: the payload schema, the
        /// error classification and the handler are all part of the kind's
        /// type. The classification is checked here, so an error that nobody
        /// classified is a compile error rather than a queue that burns its
        /// whole attempt budget on a permanent failure.
        pub fn new(comptime spec: Spec) @This() {
            comptime errors_mod.validatePartition(E, spec.errors.retryable, spec.errors.dead_on);
            return .{
                .name = spec.name,
                .queue = spec.queue,
                .max_attempts = spec.max_attempts,
                .timeout_ms = spec.timeout_ms,
                .retry = spec.retry,
                .errors = spec.errors,
                .sensitive = spec.sensitive,
                .handle = spec.handle,
                .runner = makeRunner(Args, E, spec.errors.retryable, spec.errors.dead_on, spec.handle),
                .validator = makeValidator(Args),
                .masker = makeMasker(spec.sensitive),
            };
        }
    };
}

/// Build the fused parse-and-run function for one kind.
fn makeRunner(
    comptime Args: type,
    comptime E: type,
    comptime retryable: []const E,
    comptime dead_on: []const E,
    comptime handle: *const fn (ctx: *Context, args: Args) E!void,
) Runner {
    return struct {
        fn run(ctx: *Context, alloc: std.mem.Allocator, args_json: []const u8) Outcome {
            const parsed = std.json.parseFromSlice(Args, alloc, args_json, .{}) catch {
                // The payload does not fit the kind's schema. Retrying cannot
                // change that, so it is dead on the first attempt.
                return .{ .failed = .{ .class = .dead, .name = "BadPayload" } };
            };
            defer parsed.deinit();
            handle(ctx, parsed.value) catch |e| {
                return .{ .failed = .{
                    .class = errors_mod.classify(E, retryable, dead_on, e),
                    .name = @errorName(e),
                } };
            };
            return .ok;
        }
    }.run;
}

/// Build the payload-only check for one kind.
fn makeValidator(comptime Args: type) Validator {
    return struct {
        fn validate(alloc: std.mem.Allocator, args_json: []const u8) anyerror!void {
            const parsed = std.json.parseFromSlice(Args, alloc, args_json, .{}) catch {
                return error.BadPayload;
            };
            parsed.deinit();
        }
    }.validate;
}

/// Build the payload redactor for one kind.
fn makeMasker(comptime sensitive: []const []const u8) Masker {
    return struct {
        fn mask(alloc: std.mem.Allocator, args_json: []const u8) anyerror![]u8 {
            if (sensitive.len == 0) return try alloc.dupe(u8, args_json);
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch {
                // Not valid JSON: nothing to redact, pass it through so the
                // caller still sees the raw payload.
                return try alloc.dupe(u8, args_json);
            };
            defer parsed.deinit();
            if (parsed.value == .object) {
                for (sensitive) |field| {
                    if (parsed.value.object.getPtr(field)) |v| {
                        v.* = .{ .string = "***" };
                    }
                }
            }
            return std.json.stringifyAlloc(alloc, parsed.value, .{});
        }
    }.mask;
}

test "kind carries its policy and runner" {
    const Args = struct { to: []const u8, subject: []const u8 };
    const E = error{ Transient, Permanent };
    const k = Kind(Args, E).new(.{
        .name = "mail.send",
        .queue = "mailers",
        .max_attempts = 5,
        .errors = .{ .retryable = &.{error.Transient}, .dead_on = &.{error.Permanent} },
        .handle = struct {
            fn run(_: *Context, _: Args) E!void {}
        }.run,
    });
    try std.testing.expectEqualStrings("mail.send", k.name);
    try std.testing.expectEqualStrings("mailers", k.queue);
    try std.testing.expectEqual(@as(u8, 5), k.max_attempts);
}

test "runner rejects a payload that does not fit the schema" {
    const Args = struct { to: []const u8, subject: []const u8 };
    const E = error{Transient};
    const k = Kind(Args, E).new(.{
        .name = "mail.send",
        .errors = .{ .retryable = &.{error.Transient} },
        .handle = struct {
            fn run(_: *Context, _: Args) E!void {}
        }.run,
    });
    var ctx = Context{ .job_id = 1, .lease_epoch = 0, .attempt = 1, .alloc = std.testing.allocator };
    const bad = k.runner(&ctx, std.testing.allocator, "{\"to\":\"a\"}");
    try std.testing.expect(bad == .failed);
    try std.testing.expectEqual(errors_mod.Class.dead, bad.failed.class);
    try std.testing.expectEqualStrings("BadPayload", bad.failed.name);
}

test "masker redacts the sensitive fields" {
    const Args = struct { to: []const u8, subject: []const u8 };
    const E = error{};
    const k = Kind(Args, E).new(.{
        .name = "mail.send",
        .sensitive = &.{"subject"},
        .handle = struct {
            fn run(_: *Context, _: Args) E!void {}
        }.run,
    });
    const out = try k.masker(std.testing.allocator, "{\"to\":\"a\",\"subject\":\"secret\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "***") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"to\":\"a\"") != null);
}
