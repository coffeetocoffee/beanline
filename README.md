# Beanline

A job queue and background worker system in Zig. One binary, two backends
(Postgres or Redis), one set of semantics.

> Queues without the wait.

- **Transactional enqueue** in Postgres mode: enqueue inside your transaction,
  so "the row changed and the job exists" is atomic. No dual-write bug class.
- **Per-kind payload schemas and retry policy**: every kind declares its own
  argument type and its own error set. The payload is validated at
  deserialization, and the retry classification is checked by the compiler, so
  an unclassified error is a build error rather than a 3 a.m. retry storm.
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

Each kind declares its own payload type and its own error set, so the payload
schema and the retry classification are compile-time facts.

```zig
const beanline = @import("beanline");

const SendArgs = struct { to: []const u8, subject: []const u8 };
const SendError = error{ SmtpTransient, AddressInvalid };

const send_email = beanline.Kind(SendArgs, SendError).new(.{
    .name = "emails.send",
    .queue = "mailers",
    // Every error the handler can return must land in exactly one class.
    // Forget one and the build fails, instead of the queue burning its whole
    // attempt budget on a permanent failure.
    .errors = .{
        .retryable = &.{ error.SmtpTransient },
        .dead_on = &.{ error.AddressInvalid },
    },
    .handle = struct {
        fn run(ctx: *beanline.JobContext, a: SendArgs) SendError!void {
            _ = ctx;
            _ = a;
        }
    }.run,
});

pub fn main(alloc: std.mem.Allocator) !u8 {
    var app = try beanline.App.init(alloc);
    defer app.deinit();
    try app.register(send_email);
    return app.run();
}
```

Two kinds with different payload shapes run side by side. A payload that does
not fit its kind's schema is a permanent failure: the job dead-letters on its
first attempt instead of being retried until the attempt budget runs out.

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
