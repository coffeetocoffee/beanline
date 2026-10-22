const std = @import("std");

/// Server-sent events fan-out. The runtime publishes claim/complete/dead
/// events here; each SSE connection has a subscription that buffers lines and
/// flushes them on a cadence. Bounded per-subscription buffers with drop-oldest
/// keep a slow browser from stalling the worker loop.
pub const Event = struct {
    kind: []const u8,
    queue: []const u8,
    job_id: i64,
    at_ms: i64,
};

/// Upper bound on a subscription's buffer. Exceeding it drops the oldest
/// frames rather than growing without limit.
const max_buffer: usize = 256 * 1024;

/// One SSE connection's buffer.
///
/// `push` runs on the thread that publishes events (the worker claim loop)
/// and `drain` runs on the HTTP thread serving the connection, so both
/// mutate `buf` and both take this subscription's own mutex. The bus mutex
/// guards the subscription list, not the buffers.
///
/// Lock order is always bus -> subscription: `publish` and `unsubscribe`
/// hold the bus mutex and then take the subscription mutex, while `drain`
/// takes only the subscription mutex. There is no path that takes them in
/// the other order, so the two locks cannot deadlock.
pub const Subscription = struct {
    queue_filter: []const u8,
    buf: std.ArrayListUnmanaged(u8) = .{},
    dropped: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn push(self: *Subscription, alloc: std.mem.Allocator, ev: Event) !void {
        var tmp: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "event: {s}\ndata: {{\"queue\":\"{s}\",\"job_id\":{d},\"at\":{d}}}\n\n", .{
            ev.kind, ev.queue, ev.job_id, ev.at_ms,
        });
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.buf.items.len + line.len > max_buffer) {
            // Drop the oldest frames. The cut has to land on a frame
            // boundary: the client reads a byte stream, so removing bytes
            // from the middle of it splices the frames around the cut
            // together and every event after the cut is lost too.
            const keep_from = self.dropOldest();
            std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[keep_from..]);
            self.buf.items.len -= keep_from;
        }
        try self.buf.appendSlice(alloc, line);
    }

    /// Index of the first frame to keep, dropping whole frames from the
    /// front until at least half the buffer is gone. Counts the frames it
    /// discards in `dropped`.
    ///
    /// Dropping half rather than the minimum needed keeps the cost
    /// amortised: the memmove in `push` then happens once per half buffer
    /// of pushes instead of once per push, which matters because the
    /// buffer is 256 KiB.
    fn dropOldest(self: *Subscription) usize {
        const target = self.buf.items.len / 2;
        var keep_from: usize = 0;
        var dropped: usize = 0;
        var i: usize = 0;
        while (i + 1 < self.buf.items.len) : (i += 1) {
            if (self.buf.items[i] != '\n' or self.buf.items[i + 1] != '\n') continue;
            keep_from = i + 2;
            dropped += 1;
            if (keep_from >= target) break;
        }
        self.dropped += dropped;
        return keep_from;
    }

    /// Drain buffered bytes into `dest`; returns bytes written.
    ///
    /// Only whole frames are copied. Splitting a frame across two drains
    /// is harmless (the browser reassembles the lines), but the drop
    /// policy removes bytes from the front of the buffer, so the two
    /// operations together have to agree on where a frame starts. Keeping
    /// the buffer frame aligned on both sides is what makes dropping the
    /// oldest frames safe for the client.
    pub fn drain(self: *Subscription, dest: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var end: usize = 0;
        var i: usize = 0;
        while (i + 1 < self.buf.items.len) : (i += 1) {
            if (self.buf.items[i] != '\n' or self.buf.items[i + 1] != '\n') continue;
            const boundary = i + 2;
            if (boundary > dest.len) break;
            end = boundary;
        }
        if (end == 0 and self.buf.items.len > 0) {
            // A frame larger than the destination cannot be delivered
            // whole. Copy what fits rather than stalling the stream.
            // Frames are capped at 512 bytes by `push` and the dashboard
            // drains into 4 KiB, so this is a defensive path only.
            end = @min(dest.len, self.buf.items.len);
        }
        @memcpy(dest[0..end], self.buf.items[0..end]);
        std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[end..]);
        self.buf.items.len -= end;
        return end;
    }

    pub fn deinit(self: *Subscription, alloc: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buf.deinit(alloc);
    }
};

pub const Bus = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    subs: std.ArrayListUnmanaged(*Subscription) = .{},

    pub fn init(alloc: std.mem.Allocator) Bus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Bus) void {
        for (self.subs.items) |s| {
            s.deinit(self.alloc);
            self.alloc.destroy(s);
        }
        self.subs.deinit(self.alloc);
    }

    pub fn subscribe(self: *Bus, queue_filter: []const u8) !*Subscription {
        const s = try self.alloc.create(Subscription);
        errdefer self.alloc.destroy(s);
        s.* = .{ .queue_filter = queue_filter };
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.subs.append(self.alloc, s);
        return s;
    }

    pub fn unsubscribe(self: *Bus, s: *Subscription) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subs.items, 0..) |cur, i| {
            if (cur == s) {
                _ = self.subs.swapRemove(i);
                s.deinit(self.alloc);
                self.alloc.destroy(s);
                return;
            }
        }
    }

    pub fn publish(self: *Bus, ev: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subs.items) |s| {
            if (s.queue_filter.len == 0 or std.mem.eql(u8, s.queue_filter, ev.queue)) {
                s.push(self.alloc, ev) catch {};
            }
        }
    }
};

test "sse fan out and drain" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const a = try bus.subscribe("mailers");
    const b = try bus.subscribe("");
    bus.publish(.{ .kind = "claimed", .queue = "mailers", .job_id = 7, .at_ms = 1 });
    bus.publish(.{ .kind = "completed", .queue = "other", .job_id = 8, .at_ms = 2 });
    try std.testing.expect(a.buf.items.len > 0);
    try std.testing.expect(b.buf.items.len > a.buf.items.len);
    var dest: [1024]u8 = undefined;
    const n = a.drain(&dest);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, dest[0..n], "event: claimed") != null);
    try std.testing.expect(a.buf.items.len == 0);
    bus.unsubscribe(b);
    try std.testing.expectEqual(@as(usize, 1), bus.subs.items.len);
    bus.unsubscribe(a);
}

/// Context shared by the publisher thread and the draining thread in the
/// concurrency test below.
const RaceCtx = struct {
    bus: *Bus,
    sub: *Subscription,
    iters: usize,
    publisher_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Publisher side: runs on a thread other than the one draining, exactly
/// like the worker thread that publishes while an HTTP thread serves the
/// SSE connection.
fn racePublish(ctx: *RaceCtx) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) {
        ctx.bus.publish(.{
            .kind = "claimed",
            .queue = "mailers",
            .job_id = @intCast(i % 1000),
            .at_ms = 1,
        });
    }
    ctx.publisher_done.store(true, .seq_cst);
}

/// A frame is `event: claimed\ndata: {"queue":"mailers","job_id":<n>,"at":1}`.
/// Round-trip the job id: parse it, rebuild the frame, compare. Any byte
/// that moved during a concurrent push is caught.
fn expectSseFrame(frame: []const u8) !void {
    const prefix = "event: claimed\ndata: {\"queue\":\"mailers\",\"job_id\":";
    if (!std.mem.startsWith(u8, frame, prefix)) return error.BadSseFrame;
    const rest = frame[prefix.len..];
    const sep = std.mem.indexOf(u8, rest, ",\"at\":1}") orelse return error.BadSseFrame;
    const job_id = rest[0..sep];
    if (job_id.len == 0) return error.BadSseFrame;
    for (job_id) |c| {
        if (c < '0' or c > '9') return error.BadSseFrame;
    }
    var buf: [160]u8 = undefined;
    const rebuilt = try std.fmt.bufPrint(&buf, "{s}{s},\"at\":1}}", .{ prefix, job_id });
    if (!std.mem.eql(u8, frame, rebuilt)) return error.BadSseFrame;
}

/// Drainer side: consume everything the publisher produces and check that
/// the byte stream is always a sequence of intact frames.
fn raceDrain(ctx: *RaceCtx) !usize {
    var dest: [4096]u8 = undefined;
    // A frame is at most 512 bytes (the formatter's stack buffer), so a
    // pending buffer of 8 KiB always holds a partial frame plus one chunk.
    var pending: [8192]u8 = undefined;
    var pending_len: usize = 0;
    var frames: usize = 0;

    while (true) {
        const n = ctx.sub.drain(&dest);
        if (n == 0) {
            if (ctx.publisher_done.load(.seq_cst)) break;
            // Pace the drainer so the publisher can fill the buffer past
            // its cap. That is what puts the drop path and the append path
            // on the same buffer at the same time.
            std.time.sleep(1 * std.time.ns_per_ms);
            continue;
        }
        if (pending_len + n > pending.len) return error.PendingOverflow;
        @memcpy(pending[pending_len..][0..n], dest[0..n]);
        pending_len += n;

        // Split the buffer into frames in one linear pass.
        var start: usize = 0;
        var i: usize = 0;
        while (i + 1 < pending_len) : (i += 1) {
            if (pending[i] != '\n' or pending[i + 1] != '\n') continue;
            try expectSseFrame(pending[start..i]);
            frames += 1;
            start = i + 2;
            i += 1;
        }
        if (start > 0) {
            std.mem.copyForwards(u8, pending[0 .. pending_len - start], pending[start..pending_len]);
            pending_len -= start;
        }
    }
    return frames;
}

test "sse publish and drain do not race" {
    const alloc = std.testing.allocator;
    var bus = Bus.init(alloc);
    defer bus.deinit();
    const sub = try bus.subscribe("");
    defer bus.unsubscribe(sub);

    var ctx = RaceCtx{ .bus = &bus, .sub = sub, .iters = 200_000 };
    const th = try std.Thread.spawn(.{}, racePublish, .{&ctx});
    const frames = try raceDrain(&ctx);
    th.join();

    // The publisher outruns the drainer, so most events are dropped by the
    // bounded buffer, but the frames that do arrive must be intact.
    try std.testing.expect(frames > 0);
}
