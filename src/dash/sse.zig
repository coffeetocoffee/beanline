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

pub const Subscription = struct {
    queue_filter: []const u8,
    buf: std.ArrayListUnmanaged(u8) = .{},
    dropped: u64 = 0,

    pub fn push(self: *Subscription, alloc: std.mem.Allocator, ev: Event) !void {
        var tmp: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "event: {s}\ndata: {{\"queue\":\"{s}\",\"job_id\":{d},\"at\":{d}}}\n\n", .{
            ev.kind, ev.queue, ev.job_id, ev.at_ms,
        });
        if (self.buf.items.len + line.len > 256 * 1024) {
            // drop oldest: halve the buffer
            const half = self.buf.items.len / 2;
            std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[half..]);
            self.buf.items.len -= half;
            self.dropped += 1;
        }
        try self.buf.appendSlice(alloc, line);
    }

    /// Drain buffered bytes into `dest`; returns bytes written.
    pub fn drain(self: *Subscription, dest: []u8) usize {
        const n = @min(dest.len, self.buf.items.len);
        @memcpy(dest[0..n], self.buf.items[0..n]);
        std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[n..]);
        self.buf.items.len -= n;
        return n;
    }

    pub fn deinit(self: *Subscription, alloc: std.mem.Allocator) void {
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
