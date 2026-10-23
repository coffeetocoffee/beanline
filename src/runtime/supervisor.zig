const std = @import("std");
const job = @import("../core/job.zig");
const registry = @import("../core/registry.zig");
const broker_mod = @import("../broker/broker.zig");
const postgres = @import("../broker/postgres.zig");
const redis = @import("../broker/redis.zig");
const queue_mod = @import("queues.zig");
const pool_mod = @import("pool.zig");
const config_mod = @import("../config.zig");
const metrics_mod = @import("../obs/metrics.zig");
const logs_mod = @import("../obs/logs.zig");
const otel_mod = @import("../obs/otel.zig");
const dash_auth = @import("../dash/auth.zig");
const dash_sse = @import("../dash/sse.zig");
const dash_server = @import("../dash/server.zig");

var g_stop = std.atomic.Value(bool).init(false);

/// The demo kind: accepts any JSON payload and does nothing. Registered
/// automatically so a fresh worker has something to run and a fresh dashboard
/// has something to enqueue.
const demo_kind = job.Kind(std.json.Value, error{}).new(.{
    .name = "demo.noop",
    .queue = "default",
    .handle = struct {
        fn run(_: *job.Context, _: std.json.Value) error{}!void {}
    }.run,
});

fn onCtrl(ctrl: u32) callconv(.C) i32 {
    if (ctrl <= 4) {
        g_stop.store(true, .seq_cst);
        return 1;
    }
    return 0;
}

fn onSig(_: i32) callconv(.C) void {
    g_stop.store(true, .seq_cst);
}

fn installSignals() void {
    if (@import("builtin").os.tag == .windows) {
        const k32 = struct {
            pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.C) i32, add: u32) u32;
        };
        _ = k32.SetConsoleCtrlHandler(onCtrl, 1);
    } else {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = onSig },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}

fn isLoopback(bind: []const u8) bool {
    const colon = std.mem.lastIndexOfScalar(u8, bind, ':') orelse return false;
    const host = bind[0..colon];
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "localhost");
}

fn computeSecureCookies(cfg: config_mod.Config) bool {
    if (cfg.dashboard_secure_cookie) |explicit| return explicit;
    return cfg.dashboard_tls or isLoopback(cfg.dashboard_bind);
}

pub const App = struct {
    alloc: std.mem.Allocator,
    reg: registry.Registry,
    cfg: config_mod.Config,
    metrics: metrics_mod.Metrics,
    log: logs_mod.Logger,
    tracer: otel_mod.Tracer,
    auth: dash_auth.Auth,
    bus: dash_sse.Bus,
    queue_names: std.ArrayList([]const u8) = undefined,
    queue_conc: std.ArrayList(u32) = undefined,

    pub fn init(alloc: std.mem.Allocator) App {
        const cfg = config_mod.load();
        return initWithConfig(alloc, cfg);
    }

    pub fn initWithConfig(alloc: std.mem.Allocator, cfg: config_mod.Config) App {
        var app = App{
            .alloc = alloc,
            .reg = registry.Registry.init(alloc),
            .cfg = cfg,
            .metrics = metrics_mod.Metrics.initWithLimits(alloc, .{
                .max_kinds = cfg.metrics_max_kinds,
                .max_queues = cfg.metrics_max_queues,
            }),
            .log = logs_mod.Logger.init(std.io.getStdErr()),
            .tracer = otel_mod.Tracer.init(alloc, cfg.otel_endpoint),
            .auth = dash_auth.Auth.init(alloc, cfg.dashboard_auth_secret, cfg.dashboard_readonly),
            .bus = dash_sse.Bus.init(alloc),
            .queue_names = std.ArrayList([]const u8).init(alloc),
            .queue_conc = std.ArrayList(u32).init(alloc),
        };
        app.log.log_payload = cfg.log_payload;
        app.auth.oidc = cfg.oidc;
        cfg.queueConcurrency(&app.queue_names, &app.queue_conc) catch {};
        for (cfg.dashboard_users) |u| app.auth.addUser(u) catch {};
        for (cfg.dashboard_keys) |k| app.auth.addKey(k) catch {};
        return app;
    }

    pub fn deinit(self: *App) void {
        self.reg.deinit();
        self.metrics.deinit();
        self.tracer.deinit();
        self.auth.deinit();
        self.bus.deinit();
        self.queue_names.deinit();
        self.queue_conc.deinit();
        self.log.deinit();
    }

    /// Register a job kind. The kind carries its own payload schema, retry
    /// classification and backoff, so the runtime needs no per-kind
    /// configuration and no name-based error matching.
    pub fn register(self: *App, k: anytype) !void {
        try self.reg.register(registry.entryFor(@TypeOf(k), k));
    }

    fn envOpt(self: *App, name: []const u8) !?[]u8 {
        const v = std.process.getEnvVarOwned(self.alloc, name) catch |e| {
            if (e == error.EnvironmentVariableNotFound) return null;
            return e;
        };
        if (v.len == 0) {
            self.alloc.free(v);
            return null;
        }
        return v;
    }

    fn openBroker(self: *App) !broker_mod.Broker {
        if (try self.envOpt("BEANLINE_DATABASE_URL")) |dsn| {
            defer self.alloc.free(dsn);
            const p = try postgres.open(self.alloc, dsn, self.cfg.aging_interval_ms);
            return postgres.toBroker(p);
        }
        if (try self.envOpt("BEANLINE_REDIS_URL")) |url| {
            defer self.alloc.free(url);
            const r = try redis.open(self.alloc, url, self.cfg.aging_interval_ms);
            return redis.toBroker(r);
        }
        // fall back to the loaded config
        if (self.cfg.dsn.len > 0) {
            const p = try postgres.open(self.alloc, self.cfg.dsn, self.cfg.aging_interval_ms);
            return postgres.toBroker(p);
        }
        if (self.cfg.redis_url.len > 0) {
            const r = try redis.open(self.alloc, self.cfg.redis_url, self.cfg.aging_interval_ms);
            return redis.toBroker(r);
        }
        return error.NoBackendConfigured;
    }

    /// Public accessor for tooling that drives the broker directly (the bench
    /// harness). Prefer the queue loop in `run()` for normal worker duties.
    pub fn openBrokerPublic(self: *App) !broker_mod.Broker {
        return self.openBroker();
    }

    /// Run worker roles (queue loops). If cfg.dashboard_enabled, also serves
    /// the dashboard from this process.
    pub fn run(self: *App) !u8 {
        if (self.reg.get("demo.noop") == null) {
            try self.register(demo_kind);
        }

        const br = self.openBroker() catch |e| {
            self.log.err("worker: cannot open backend ({s}); set BEANLINE_DATABASE_URL or BEANLINE_REDIS_URL", .{@errorName(e)});
            return 1;
        };
        defer br.deinit();

        g_stop.store(false, .seq_cst);
        installSignals();

        // Build per-queue configs from the loaded config.
        var cfgs = std.ArrayList(queue_mod.QueueConfig).init(self.alloc);
        defer cfgs.deinit();
        self.queue_names.clearRetainingCapacity();
        self.queue_conc.clearRetainingCapacity();
        self.cfg.queueConcurrency(&self.queue_names, &self.queue_conc) catch {};
        for (self.queue_names.items, self.queue_conc.items) |qn, qc| {
            try cfgs.append(.{ .name = qn, .concurrency = qc, .lease_ms = self.cfg.lease_ms });
        }
        if (cfgs.items.len == 0) {
            try cfgs.append(.{ .name = "default", .concurrency = self.cfg.default_concurrency, .lease_ms = self.cfg.lease_ms });
        }

        var pool = pool_mod.Pool{ .alloc = self.alloc };
        var total_slots: usize = 8;
        for (cfgs.items) |c| total_slots += c.concurrency;
        try pool.start(total_slots);
        defer pool.shutdown();

        var owner = try queue_mod.Owner.init(self.alloc, br, &self.reg, &pool, .{
            .queues = cfgs.items,
            .worker_name = "beanline",
            .retry = self.cfg.defaultBackoff(),
            .metrics = &self.metrics,
            .sandbox_enabled = self.cfg.sandbox_enabled,
            .sandbox_memory_mb = self.cfg.sandbox_memory_mb,
            .sandbox_cpu_percent = self.cfg.sandbox_cpu_percent,
            .sandbox_timeout_ms = self.cfg.sandbox_timeout_ms,
        });
        defer owner.deinit();

        // Optional dashboard tier in-process.
        var server_storage: ?dash_server.Server = null;
        if (self.cfg.dashboard_enabled) {
            var srv = dash_server.Server.initWithKinds(
                self.alloc,
                br,
                &self.auth,
                &self.bus,
                &self.metrics,
                &self.log,
                self.queue_names.items,
                self.cfg.dashboard_bind,
                self.cfg.dashboard_readonly,
                computeSecureCookies(self.cfg),
                &self.reg,
                self.cfg.max_attempts,
            );
            srv.start() catch |e| {
                self.log.err("dashboard: failed to start ({s})", .{@errorName(e)});
                return 1;
            };
            server_storage = srv;
        }
        defer if (server_storage) |*s| s.stopServer();

        var worker_id_buf: [128]u8 = undefined;
        const worker_id = std.fmt.bufPrint(&worker_id_buf, "beanline:{d}", .{std.time.milliTimestamp()}) catch "beanline";
        self.log.worker_id = worker_id;
        self.log.info("worker: beanline worker running backend={s} (ctrl+c to stop)", .{br.capabilities().named_backend});

        var depth_tick_ms: i64 = 0;
        var retention_tick_ms: i64 = 0;
        const retention_interval_ms: i64 = 60 * 60 * 1000; // 1 hour
        while (!g_stop.load(.seq_cst)) {
            if (owner.inflight() == 0 and g_stop.load(.seq_cst)) break;
            const t0 = std.time.microTimestamp();
            const n = owner.tick(std.time.milliTimestamp()) catch |e| {
                self.log.warn("worker tick: {s}", .{@errorName(e)});
                std.time.sleep(250);
                continue;
            };
            const dt_us: u64 = @intCast(@max(0, std.time.microTimestamp() - t0));
            if (n > 0) {
                self.metrics.observeClaim(dt_us / @max(1, n));
                self.bus.publish(.{ .kind = "claimed", .queue = cfgs.items[0].name, .job_id = 0, .at_ms = std.time.milliTimestamp() });
            }
            // periodic depth gauge refresh (cheap, ~1/s)
            const now_ms = std.time.milliTimestamp();
            if (now_ms - depth_tick_ms > 1000) {
                depth_tick_ms = now_ms;
                for (cfgs.items) |c| {
                    var d = broker_mod.Depth{};
                    br.depth(c.name, &d) catch {
                        continue;
                    };
                    self.metrics.setQueueDepthFull(c.name, @intCast(d.available), @intCast(d.scheduled), @intCast(d.running), @intCast(d.dead), @intCast(d.completed), @intCast(d.cancelled));
                }
            }
            std.time.sleep(if (owner.inflight() == 0) 20 else 5);
            // periodic retention sweep (bounded, cheap)
            if (now_ms - retention_tick_ms > retention_interval_ms) {
                retention_tick_ms = now_ms;
                _ = br.retention(self.alloc, self.cfg.retention_completed_ms, self.cfg.retention_events_ms) catch |e| {
                    self.log.warn("retention sweep: {s}", .{@errorName(e)});
                };
            }
        }

        // Graceful drain: stop claiming, wait for running handlers.
        // Server sockets close first via the defer above ordering (stopServer
        // runs before drain completes? no — defer runs at scope exit, so we
        // stop the server explicitly here before draining).
        if (server_storage) |*s| {
            s.stopServer();
            server_storage = null;
        }
        owner.signalStop();
        const drain_deadline = std.time.milliTimestamp() + @as(i64, @intCast(self.cfg.drain_timeout_ms));
        while (owner.inflight() > 0 and std.time.milliTimestamp() < drain_deadline) {
            _ = owner.tick(std.time.milliTimestamp()) catch break;
            std.time.sleep(2);
        }

        self.log.info("worker: drained, exiting", .{});
        return 0;
    }

    /// Dashboard-only tier (`beanline server`): no queue loops, just the
    /// control server. Still needs a broker connection for reads.
    pub fn runServer(self: *App) !u8 {
        const br = self.openBroker() catch |e| {
            self.log.err("server: cannot open backend ({s}); set BEANLINE_DATABASE_URL or BEANLINE_REDIS_URL", .{@errorName(e)});
            return 1;
        };
        defer br.deinit();

        g_stop.store(false, .seq_cst);
        installSignals();

        self.queue_names.clearRetainingCapacity();
        self.queue_conc.clearRetainingCapacity();
        self.cfg.queueConcurrency(&self.queue_names, &self.queue_conc) catch {};

        var srv = dash_server.Server.initWithKinds(
            self.alloc,
            br,
            &self.auth,
            &self.bus,
            &self.metrics,
            &self.log,
            self.queue_names.items,
            self.cfg.dashboard_bind,
            self.cfg.dashboard_readonly,
            computeSecureCookies(self.cfg),
            &self.reg,
            self.cfg.max_attempts,
        );
        srv.start() catch |e| {
            self.log.err("server: failed to start ({s})", .{@errorName(e)});
            return 1;
        };
        defer srv.stopServer();

        self.log.info("server: dashboard serving on {s} (ctrl+c to stop)", .{self.cfg.dashboard_bind});
        while (!g_stop.load(.seq_cst)) {
            std.time.sleep(50);
            // keep depth gauges fresh for the metrics endpoint
            var d = broker_mod.Depth{};
            for (self.queue_names.items) |q| {
                br.depth(q, &d) catch continue;
                self.metrics.setQueueDepthFull(q, @intCast(d.available), @intCast(d.scheduled), @intCast(d.running), @intCast(d.dead), @intCast(d.completed), @intCast(d.cancelled));
            }
        }
        return 0;
    }
};
