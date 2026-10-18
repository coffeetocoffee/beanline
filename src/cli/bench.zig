const std = @import("std");
const broker_mod = @import("../broker/broker.zig");

/// Workload shapes from the architecture doc's Ã‚Â§19 benchmark table.
pub const Workload = enum {
    noop, // pure broker round trip
    io, // 20 ms sleep, models DB/HTTP bound handlers
    cpu, // ~10 ms of arithmetic, models CPU bound handlers
    flaky, // 10% transient failures, exercises retry and backoff
    poison, // 1% permanent failures, exercises the dead path

    pub fn parse(s: []const u8) ?Workload {
        const map = [_]struct { []const u8, Workload }{
            .{ "noop", .noop },
            .{ "io", .io },
            .{ "io-bound", .io },
            .{ "cpu", .cpu },
            .{ "flaky", .flaky },
            .{ "poison", .poison },
        };
        for (map) |e| {
            if (std.mem.eql(u8, e[0], s)) return e[1];
        }
        return null;
    }

    pub fn kindName(self: Workload) []const u8 {
        return switch (self) {
            .noop => "bench.noop",
            .io => "bench.io",
            .cpu => "bench.cpu",
            .flaky => "bench.flaky",
            .poison => "bench.poison",
        };
    }
};

pub const Options = struct {
    workload: Workload = .noop,
    /// 0 means "whatever BEANLINE_* is configured"; otherwise a literal name
    /// used for the reference file and the report label.
    backend_label: []const u8 = "configured",
    /// Number of producer threads (set from workers at run time).
    producers: u16 = 1,
    duration_ms: i64 = 120_000,
    warmup_ms: i64 = 5_000,
    workers: u16 = 4,
    queues: u8 = 1,
    payload_bytes: u16 = 1024,
    /// Target enqueue rate per second across all producers; 0 = unthrottled.
    rate: u32 = 0,
    lease_ms: u64 = 30_000,
    claim_batch: u32 = 4,
    seed: u64 = 0x5eed,
    report_path: ?[]const u8 = null,
    reference_dir: []const u8 = "bench/reference",
    /// Compare against the stored reference and fail on a p99 regression.
    gate: bool = false,
    gate_pct: f64 = 5.0,
    /// Print the plan and exit without touching a broker.
    dry_run: bool = false,
    json: bool = false,
};

pub const usage =
    \\beanline bench - workload generator and benchmark gate
    \\
    \\usage: beanline bench [options]
    \\  --workload <noop|io|cpu|flaky|poison>  workload shape (default noop)
    \\  --backend <label>                       label for report/reference (default: configured backend)
    \\  --duration <seconds>                    measurement window (default 120)
    \\  --warmup <seconds>                      warmup before measuring (default 5)
    \\  --workers <n>                           worker threads (default 4)
    \\  --queues <n>                            number of queues (default 1)
    \\  --payload <bytes>                       args payload size (default 1024)
    \\  --rate <n>                              enqueue rate per second, 0 = unthrottled
    \\  --lease-ms <n>                          lease duration (default 30000)
    \\  --claim-batch <n>                       claim batch size (default 4)
    \\  --seed <n>                              PRNG seed for reproducible failure injection
    \\  --report <path>                         write a JSON report
    \\  --reference-dir <path>                  reference directory (default bench/reference)
    \\  --gate                                  compare against the reference, fail on >5% p99 regression
    \\  --gate-pct <pct>                        regression budget (default 5)
    \\  --json                                  print the report as JSON
    \\  --dry-run                               print the plan and exit
    \\
;

/// Fetch the value that follows a flag, advancing the cursor.
fn argNext(args: []const []const u8, idx: *usize) ![]const u8 {
    if (idx.* + 1 >= args.len) return error.MissingValue;
    idx.* += 1;
    return args[idx.*];
}

/// Parse bench arguments (argv[0] is the program name, argv[1] "bench").
pub fn parseArgs(argv: []const []const u8) !Options {
    var o = Options{};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        if (std.mem.eql(u8, a, "--workload")) {
            const v = try argNext(argv, &i);
            o.workload = Workload.parse(v) orelse return error.BadWorkload;
        } else if (std.mem.eql(u8, a, "--backend")) {
            o.backend_label = try argNext(argv, &i);
        } else if (std.mem.eql(u8, a, "--duration")) {
            o.duration_ms = (try std.fmt.parseInt(i64, try argNext(argv, &i), 10)) * 1000;
        } else if (std.mem.eql(u8, a, "--warmup")) {
            o.warmup_ms = (try std.fmt.parseInt(i64, try argNext(argv, &i), 10)) * 1000;
        } else if (std.mem.eql(u8, a, "--workers")) {
            o.workers = try std.fmt.parseInt(u16, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--queues")) {
            o.queues = try std.fmt.parseInt(u8, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--payload")) {
            o.payload_bytes = try std.fmt.parseInt(u16, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--rate")) {
            o.rate = try std.fmt.parseInt(u32, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--lease-ms")) {
            o.lease_ms = try std.fmt.parseInt(u64, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--claim-batch")) {
            o.claim_batch = try std.fmt.parseInt(u32, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            o.seed = try std.fmt.parseInt(u64, try argNext(argv, &i), 10);
        } else if (std.mem.eql(u8, a, "--report")) {
            o.report_path = try argNext(argv, &i);
        } else if (std.mem.eql(u8, a, "--reference-dir")) {
            o.reference_dir = try argNext(argv, &i);
        } else if (std.mem.eql(u8, a, "--gate")) {
            o.gate = true;
        } else if (std.mem.eql(u8, a, "--gate-pct")) {
            o.gate_pct = try std.fmt.parseFloat(f64, try argNext(argv, &i));
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            o.dry_run = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            o.dry_run = true;
        } else {
            return error.UnknownFlag;
        }
    }
    if (o.queues == 0) return error.BadQueues;
    if (o.workers == 0) return error.BadWorkers;
    if (o.duration_ms <= 0) return error.BadDuration;
    return o;
}

/// Latency samples in microseconds. Samples are collected per thread and
/// merged at the end; the reservoir cap keeps memory bounded on long runs.
pub const Samples = struct {
    buf: std.ArrayListUnmanaged(u32) = .{},
    seen: u64 = 0,
    cap: usize = 1_000_000,
    rng: std.Random.Xoshiro256 = std.Random.Xoshiro256.init(1),

    pub fn init(seed: u64) Samples {
        return .{ .rng = std.Random.Xoshiro256.init(seed) };
    }

    pub fn deinit(self: *Samples, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    /// Reservoir sampling: keep the first `cap` samples, then replace at a
    /// uniformly random index so the retained set stays representative.
    pub fn add(self: *Samples, alloc: std.mem.Allocator, micros: u32) !void {
        self.seen += 1;
        if (self.buf.items.len < self.cap) {
            try self.buf.append(alloc, micros);
            return;
        }
        const idx = self.rng.random().uintLessThan(usize, self.seen);
        if (idx < self.cap) self.buf.items[idx] = micros;
    }

    /// Exact percentile over the retained samples (nearest rank, which is the
    /// right definition for latency budgets).
    pub fn percentile(self: *const Samples, p: f64) u32 {
        if (self.buf.items.len == 0) return 0;
        const copy = std.heap.page_allocator.dupe(u32, self.buf.items) catch return 0;
        defer std.heap.page_allocator.free(copy);
        std.mem.sort(u32, copy, {}, std.sort.asc(u32));
        const rank: usize = @intFromFloat(@as(f64, @floatFromInt(copy.len)) * p);
        const idx = @min(copy.len - 1, if (rank == 0) 0 else rank - 1);
        return copy[idx];
    }

    pub fn count(self: *const Samples) usize {
        return self.buf.items.len;
    }
};

/// Counters plus latency series for one measured run.
pub const Result = struct {
    workload: Workload = .noop,
    backend: []const u8 = "configured",
    workers: u16 = 0,
    queues: u8 = 0,
    elapsed_ms: i64 = 0,
    enqueued: u64 = 0,
    claimed: u64 = 0,
    completed: u64 = 0,
    failed_retryable: u64 = 0,
    failed_permanent: u64 = 0,
    claim_latency: Samples = .{},
    duration: Samples = .{},
    e2e: Samples = .{},
    errors: u64 = 0,

    pub fn throughput(self: *const Result) f64 {
        if (self.elapsed_ms <= 0) return 0;
        return @as(f64, @floatFromInt(self.completed)) * 1000.0 / @as(f64, @floatFromInt(self.elapsed_ms));
    }
};

pub const Reference = struct {
    workload: []const u8 = "",
    backend: []const u8 = "",
    workers: u16 = 0,
    p50_ms: f64 = 0,
    p99_ms: f64 = 0,
    throughput: f64 = 0,
};

pub const GateOutcome = enum { no_reference, pass, fail };

/// Compare p99 against a reference. A reference more than `budget_pct` slower
/// (higher p99) fails the gate; being faster always passes.
pub fn gate(result: *const Result, ref: ?Reference, budget_pct: f64) struct { outcome: GateOutcome, delta_pct: f64 } {
    const r = ref orelse return .{ .outcome = .no_reference, .delta_pct = 0 };
    if (r.p99_ms <= 0) return .{ .outcome = .no_reference, .delta_pct = 0 };
    const ours = @as(f64, @floatFromInt(result.claim_latency.percentile(0.99))) / 1000.0;
    if (ours <= 0) return .{ .outcome = .no_reference, .delta_pct = 0 };
    const delta = (ours - r.p99_ms) / r.p99_ms * 100.0;
    return .{
        .outcome = if (delta > budget_pct) .fail else .pass,
        .delta_pct = delta,
    };
}

fn resultToJson(alloc: std.mem.Allocator, r: *const Result) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "workload": "{s}",
        \\  "backend": "{s}",
        \\  "workers": {d},
        \\  "queues": {d},
        \\  "elapsed_ms": {d},
        \\  "enqueued": {d},
        \\  "claimed": {d},
        \\  "completed": {d},
        \\  "failed_retryable": {d},
        \\  "failed_permanent": {d},
        \\  "errors": {d},
        \\  "claim_p50_ms": {d:.3},
        \\  "claim_p99_ms": {d:.3},
        \\  "duration_p50_ms": {d:.3},
        \\  "duration_p99_ms": {d:.3},
        \\  "e2e_p50_ms": {d:.3},
        \\  "e2e_p99_ms": {d:.3},
        \\  "throughput_per_s": {d:.1}
        \\}}
    , .{
        @tagName(r.workload),                            r.backend,
        r.workers,                                       r.queues,
        r.elapsed_ms,                                    r.enqueued,
        r.claimed,                                       r.completed,
        r.failed_retryable,                              r.failed_permanent,
        r.errors,                                        @divTrunc(r.claim_latency.percentile(50), 1000),
        @divTrunc(r.claim_latency.percentile(99), 1000), @divTrunc(r.duration.percentile(50), 1000),
        @divTrunc(r.duration.percentile(99), 1000),      @divTrunc(r.e2e.percentile(50), 1000),
        @divTrunc(r.e2e.percentile(99), 1000),           r.throughput(),
    });
}

/// Shared per-worker accumulator. Threads own one of these, then merge.
const WorkerState = struct {
    alloc: std.mem.Allocator,
    claimed: u64 = 0,
    completed: u64 = 0,
    failed_retryable: u64 = 0,
    failed_permanent: u64 = 0,
    errors: u64 = 0,
    claim_latency: Samples = .{},
    duration: Samples = .{},
    e2e: Samples = .{},
    rng: std.Random = undefined,
    measure: *std.atomic.Value(bool),

    fn init(alloc: std.mem.Allocator, seed: u64, measure: *std.atomic.Value(bool)) WorkerState {
        var rng = std.Random.DefaultPrng.init(seed);
        return .{
            .alloc = alloc,
            .measure = measure,
            .claim_latency = Samples.init(seed ^ 0xaaaa),
            .duration = Samples.init(seed ^ 0xbbbb),
            .e2e = Samples.init(seed ^ 0xcccc),
            .rng = rng.random(),
        };
    }
};

const Shared = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    broker: broker_mod.Broker,
    states: []WorkerState,
    enqueued: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    producer_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    measure: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queue_names: []const []const u8,
    args_json: []const u8,
};

fn buildArgsJson(alloc: std.mem.Allocator, payload_bytes: u16) ![]u8 {
    const fill_len = @max(1, @as(usize, payload_bytes));
    const buf = try alloc.alloc(u8, fill_len);
    defer alloc.free(buf);
    for (buf, 0..) |*c, i| c.* = @intCast('a' + (i % 26));
    return std.fmt.allocPrint(alloc, "{{\"to\":\"{s}\",\"subject\":\"{s}\"}}", .{ buf, buf });
}

/// Simulate the handler cost for the selected workload.
const WorkerCtx = struct {
    rng: std.Random,
    scratch: u64 = 0x9e3779b97f4a7c15,

    fn run(w: *WorkerCtx, workload: Workload) anyerror!void {
        switch (workload) {
            .noop => {},
            .io => std.time.sleep(20 * std.time.ns_per_ms),
            .cpu => {
                var acc: u64 = w.scratch;
                const until = std.time.milliTimestamp() + 10;
                while (std.time.milliTimestamp() < until) {
                    acc = acc *% 6364136223846793005 +% 1442695040888963407;
                }
                w.scratch = acc;
            },
            .flaky => if (w.rng.uintLessThan(u8, 10) == 0) return error.BenchTransient,
            .poison => if (w.rng.uintLessThan(u8, 100) == 0) return error.BenchPermanent,
        }
    }
};

fn workerThread(shared: *Shared, index: u16) void {
    const alloc = shared.alloc;
    var st = shared.states[index];
    defer {
        shared.states[index] = st;
    }
    var wctx = WorkerCtx{ .rng = st.rng };
    const worker_id_buf = std.fmt.allocPrint(alloc, "bench-{d}", .{index}) catch return;
    defer alloc.free(worker_id_buf);

    var ids: [64]i64 = undefined;
    var epochs: [64]u64 = undefined;
    var batch: [64]broker_mod.Claimed = undefined;

    while (!shared.stop.load(.seq_cst)) {
        const queue = shared.queue_names[index % shared.queue_names.len];
        const n = shared.broker.claim(queue, @min(shared.opts.claim_batch, batch.len), worker_id_buf, shared.opts.lease_ms, &batch) catch {
            st.errors += 1;
            std.time.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) {
            std.time.sleep(2 * std.time.ns_per_ms);
            continue;
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const job = batch[k];
            const now = std.time.milliTimestamp();
            st.claimed += 1;
            if (shared.measure.load(.seq_cst)) {
                st.claim_latency.add(alloc, @intCast(@max(0, now - job.run_at_ms) * 1000)) catch {};
            }

            const started = std.time.milliTimestamp();
            const outcome: anyerror!void = WorkerCtx.run(&wctx, shared.opts.workload);
            const finished = std.time.milliTimestamp();
            if (shared.measure.load(.seq_cst)) {
                st.duration.add(alloc, @intCast(@max(0, finished - started) * 1000)) catch {};
                st.e2e.add(alloc, @intCast(@max(0, finished - job.run_at_ms) * 1000)) catch {};
            }

            if (outcome) |_| {
                shared.broker.finish(queue, job.id, job.lease_epoch) catch {
                    st.errors += 1;
                    continue;
                };
                st.completed += 1;
            } else |err| {
                const permanent = err == error.BenchPermanent;
                var fo = broker_mod.FailOutcome{};
                const retry_at = if (permanent) 0 else std.time.milliTimestamp() + 1000;
                shared.broker.fail(queue, job.id, job.lease_epoch, @errorName(err), !permanent, retry_at, &fo) catch {
                    st.errors += 1;
                    continue;
                };
                if (permanent) st.failed_permanent += 1 else st.failed_retryable += 1;
            }
            if (k < ids.len) {
                ids[k] = job.id;
                epochs[k] = job.lease_epoch;
            }
        }
        // One batched heartbeat per tick, mirroring the runtime's design.
        if (n > 0) {
            shared.broker.heartbeat(queue, ids[0..@min(n, ids.len)], epochs[0..@min(n, epochs.len)], shared.opts.lease_ms) catch {
                st.errors += 1;
            };
        }
    }
    st.rng = wctx.rng;
}

fn producerThread(shared: *Shared, index: u16) void {
    const alloc = shared.alloc;
    var prng = std.Random.Xoshiro256.init(shared.opts.seed ^ (0x1000 + index));
    const per_thread_rate: u32 = if (shared.opts.rate == 0) 0 else @max(1, shared.opts.rate / @max(1, shared.opts.producers));
    var next_ns = std.time.nanoTimestamp();
    while (!shared.stop.load(.seq_cst)) {
        if (shared.opts.rate != 0) {
            next_ns += @divTrunc(@as(i64, per_thread_rate) * std.time.ns_per_s, 1000);
            const now_ns = std.time.nanoTimestamp();
            if (next_ns > now_ns) {
                std.time.sleep(@intCast(@min(next_ns - now_ns, @as(i64, 20 * std.time.ns_per_ms))));
                continue;
            }
        }
        const queue = shared.queue_names[index % shared.queue_names.len];
        var out = broker_mod.Enqueued{};
        shared.broker.enqueue(shared.opts.workload.kindName(), shared.args_json, .{ .queue = queue }, &out) catch {
            _ = shared.producer_errors.fetchAdd(1, .seq_cst);
            std.time.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        _ = prng.next(); // keep the PRNG advancing so seeds stay meaningful
        _ = shared.enqueued.fetchAdd(1, .seq_cst);
    }
    _ = alloc;
}

pub fn run(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    const stdout = std.io.getStdOut().writer();
    const opts = parseArgs(argv) catch |e| {
        try stdout.print("beanline bench: {s}\n\n{s}", .{ @errorName(e), usage });
        return 2;
    };
    // A dry run must not need a broker.
    if (opts.dry_run) {
        try printPlan(stdout, opts);
        return 0;
    }

    const sup = @import("../runtime/supervisor.zig");
    var app = sup.App.init(alloc);
    defer app.deinit();
    const br = app.openBrokerPublic() catch |e| {
        try stdout.print("bench: cannot open backend ({s}); set BEANLINE_DATABASE_URL or BEANLINE_REDIS_URL\n", .{@errorName(e)});
        return 1;
    };
    defer br.deinit();
    return runWithBroker(alloc, argv, br);
}

fn printPlan(stdout: anytype, opts: Options) !void {
    try stdout.print(
        "bench plan (dry run)\n  workload:   {s}\n  backend:    {s}\n  workers:    {d}\n  queues:     {d}\n  duration:   {d}s (warmup {d}s)\n  payload:    {d} bytes\n  rate:       {s}\n  lease:      {d}ms\n  claim batch:{d}\n",
        .{
            @tagName(opts.workload),           opts.backend_label,
            opts.workers,                      opts.queues,
            @divTrunc(opts.duration_ms, 1000), @divTrunc(opts.warmup_ms, 1000),
            opts.payload_bytes,                if (opts.rate == 0) "unthrottled" else "throttled",
            opts.lease_ms,                     opts.claim_batch,
        },
    );
}

/// Run the workload and collect the measurements. No printing: the caller
/// renders the result. This is the piece the tests drive.
pub fn execute(alloc: std.mem.Allocator, opts_in: Options, br: broker_mod.Broker) !Result {
    var opts = opts_in;
    opts.backend_label = br.capabilities().named_backend;

    const queue_names = try alloc.alloc([]const u8, opts.queues);
    defer {
        for (queue_names) |q| alloc.free(q);
        alloc.free(queue_names);
    }
    for (queue_names, 0..) |*q, i| {
        q.* = try std.fmt.allocPrint(alloc, "bench{d}", .{i});
    }

    const states = try alloc.alloc(WorkerState, opts.workers);
    defer alloc.free(states);
    var measure = std.atomic.Value(bool).init(false);
    for (states, 0..) |*s, i| s.* = WorkerState.init(alloc, opts.seed +% i, &measure);

    const args_json = try buildArgsJson(alloc, opts.payload_bytes);
    defer alloc.free(args_json);

    opts.producers = opts.workers;
    var shared = Shared{
        .alloc = alloc,
        .opts = opts,
        .broker = br,
        .states = states,
        .queue_names = queue_names,
        .args_json = args_json,
    };

    // Warm up, then start measuring.
    const threads = try alloc.alloc(std.Thread, opts.workers);
    defer alloc.free(threads);
    for (threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, workerThread, .{ &shared, @as(u16, @intCast(i)) });
    const producers = try alloc.alloc(std.Thread, opts.workers);
    defer alloc.free(producers);
    for (producers, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, producerThread, .{ &shared, @as(u16, @intCast(i)) });

    if (opts.warmup_ms > 0) std.time.sleep(@intCast(@min(opts.warmup_ms, 60_000) * std.time.ns_per_ms));
    measure.store(true, .seq_cst);
    const start = std.time.milliTimestamp();
    std.time.sleep(@intCast(opts.duration_ms * std.time.ns_per_ms));
    const elapsed = std.time.milliTimestamp() - start;
    shared.stop.store(true, .seq_cst);
    for (threads) |t| t.join();
    for (producers) |t| t.join();

    var result = Result{
        .workload = opts.workload,
        .backend = opts.backend_label,
        .workers = opts.workers,
        .queues = opts.queues,
        .elapsed_ms = elapsed,
        .enqueued = shared.enqueued.load(.seq_cst),
        .errors = shared.producer_errors.load(.seq_cst),
    };
    for (states) |*s| {
        result.claimed += s.claimed;
        result.completed += s.completed;
        result.failed_retryable += s.failed_retryable;
        result.failed_permanent += s.failed_permanent;
        result.errors += s.errors;
        result.claim_latency.buf.appendSlice(alloc, s.claim_latency.buf.items) catch {};
        result.claim_latency.seen += s.claim_latency.seen;
        result.duration.buf.appendSlice(alloc, s.duration.buf.items) catch {};
        result.duration.seen += s.duration.seen;
        result.e2e.buf.appendSlice(alloc, s.e2e.buf.items) catch {};
        result.e2e.seen += s.e2e.seen;
    }
    return result;
}

/// Run the bench against an already-open broker. Exposed so the harness can
/// be exercised against a mock broker in tests.
pub fn runWithBroker(alloc: std.mem.Allocator, argv: []const []const u8, br: broker_mod.Broker) !u8 {
    const stdout = std.io.getStdOut().writer();
    var opts = parseArgs(argv) catch |e| {
        try stdout.print("beanline bench: {s}\n\n{s}", .{ @errorName(e), usage });
        return 2;
    };

    if (opts.dry_run) {
        try stdout.print(
            "bench plan (dry run)\n  workload:   {s}\n  backend:    {s}\n  workers:    {d}\n  queues:     {d}\n  duration:   {d}s (warmup {d}s)\n  payload:    {d} bytes\n  rate:       {s}\n  lease:      {d}ms\n  claim batch:{d}\n",
            .{
                @tagName(opts.workload),           opts.backend_label,
                opts.workers,                      opts.queues,
                @divTrunc(opts.duration_ms, 1000), @divTrunc(opts.warmup_ms, 1000),
                opts.payload_bytes,                if (opts.rate == 0) "unthrottled" else "throttled",
                opts.lease_ms,                     opts.claim_batch,
            },
        );
        return 0;
    }

    opts.backend_label = br.capabilities().named_backend;
    const result = try execute(alloc, opts, br);
    var report_result = result;
    defer {
        report_result.claim_latency.deinit(alloc);
        report_result.duration.deinit(alloc);
        report_result.e2e.deinit(alloc);
    }

    // Report.
    if (opts.json) {
        try stdout.print("{s}\n", .{try resultToJson(alloc, &report_result)});
    } else {
        try stdout.print(
            \\backend            {s}
            \\workload           {s}
            \\workers / queues   {d} / {d}
            \\elapsed            {d} ms
            \\enqueued           {d}
            \\claimed            {d}
            \\completed          {d}
            \\failed (retryable) {d}
            \\failed (permanent) {d}
            \\errors             {d}
            \\
            \\claim  p50/p99     {d} / {d} ms
            \\run    p50/p99     {d} / {d} ms
            \\e2e    p50/p99     {d} / {d} ms
            \\throughput         {d:.1} completes/s
            \\
        , .{
            result.backend,                                       @tagName(result.workload),
            result.workers,                                       result.queues,
            result.elapsed_ms,                                    result.enqueued,
            result.claimed,                                       result.completed,
            result.failed_retryable,                              result.failed_permanent,
            result.errors,                                        @divTrunc(result.claim_latency.percentile(50), 1000),
            @divTrunc(result.claim_latency.percentile(99), 1000), @divTrunc(result.duration.percentile(50), 1000),
            @divTrunc(result.duration.percentile(99), 1000),      @divTrunc(result.e2e.percentile(50), 1000),
            @divTrunc(result.e2e.percentile(99), 1000),           result.throughput(),
        });
    }

    if (opts.report_path) |p| {
        const json = try resultToJson(alloc, &result);
        defer alloc.free(json);
        const f = try std.fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try f.writeAll(json);
        try f.writeAll("\n");
    }

    if (opts.gate) {
        const ref = try loadReference(alloc, opts, result.workload, result.backend);
        const g = gate(&result, ref, opts.gate_pct);
        switch (g.outcome) {
            .no_reference => try stdout.print("gate: no reference for {s}/{s}; run with --report to create one\n", .{ result.backend, @tagName(result.workload) }),
            .pass => try stdout.print("gate: pass (p99 {d:.1}% vs reference, budget {d:.1}%)\n", .{ g.delta_pct, opts.gate_pct }),
            .fail => {
                try stdout.print("gate: FAIL (p99 {d:.1}% vs reference, budget {d:.1}%)\n", .{ g.delta_pct, opts.gate_pct });
                return 1;
            },
        }
    }
    return 0;
}

/// Load bench/reference/<backend>-<workload>.json if it exists.
pub fn loadReference(alloc: std.mem.Allocator, opts: Options, workload: Workload, backend: []const u8) !?Reference {
    const name = try std.fmt.allocPrint(alloc, "{s}-{s}.json", .{ backend, @tagName(workload) });
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ opts.reference_dir, name });
    defer alloc.free(path);
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const buf = file.readToEndAlloc(alloc, 64 * 1024) catch return null;
    defer alloc.free(buf);
    const parsed = std.json.parseFromSlice(Reference, alloc, buf, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const r = parsed.value;
    return Reference{
        .workload = r.workload,
        .backend = r.backend,
        .workers = r.workers,
        .p50_ms = r.p50_ms,
        .p99_ms = r.p99_ms,
        .throughput = r.throughput,
    };
}

test "workload parsing" {
    try std.testing.expectEqual(Workload.io, Workload.parse("io-bound").?);
    try std.testing.expectEqual(Workload.poison, Workload.parse("poison").?);
    try std.testing.expect(Workload.parse("nope") == null);
    try std.testing.expectEqualStrings("bench.noop", Workload.noop.kindName());
}

test "argument parsing" {
    const argv = [_][]const u8{
        "beanline", "bench",    "--workload", "flaky",     "--duration", "5",      "--workers",
        "8",        "--queues", "3",          "--payload", "512",        "--rate", "100",
        "--gate",
    };
    const o = try parseArgs(&argv);
    try std.testing.expectEqual(Workload.flaky, o.workload);
    try std.testing.expectEqual(@as(i64, 5000), o.duration_ms);
    try std.testing.expectEqual(@as(u16, 8), o.workers);
    try std.testing.expectEqual(@as(u8, 3), o.queues);
    try std.testing.expectEqual(@as(u16, 512), o.payload_bytes);
    try std.testing.expectEqual(@as(u32, 100), o.rate);
    try std.testing.expect(o.gate);
}

test "argument validation" {
    try std.testing.expectError(error.BadQueues, parseArgs(&.{ "beanline", "bench", "--queues", "0" }));
    try std.testing.expectError(error.BadWorkers, parseArgs(&.{ "beanline", "bench", "--workers", "0" }));
    try std.testing.expectError(error.BadDuration, parseArgs(&.{ "beanline", "bench", "--duration", "0" }));
    try std.testing.expectError(error.BadWorkload, parseArgs(&.{ "beanline", "bench", "--workload", "nope" }));
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "beanline", "bench", "--nope" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "beanline", "bench", "--workload" }));
}

test "samples percentiles are nearest rank" {
    const alloc = std.testing.allocator;
    var s = Samples.init(7);
    defer s.deinit(alloc);
    var i: u32 = 1;
    while (i <= 100) : (i += 1) try s.add(alloc, i * 1000); // 1ms..100ms
    // Nearest rank: p50 is the 50th of 100 samples, p99 the 99th.
    try std.testing.expectEqual(@as(u32, 50_000), s.percentile(0.50));
    try std.testing.expectEqual(@as(u32, 99_000), s.percentile(0.99));
    try std.testing.expectEqual(@as(usize, 100), s.count());
}

test "samples cap memory and keep sampling" {
    const alloc = std.testing.allocator;
    var s = Samples.init(9);
    defer s.deinit(alloc);
    s.cap = 16;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) try s.add(alloc, i);
    try std.testing.expectEqual(@as(usize, 16), s.count());
    try std.testing.expectEqual(@as(u64, 1000), s.seen);
}

test "empty samples report zero" {
    const alloc = std.testing.allocator;
    var s = Samples.init(1);
    defer s.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), s.percentile(0.99));
}

test "gate passes, fails, and tolerates a missing reference" {
    var r = Result{ .claim_latency = .{} };
    const alloc = std.testing.allocator;
    defer {
        r.claim_latency.deinit(alloc);
        r.duration.deinit(alloc);
        r.e2e.deinit(alloc);
    }
    var s = Samples.init(3);
    defer s.deinit(alloc);
    var i: usize = 0;
    while (i < 100) : (i += 1) try s.add(alloc, 10_000); // p99 = 10ms
    r.claim_latency.buf.appendSlice(alloc, s.buf.items) catch {};

    const ref = Reference{ .p99_ms = 10 };
    try std.testing.expectEqual(GateOutcome.pass, gate(&r, ref, 5).outcome);

    const slow = Reference{ .p99_ms = 5 };
    const g = gate(&r, slow, 5);
    try std.testing.expectEqual(GateOutcome.fail, g.outcome);
    try std.testing.expect(g.delta_pct > 90);

    try std.testing.expectEqual(GateOutcome.no_reference, gate(&r, null, 5).outcome);
    try std.testing.expectEqual(GateOutcome.no_reference, gate(&r, Reference{ .p99_ms = 0 }, 5).outcome);
}

test "faster than reference always passes" {
    var r = Result{ .claim_latency = .{} };
    const alloc = std.testing.allocator;
    defer {
        r.claim_latency.deinit(alloc);
        r.duration.deinit(alloc);
        r.e2e.deinit(alloc);
    }
    var s = Samples.init(3);
    defer s.deinit(alloc);
    var i: usize = 0;
    while (i < 100) : (i += 1) try s.add(alloc, 1_000); // 1ms
    r.claim_latency.buf.appendSlice(alloc, s.buf.items) catch {};
    try std.testing.expectEqual(GateOutcome.pass, gate(&r, Reference{ .p99_ms = 50 }, 5).outcome);
}

test "throughput math" {
    var r = Result{ .elapsed_ms = 1000, .completed = 500 };
    try std.testing.expectEqual(@as(f64, 500), r.throughput());
    r.elapsed_ms = 0;
    try std.testing.expectEqual(@as(f64, 0), r.throughput());
}

test "reference round trip parses the report shape" {
    const alloc = std.testing.allocator;
    const json =
        \\{"workload":"noop","backend":"postgres","workers":4,"p50_ms":1.5,"p99_ms":9.25,"throughput":5200.0}
    ;
    const parsed = try std.json.parseFromSlice(Reference, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 9.25), parsed.value.p99_ms);
    try std.testing.expectEqualStrings("postgres", parsed.value.backend);
}

/// A tiny in-memory broker so the bench loop (producers, workers, finish,
/// latency accounting) is exercised without a database.
const MockBroker = struct {
    mutex: std.Thread.Mutex = .{},
    pending: std.ArrayListUnmanaged(broker_mod.Claimed) = .{},
    next_id: i64 = 1,
    completed: u64 = 0,

    fn enqueue(_: *anyopaque, _: []const u8, _: []const u8, _: broker_mod.EnqueueOptions, out: *broker_mod.Enqueued) anyerror!void {
        out.* = .{ .id = 1 };
    }

    fn claim(ctx: *anyopaque, _: []const u8, limit: u32, _: []const u8, _: u64, out: []broker_mod.Claimed) anyerror!usize {
        const self: *MockBroker = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        while (n < limit and n < out.len and self.pending.items.len > 0) {
            out[n] = self.pending.orderedRemove(0);
            n += 1;
        }
        return n;
    }

    fn heartbeat(_: *anyopaque, _: []const u8, _: []const i64, _: []const u64, _: u64) anyerror!void {}

    fn finish(ctx: *anyopaque, _: []const u8, _: i64, _: u64) anyerror!void {
        const self: *MockBroker = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.completed += 1;
    }

    fn fail(_: *anyopaque, _: []const u8, _: i64, _: u64, _: []const u8, _: bool, _: i64, out: *broker_mod.FailOutcome) anyerror!void {
        out.* = .{};
    }

    fn cancel(_: *anyopaque, _: []const u8, _: i64, _: ?u64) anyerror!void {}

    fn promote(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
        return 0;
    }

    fn reap(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
        return 0;
    }

    fn depth(_: *anyopaque, _: []const u8, out: *broker_mod.Depth) anyerror!void {
        out.* = .{};
    }

    fn capabilitiesFn() broker_mod.Capabilities {
        return .{ .transactional_enqueue = false, .pubsub_wakeups = false, .named_backend = "mock" };
    }

    fn deinit(_: *anyopaque) void {}

    const vt = broker_mod.VTable{
        .enqueue = enqueue,
        .claim = claim,
        .heartbeat = heartbeat,
        .finish = finish,
        .fail = fail,
        .cancel = cancel,
        .promote = promote,
        .reap = reap,
        .depth = depth,
        .capabilities = capabilitiesFn,
        .deinit = deinit,
    };
};

test "bench loop runs end to end against a mock broker" {
    const alloc = std.testing.allocator;
    var mock = MockBroker{ .pending = .{} };
    defer mock.pending.deinit(alloc);

    // Seed a few jobs for the workers to claim and finish.
    for (0..8) |i| {
        try mock.pending.append(alloc, .{
            .id = @intCast(i + 1),
            .queue = "bench0",
            .kind = "bench.noop",
            .args_json = "{}",
            .attempts = 1,
            .max_attempts = 25,
            .lease_epoch = 1,
            .priority = 1,
            .run_at_ms = std.time.milliTimestamp(),
        });
    }

    const argv = [_][]const u8{
        "beanline", "bench", "--workload", "noop", "--duration", "1", "--warmup", "0", "--workers", "2",
    };
    var opts = try parseArgs(&argv);
    opts.duration_ms = 300;
    opts.warmup_ms = 0;
    opts.workers = 2;

    const br = broker_mod.Broker{ .ptr = &mock, .vtable = &MockBroker.vt };
    var result = try execute(alloc, opts, br);
    defer {
        result.claim_latency.deinit(alloc);
        result.duration.deinit(alloc);
        result.e2e.deinit(alloc);
    }
    try std.testing.expectEqual(@as(u64, 8), mock.completed);
    try std.testing.expectEqual(@as(u64, 8), result.completed);
    try std.testing.expect(result.claimed >= 8);
}
