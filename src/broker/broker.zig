const std = @import("std");

pub const Status = enum {
    available,
    scheduled,
    running,
    completed,
    dead,
    discarded,
    cancelled,

    pub fn fromSql(s: []const u8) ?Status {
        const map = [_]struct { []const u8, Status }{
            .{ "available", .available },
            .{ "scheduled", .scheduled },
            .{ "running", .running },
            .{ "completed", .completed },
            .{ "dead", .dead },
            .{ "discarded", .discarded },
            .{ "cancelled", .cancelled },
        };
        for (map) |e| {
            if (std.mem.eql(u8, e[0], s)) return e[1];
        }
        return null;
    }
};

pub const EnqueueOptions = struct {
    queue: []const u8 = "default",
    priority: u8 = 1,
    run_at_ms: i64 = 0,
    max_attempts: u32 = 25,
    /// How many lease expiries the job tolerates before it is
    /// dead-lettered. A lease expiry (worker killed, host reboot, heartbeat
    /// lost) does not spend an attempt, so this is what bounds a job whose
    /// handler kills its worker on every attempt: without it the attempt
    /// counter never climbs and max_attempts is never reached. 0 disables
    /// the bound and requeues the job forever.
    max_lease_losses: u32 = 3,
    unique_key: ?[]const u8 = null,
    dedup_run_id: ?[]const u8 = null,
    /// Optional batch ID to associate this job with a batch. When all jobs
    /// in a batch complete, the batch callback (if any) is enqueued.
    batch_id: ?i64 = null,
    tags: []const []const u8 = &.{},
    context_json: []const u8 = "{}",
    unique: Unique = .block,
};

pub const Unique = enum { block, skip, replace, until_complete };

pub const Enqueued = struct {
    id: i64 = 0,
    deduped: bool = false,
    replaced: bool = false,
};

/// Why a job stopped without completing.
///
/// This is the machine-readable reason the architecture document asks for in
/// §10.4. It is stored on the job row, so a dead-letter queue can be
/// aggregated by cause instead of by reading event JSON and joining to the
/// row.
pub const DeadReason = enum {
    /// The attempt budget ran out. The error itself was classified as worth
    /// retrying, but there were no attempts left.
    attempts_exhausted,
    /// The handler returned an error the kind classified as permanent.
    non_retryable,
    /// The job lost too many leases: the handler kept killing its worker.
    crash_loop,
    /// An operator discarded the job.
    discarded_by_operator,
    /// The job was cancelled.
    cancelled,

    pub fn toSql(self: DeadReason) []const u8 {
        return @tagName(self);
    }

    pub fn fromSql(s: []const u8) ?DeadReason {
        inline for (@typeInfo(DeadReason).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(DeadReason, f.name);
        }
        return null;
    }
};

/// What should happen to a job whose attempt just failed.
///
/// The caller states the intent in one value, so "the error is permanent" and
/// "the error was fine but the budget is spent" cannot be confused with each
/// other, and the broker does not have to guess which one it is looking at.
pub const Failure = union(enum) {
    /// The error is worth trying again. The value is when to try.
    retry: i64,
    /// The handler's error is permanent: the job is dead now.
    non_retryable: void,
    /// The error was worth retrying, but the attempt budget is spent.
    attempts_exhausted: void,
};

pub const Claimed = struct {
    id: i64,
    queue: []const u8,
    kind: []const u8,
    args_json: []const u8,
    attempts: u32,
    max_attempts: u32,
    lease_epoch: u64,
    priority: u8,
    run_at_ms: i64,
    tags: []const []const u8 = &.{},
    context_json: []const u8 = "{}",
};

pub const FailOutcome = struct {
    status: Status = .available,
    retry_at_ms: i64 = 0,
    attempts: u32 = 0,
    /// Why the job died, when it did. Null while the job is still live.
    dead_reason: ?DeadReason = null,
};

pub const Depth = struct {
    available: u64 = 0,
    scheduled: u64 = 0,
    running: u64 = 0,
    dead: u64 = 0,
    completed: u64 = 0,
    cancelled: u64 = 0,
    oldest_available_ms: i64 = 0,
};

pub const Capabilities = struct {
    transactional_enqueue: bool,
    pubsub_wakeups: bool,
    named_backend: []const u8,
};

/// A job row as surfaced by the read-side query API (dashboard / REST).
pub const JobRow = struct {
    id: i64,
    queue: []const u8,
    kind: []const u8,
    args_json: []const u8,
    status: Status,
    priority: u8,
    run_at_ms: i64,
    attempts: u32,
    max_attempts: u32,
    /// Lease expiries so far. Never refunded, unlike `attempts`.
    lease_losses: u32 = 0,
    /// Lease expiries tolerated before the job is dead-lettered.
    max_lease_losses: u32 = 0,
    lease_epoch: u64,
    worker_id: []const u8,
    inserted_ms: i64,
    started_ms: i64,
    finished_ms: i64,
    /// Why the job stopped without completing. Null while it is still live,
    /// and null for jobs that predate the column.
    dead_reason: ?DeadReason = null,
};

/// A single job event row (audit trail view).
pub const EventRow = struct {
    job_id: i64,
    seq: i64,
    event_type: []const u8,
    data_json: []const u8,
    at_ms: i64,
};

/// Batch creation options.
pub const BatchOptions = struct {
    /// Total number of jobs in this batch.
    total: u32,
    /// Optional callback kind to enqueue when the batch completes.
    callback_kind: ?[]const u8 = null,
    /// Optional callback arguments (JSON).
    callback_args: []const u8 = "{}",
};

/// Batch information returned by createBatch.
pub const BatchInfo = struct {
    id: i64,
    total: u32,
    remaining: u32,
    status: []const u8,
};

/// Query filters for job listing.
pub const JobFilter = struct {
    queue: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    status: ?Status = null,
    limit: u32 = 50,
    offset: u32 = 0,
};

pub const VTable = struct {
    enqueue: *const fn (ctx: *anyopaque, kind: []const u8, args_json: []const u8, opts: EnqueueOptions, out: *Enqueued) anyerror!void,
    claim: *const fn (ctx: *anyopaque, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []Claimed) anyerror!usize,
    heartbeat: *const fn (ctx: *anyopaque, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) anyerror!void,
    finish: *const fn (ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64) anyerror!void,
    fail: *const fn (ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, failure: Failure, out: *FailOutcome) anyerror!void,
    cancel: *const fn (ctx: *anyopaque, queue: []const u8, id: i64, lease_epoch: ?u64) anyerror!void,
    promote: *const fn (ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32,
    reap: *const fn (ctx: *anyopaque, queues: []const []const u8, limit: u32) anyerror!u32,
    /// Create a new batch record. Returns the batch ID.
    create_batch: ?*const fn (ctx: *anyopaque, opts: BatchOptions, out: *BatchInfo) anyerror!void = null,
    /// Notify the batch that a job has completed. Decrements remaining; when
    /// it reaches 0, enqueues the callback (if any) and marks the batch done.
    complete_batch_job: ?*const fn (ctx: *anyopaque, batch_id: i64, success: bool) anyerror!void = null,
    /// Retention sweep. Deletes completed job rows older than
    /// `retention_completed_ms` and job events older than
    /// `retention_events_ms`, in bounded batches so the delete never holds a
    /// long lock. `error.Unsupported` means the backend cannot express it.
    retention: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, retention_completed_ms: i64, retention_events_ms: i64) anyerror!u64 = null,
    depth: *const fn (ctx: *anyopaque, queue: []const u8, out: *Depth) anyerror!void,
    capabilities: *const fn () Capabilities,
    deinit: *const fn (ctx: *anyopaque) void,
    // Optional read-side query API for the dashboard (may be null).
    list_jobs: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, filter: JobFilter, out: *std.ArrayList(JobRow)) anyerror!void = null,
    get_job: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *?JobRow) anyerror!void = null,
    job_events: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(EventRow)) anyerror!void = null,
    queue_names: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) anyerror!void = null,
    retry: ?*const fn (ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void = null,
    discard: ?*const fn (ctx: *anyopaque, queue: []const u8, id: i64) anyerror!void = null,
    // Optional operator control. Pause must persist in the broker so it is
    // visible to workers in other processes; claim skips paused queues.
    pause_queue: ?*const fn (ctx: *anyopaque, queue: []const u8) anyerror!void = null,
    resume_queue: ?*const fn (ctx: *anyopaque, queue: []const u8) anyerror!void = null,
    queue_paused: ?*const fn (ctx: *anyopaque, queue: []const u8) anyerror!bool = null,
};

pub const Broker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Batch = struct {
        max: usize = 16,
        items: [16]Claimed = undefined,

        pub fn slice(self: *Batch) []Claimed {
            return self.items[0..self.max];
        }
    };

    pub fn enqueue(self: Broker, kind: []const u8, args_json: []const u8, opts: EnqueueOptions, out: *Enqueued) anyerror!void {
        return self.vtable.enqueue(self.ptr, kind, args_json, opts, out);
    }

    pub fn claim(self: Broker, queue: []const u8, limit: u32, worker_id: []const u8, lease_ms: u64, out: []Claimed) anyerror!usize {
        return self.vtable.claim(self.ptr, queue, limit, worker_id, lease_ms, out);
    }

    pub fn heartbeat(self: Broker, queue: []const u8, ids: []const i64, epochs: []const u64, lease_ms: u64) anyerror!void {
        return self.vtable.heartbeat(self.ptr, queue, ids, epochs, lease_ms);
    }

    pub fn finish(self: Broker, queue: []const u8, id: i64, lease_epoch: u64) anyerror!void {
        return self.vtable.finish(self.ptr, queue, id, lease_epoch);
    }

    pub fn fail(self: Broker, queue: []const u8, id: i64, lease_epoch: u64, err_name: []const u8, failure: Failure, out: *FailOutcome) anyerror!void {
        return self.vtable.fail(self.ptr, queue, id, lease_epoch, err_name, failure, out);
    }

    pub fn cancel(self: Broker, queue: []const u8, id: i64, lease_epoch: ?u64) anyerror!void {
        return self.vtable.cancel(self.ptr, queue, id, lease_epoch);
    }

    pub fn promote(self: Broker, queues: []const []const u8, limit: u32) anyerror!u32 {
        return self.vtable.promote(self.ptr, queues, limit);
    }

    pub fn reap(self: Broker, queues: []const []const u8, limit: u32) anyerror!u32 {
        return self.vtable.reap(self.ptr, queues, limit);
    }

    /// Create a new batch record. Returns the batch info including the batch ID.
    pub fn createBatch(self: Broker, opts: BatchOptions, out: *BatchInfo) anyerror!void {
        const f = self.vtable.create_batch orelse return error.Unsupported;
        return f(self.ptr, opts, out);
    }

    /// Notify the batch that a job has completed. Decrements remaining; when
    /// it reaches 0, enqueues the callback (if any) and marks the batch done.
    pub fn completeBatchJob(self: Broker, batch_id: i64, success: bool) anyerror!void {
        const f = self.vtable.complete_batch_job orelse return error.Unsupported;
        return f(self.ptr, batch_id, success);
    }

    /// Run one retention sweep. Returns the number of completed job rows
    /// deleted, or `error.Unsupported` when this backend has no retention.
    pub fn retention(self: Broker, alloc: std.mem.Allocator, retention_completed_ms: i64, retention_events_ms: i64) anyerror!u64 {
        const f = self.vtable.retention orelse return error.Unsupported;
        return f(self.ptr, alloc, retention_completed_ms, retention_events_ms);
    }

    pub fn depth(self: Broker, queue: []const u8, out: *Depth) anyerror!void {
        return self.vtable.depth(self.ptr, queue, out);
    }

    pub fn capabilities(self: Broker) Capabilities {
        return self.vtable.capabilities();
    }

    pub fn deinit(self: Broker) void {
        self.vtable.deinit(self.ptr);
    }

    /// Optional read-side queries; return error.Unsupported when the backend
    /// does not implement them.
    pub fn listJobs(self: Broker, alloc: std.mem.Allocator, filter: JobFilter, out: *std.ArrayList(JobRow)) anyerror!void {
        const f = self.vtable.list_jobs orelse return error.Unsupported;
        return f(self.ptr, alloc, filter, out);
    }

    pub fn getJob(self: Broker, alloc: std.mem.Allocator, id: i64, out: *?JobRow) anyerror!void {
        const f = self.vtable.get_job orelse return error.Unsupported;
        return f(self.ptr, alloc, id, out);
    }

    pub fn jobEvents(self: Broker, alloc: std.mem.Allocator, id: i64, out: *std.ArrayList(EventRow)) anyerror!void {
        const f = self.vtable.job_events orelse return error.Unsupported;
        return f(self.ptr, alloc, id, out);
    }

    pub fn queueNames(self: Broker, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) anyerror!void {
        const f = self.vtable.queue_names orelse return error.Unsupported;
        return f(self.ptr, alloc, out);
    }

    pub fn retry(self: Broker, queue: []const u8, id: i64) anyerror!void {
        const f = self.vtable.retry orelse return error.Unsupported;
        return f(self.ptr, queue, id);
    }

    pub fn discard(self: Broker, queue: []const u8, id: i64) anyerror!void {
        const f = self.vtable.discard orelse return error.Unsupported;
        return f(self.ptr, queue, id);
    }

    pub fn pauseQueue(self: Broker, queue: []const u8) anyerror!void {
        const f = self.vtable.pause_queue orelse return error.Unsupported;
        return f(self.ptr, queue);
    }

    pub fn resumeQueue(self: Broker, queue: []const u8) anyerror!void {
        const f = self.vtable.resume_queue orelse return error.Unsupported;
        return f(self.ptr, queue);
    }

    pub fn queuePaused(self: Broker, queue: []const u8) anyerror!bool {
        const f = self.vtable.queue_paused orelse return error.Unsupported;
        return f(self.ptr, queue);
    }
};

test "status round trip" {
    for ([_][]const u8{ "available", "scheduled", "running", "completed", "dead", "discarded", "cancelled" }) |s| {
        const st = Status.fromSql(s).?;
        try std.testing.expectEqualStrings(s, @tagName(st));
    }
    try std.testing.expect(Status.fromSql("bogus") == null);
}

test "batch slices claimed items" {
    var b = Broker.Batch{};
    b.max = 3;
    try std.testing.expectEqual(@as(usize, 3), b.slice().len);
}
