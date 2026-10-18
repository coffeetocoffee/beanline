const std = @import("std");
const conn = @import("../broker/pg/conn.zig");

const DEFAULT_DSN = "postgres://postgres@127.0.0.1:5432/postgres";

fn report(c: *conn.Conn, what: []const u8) void {
    if (c.lastError()) |e| {
        std.debug.print("migrate: {s}: {s} [{s}]\n", .{ what, e.message, e.sqlstate });
    } else {
        std.debug.print("migrate: {s}\n", .{what});
    }
}

pub fn run(alloc: std.mem.Allocator) !u8 {
    const dsn_env = std.process.getEnvVarOwned(alloc, "BEANLINE_DATABASE_URL") catch null;
    defer if (dsn_env) |d| alloc.free(d);
    const dsn = dsn_env orelse DEFAULT_DSN;

    const cfg = conn.parseDsn(alloc, dsn) catch |e| {
        std.debug.print("migrate: bad DSN ({s}): {s}\n", .{ @errorName(e), dsn });
        return 1;
    };
    defer cfg.free(alloc);

    var c = conn.Conn.connect(alloc, cfg) catch |e| {
        std.debug.print("migrate: connect failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer c.deinit();

    c.execSimple("SELECT pg_advisory_lock(722001)") catch {
        report(&c, "advisory lock");
        return 1;
    };
    c.execSimple(
        \\CREATE TABLE IF NOT EXISTS beanline_schema_migrations (
        \\  version TEXT PRIMARY KEY,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
        \\)
    ) catch {
        report(&c, "create schema_migrations");
        return 1;
    };

    var applied = std.StringHashMap(void).init(alloc);
    defer applied.deinit();

    var applied_rows = c.query("SELECT version FROM beanline_schema_migrations", &.{}) catch {
        report(&c, "read applied migrations");
        return 1;
    };
    defer applied_rows.deinit();
    for (applied_rows.rows) |row| {
        if (row[0]) |version| try applied.put(version, {});
    }

    var dir = std.fs.cwd().openDir("migrations", .{ .iterate = true }) catch {
        std.debug.print("migrate: cannot open ./migrations (run from the project root)\n", .{});
        return 1;
    };
    defer dir.close();

    var names = std.ArrayList([]const u8).init(alloc);
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit();
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try names.append(try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var count: usize = 0;
    for (names.items) |name| {
        if (applied.contains(name)) continue;
        const content = dir.readFileAlloc(alloc, name, 32 * 1024 * 1024) catch |e| {
            std.debug.print("migrate: cannot read {s}: {s}\n", .{ name, @errorName(e) });
            return 1;
        };
        defer alloc.free(content);

        c.execSimple("BEGIN") catch {
            report(&c, "begin");
            return 1;
        };
        c.execSimple(content) catch {
            report(&c, name);
            c.rollbackBestEffort();
            return 1;
        };
        var rec = c.query("INSERT INTO beanline_schema_migrations (version) VALUES ($1)", &.{name}) catch {
            report(&c, name);
            c.rollbackBestEffort();
            return 1;
        };
        rec.deinit();
        c.execSimple("COMMIT") catch {
            report(&c, name);
            return 1;
        };
        std.debug.print("migrate: applied {s}\n", .{name});
        count += 1;
    }

    std.debug.print("migrate: {d} applied, {d} total, up to date\n", .{ count, names.items.len });
    return 0;
}
