const std = @import("std");
const beanline = @import("../beanline.zig");
const migrate = @import("migrate.zig");
const bench = @import("bench.zig");

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = std.process.argsAlloc(alloc) catch {
        std.log.err("failed to read argv", .{});
        return 1;
    };
    defer std.process.argsFree(alloc, argv);

    const stdout = std.io.getStdOut().writer();
    const cmd: []const u8 = if (argv.len > 1) argv[1] else "help";

    if (std.mem.eql(u8, cmd, "version")) {
        stdout.print("beanline {d}.{d}.{d}\n", .{
            beanline.version.major,
            beanline.version.minor,
            beanline.version.patch,
        }) catch return 1;
        return 0;
    }

    if (std.mem.eql(u8, cmd, "migrate")) {
        return migrate.run(alloc) catch 1;
    }

    if (std.mem.eql(u8, cmd, "worker")) {
        var app = beanline.App.init(alloc);
        defer app.deinit();
        return app.run() catch 1;
    }

    if (std.mem.eql(u8, cmd, "server")) {
        var app = beanline.App.init(alloc);
        defer app.deinit();
        // server tier always enables the dashboard regardless of env flag
        app.cfg.dashboard_enabled = true;
        return app.runServer() catch 1;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        return bench.run(alloc, argv) catch 1;
    }

    stdout.print(
        \\beanline - a job queue and background worker system
        \\usage: beanline <command>
        \\  version   print version
        \\  migrate   apply pending SQL migrations (BEANLINE_DATABASE_URL)
        \\  worker    run the worker (drain queues)
        \\  server    run the dashboard/API tier only
        \\  bench     run the workload generator (`beanline bench --help`)
        \\  help      show this help
        \\
    , .{}) catch return 1;
    return 0;
}
