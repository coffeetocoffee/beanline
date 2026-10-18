const std = @import("std");

pub const Task = struct {
    ptr: *anyopaque,
    run: *const fn (ptr: *anyopaque) void,
};

pub const Pool = struct {
    alloc: std.mem.Allocator,
    threads_storage: []std.Thread = &.{},
    threads: []std.Thread = &.{},
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    idle_cond: std.Thread.Condition = .{},
    tasks: std.ArrayListUnmanaged(Task) = .{},
    busy: usize = 0,
    accepting: bool = true,
    closing: bool = false,

    // Call start immediately after zero-init; workers retain *self, so the
    // Pool must never be moved/copied afterwards.
    pub fn start(self: *Pool, n: usize) !void {
        self.threads_storage = try self.alloc.alloc(std.Thread, n);
        errdefer {
            self.closing = true;
            self.cond.broadcast();
            for (self.threads) |t| t.join();
            self.threads = &.{};
            self.alloc.free(self.threads_storage);
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.threads_storage[i] = try std.Thread.spawn(.{}, worker, .{self});
        }
        self.threads = self.threads_storage;
        return;
    }

    pub fn submit(self: *Pool, t: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.accepting or self.closing) return error.ShuttingDown;
        try self.tasks.append(self.alloc, t);
        self.cond.signal();
    }

    pub fn pending(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len;
    }

    // Stop accepting work, wait for all submitted tasks to finish.
    pub fn drain(self: *Pool) void {
        self.mutex.lock();
        self.accepting = false;
        while (self.busy != 0 or self.tasks.items.len != 0) self.idle_cond.wait(&self.mutex);
        self.mutex.unlock();
    }

    pub fn shutdown(self: *Pool) void {
        self.mutex.lock();
        self.closing = true;
        self.mutex.unlock();
        self.cond.broadcast();
        for (self.threads) |t| t.join();
        self.threads = &.{};
        self.tasks.deinit(self.alloc);
        self.alloc.free(self.threads_storage);
    }

    fn waitWhile(p: *Pool, m: *std.Thread.Mutex, pred: fn (*Pool) bool) void {
        while (pred(p)) m.wait();
    }

    fn worker(p: *Pool) void {
        var out_local: Task = undefined;
        while (true) {
            p.mutex.lock();
            while (true) {
                if (p.tasks.items.len > 0) {
                    out_local = p.tasks.orderedRemove(0);
                    p.busy += 1;
                    p.mutex.unlock();
                    break;
                }
                if (p.closing) {
                    p.mutex.unlock();
                    return;
                }
                p.cond.wait(&p.mutex);
            }
            (out_local.run)(out_local.ptr);
            p.mutex.lock();
            p.busy -= 1;
            if (p.busy == 0 and p.tasks.items.len == 0) p.idle_cond.signal();
            p.mutex.unlock();
        }
    }
};

test "pool executes and drains" {
    const ctx = struct {
        var hits: usize = 0;
        fn run(_: *anyopaque) void {
            std.Thread.sleep(std.time.ns_per_ms * 2);
            _ = @atomicRmw(usize, &hits, .Add, 1, .monotonic);
        }
        fn task() Task {
            return .{ .ptr = undefined, .run = run };
        }
    };
    var p = Pool{ .alloc = std.testing.allocator };
    try p.start(4);
    defer p.shutdown();
    var i: usize = 0;
    while (i < 8) : (i += 1) try p.submit(ctx.task());
    p.drain();
    try std.testing.expectEqual(@as(usize, 8), @atomicLoad(usize, &ctx.hits, .monotonic));
    try std.testing.expectEqual(@as(usize, 0), p.pending());
    try std.testing.expectError(error.ShuttingDown, p.submit(ctx.task()));
}
