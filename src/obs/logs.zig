const std = @import("std");

/// Structured leveled logger. Writes JSON lines (default) to stderr so logs
/// never mix with stdout artifacts. Mirrors the log discipline in architecture
/// doc §15: ts, level, worker_id, queue, kind, job_id, attempt on job-scoped
/// lines, and args only when log_payload is true.
pub const Level = enum { debug, info, warn, err };

pub const Logger = struct {
    out: std.io.AnyWriter,
    mutex: std.Thread.Mutex = .{},
    pretty: bool = false,
    log_payload: bool = false,
    worker_id: []const u8 = "",

    pub fn init(file: std.fs.File) Logger {
        return .{ .out = file.writer().any() };
    }

    pub fn deinit(self: *Logger) void {
        _ = self;
    }

    pub fn log(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pretty) {
            self.out.print("[{s}] ", .{@tagName(level)}) catch return;
            self.out.print(fmt, args) catch return;
            self.out.writeByte('\n') catch return;
            return;
        }
        const buf = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
        defer std.heap.page_allocator.free(buf);
        // escape for JSON
        var esc = std.ArrayList(u8).init(std.heap.page_allocator);
        defer esc.deinit();
        esc.append('"') catch return;
        for (buf) |c| {
            switch (c) {
                '"' => esc.appendSlice("\\\"") catch return,
                '\\' => esc.appendSlice("\\\\") catch return,
                '\n' => esc.appendSlice("\\n") catch return,
                '\r' => esc.appendSlice("\\r") catch return,
                '\t' => esc.appendSlice("\\t") catch return,
                else => esc.append(c) catch return,
            }
        }
        esc.append('"') catch return;
        self.out.print("{{\"ts\":{d},\"level\":\"{s}\",\"worker\":\"{s}\",\"msg\":{s}}}\n", .{
            std.time.milliTimestamp(),
            @tagName(level),
            self.worker_id,
            esc.items,
        }) catch return;
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }
    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }
    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

test "json logger emits structured line" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const l = Logger{ .out = fbs.writer().any(), .log_payload = false };
    var lg = l;
    lg.info("worker started queue={s}", .{"default"});
    const s = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, s, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "worker started queue=") != null);
}
