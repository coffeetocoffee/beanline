const std = @import("std");
const cli = @import("cli/main.zig");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub const Job = @import("core/job.zig").Job;
pub const Args = @import("core/job.zig").Args;
pub const JobContext = @import("core/job.zig").Context;
/// Low-level building blocks, exported so the fuzz targets in tests/fuzz can
/// reach them without importing files outside their module path.
pub const Resp = @import("broker/resp/client.zig");
pub const CronSchedule = @import("sched/cron.zig").Schedule;
pub const PgProto = @import("broker/pg/proto.zig");
pub const App = @import("runtime/supervisor.zig").App;
pub const Broker = @import("broker/broker.zig").Broker;
pub const RetryPolicy = @import("core/errors.zig").RetryPolicy;
pub const Backoff = @import("runtime/backoff.zig").Backoff;
pub const Cron = @import("sched/cron.zig").Schedule;
pub const Zone = @import("sched/tz.zig").Zone;
pub const FromLocal = @import("sched/tz.zig").FromLocal;
pub const Scheduler = @import("sched/scheduler.zig").Scheduler;
pub const ScheduleEntry = @import("sched/scheduler.zig").Entry;
pub const Lock = @import("sched/leader.zig").Lock;
pub const Owner = @import("runtime/queues.zig").Owner;
pub const QueueConfig = @import("runtime/queues.zig").QueueConfig;
pub const Pool = @import("runtime/pool.zig").Pool;
pub const Limiter = @import("runtime/limiter.zig").Limiter;
pub const Config = @import("config.zig").Config;
pub const Metrics = @import("obs/metrics.zig").Metrics;
pub const Logger = @import("obs/logs.zig").Logger;
pub const Tracer = @import("obs/otel.zig").Tracer;
pub const DashAuth = @import("dash/auth.zig").Auth;
pub const DashRest = @import("dash/rest.zig").Rest;
pub const DashBus = @import("dash/sse.zig").Bus;
pub const DashServer = @import("dash/server.zig").Server;
pub const Bench = @import("cli/bench.zig");

pub fn main() u8 {
    return cli.main();
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("core/registry.zig");
    _ = @import("core/errors.zig");
    _ = @import("runtime/backoff.zig");
    _ = @import("runtime/fairness.zig");
    _ = @import("runtime/pool.zig");
    _ = @import("runtime/limiter.zig");
    _ = @import("runtime/queues.zig");
    _ = @import("runtime/worker_e2e_test.zig");
    _ = @import("runtime/supervisor.zig");
    _ = @import("sched/cron.zig");
    _ = @import("sched/civil.zig");
    _ = @import("sched/tzstring.zig");
    _ = @import("sched/tz.zig");
    _ = @import("sched/scheduler.zig");
    _ = @import("sched/leader.zig");
    _ = @import("sched/promote_task.zig");
    _ = @import("broker/broker.zig");
    _ = @import("broker/pg/proto.zig");
    _ = @import("broker/pg/scram.zig");
    _ = @import("broker/pg/conn.zig");
    _ = @import("broker/postgres.zig");
    _ = @import("broker/resp/client.zig");
    _ = @import("broker/redis.zig");
    _ = @import("config.zig");
    _ = @import("obs/metrics.zig");
    _ = @import("obs/logs.zig");
    _ = @import("obs/otel.zig");
    _ = @import("dash/auth.zig");
    _ = @import("dash/sse.zig");
    _ = @import("dash/rest.zig");
    _ = @import("dash/server.zig");
    _ = @import("cli/bench.zig");
    _ = @import("dash/smoke_test.zig");
}
