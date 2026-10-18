# Beanline

A job queue and background worker system in Zig. One binary, two backends
(Postgres or Redis), one set of semantics.

> Queues without the wait.

- **Transactional enqueue** in Postgres mode: enqueue inside your transaction,
  so "the row changed and the job exists" is atomic. No dual-write bug class.
- **Reliable execution**: leases, heartbeats, fencing tokens, retries with
  backoff and jitter, dead letters, cancellation, graceful shutdown.
- **Cron scheduler**: timezone aware, DST correct, misfire policies, leader
  election, idempotent run deduplication.
- **Embedded dashboard**: REST + live SSE + Prometheus metrics, with auth on by
  default (local users, scoped API keys, OIDC SSO), served from the same binary.
- **No GC, no runtime dependencies** beyond the database you already run.

## Status

Design and implementation are tracked in the milestone table of
[docs/architecture.md](docs/architecture.md) (M0 to M6). The current tree
implements the Postgres and Redis brokers, the scheduler, the runtime, the
dashboard, the CLI, the bench harness, and the fuzz targets.

## Build

Requires Zig 0.14.x.

```sh
zig build                 # binary in zig-out/bin
zig build test            # unit + fuzz-target tests
zig build fuzz-gate       # deterministic fuzz gate (CI sized)
zig build -Doptimize=ReleaseSafe
```

## Quick start

```sh
# 1. a database
docker compose up -d postgres

# 2. schema
export BEANLINE_DATABASE_URL='postgres://beanline:beanline@localhost:5432/beanline'
beanline migrate

# 3. work
beanline worker

# 4. dashboard (separate terminal)
BEANLINE_DASH_USERS='ops:change-me:admin' beanline server
open http://127.0.0.1:9484
```

Redis works the same way with `BEANLINE_REDIS_URL=redis://localhost:6379`.

## CLI

```
beanline version                    print the version
beanline migrate                    apply pending migrations (forward only)
beanline worker                     run the worker tier
beanline server                     run the dashboard/API tier
beanline bench [options]            workload generator and benchmark gate
```

## Embedding

```zig
const beanline = @import("beanline");

pub fn main(alloc: std.mem.Allocator) !u8 {
    var app = try beanline.App.init(alloc);
    defer app.deinit();
    try app.register(.{
        .name = "emails.send",
        .queue = "mailers",
        .handle = struct {
            fn run(ctx: *beanline.JobContext, args: beanline.Args) !void {
                _ = ctx;
                _ = args;
            }
        }.run,
    });
    return app.run();
}
```

## Configuration

Everything is configured through `BEANLINE_*` environment variables. See
[docs/configuration.md](docs/configuration.md) for the full list and
[docs/dashboard-auth.md](docs/dashboard-auth.md) for the auth surface.

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The design document: semantics, data model, backends, roadmap |
| [docs/api.md](docs/api.md) | REST API and dashboard endpoints |
| [docs/configuration.md](docs/configuration.md) | Every environment variable |
| [docs/dashboard-auth.md](docs/dashboard-auth.md) | Users, API keys, OIDC SSO |
| [docs/benchmarks.md](docs/benchmarks.md) | Bench harness, reference files, the release gate |
| [docs/soak.md](docs/soak.md) | Soak harness and the error budget |
| [docs/runbooks/](docs/runbooks/) | Operational runbooks |

## Operations

Runbooks for the failure modes that actually happen:
[stuck queue](docs/runbooks/stuck-queue.md),
[dead surge](docs/runbooks/dead-surge.md),
[leader flapping](docs/runbooks/leader-flapping.md),
[lease storm](docs/runbooks/lease-storm.md),
[database failover](docs/runbooks/db-failover.md),
[schema rollback](docs/runbooks/schema-rollback.md),
[poison job](docs/runbooks/poison-job.md).

## License

MIT.
