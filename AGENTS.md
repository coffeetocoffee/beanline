# beanline — agent notes

Zig 0.14.1 job queue (Postgres/Redis broker, cron scheduler, dashboard). Tests
live inline in `src/`; `zig build test` = 146 unit + fuzz-target tests
(`tests/fuzz/all.zig`).
Shared contract suite (tests/contract/all.zig): 60 cases run identically against
both backends; `zig build test-contract` (needs BEANLINE_TEST_DSN /
BEANLINE_TEST_REDIS_URL).

## Kind API (changed in 0.8.0)

A kind declares its own payload type and its own error set. There is no
global `Args` struct and no runtime error-name matching any more.

```zig
const send_email = beanline.Kind(SendArgs, SendError).new(.{
    .name = "emails.send",
    .errors = .{ .retryable = &.{error.SmtpTransient}, .dead_on = &.{error.AddressInvalid} },
    .handle = struct {
        fn run(ctx: *beanline.JobContext, a: SendArgs) SendError!void { ... }
    }.run,
});
try app.register(send_email);
```

- `Kind.new` is comptime-evaluated and runs the partition check, so an
  unclassified error is a compile error.
- The spec must be comptime-known. `Kind.new` takes a `comptime` parameter,
  so a spec built at runtime does not compile (by design: a kind's schema,
  policy and handler are compile-time facts).
- The runtime never parses a payload and never matches an error name: the
  kind's `runner` does both, with the classification baked in.
- A payload that does not fit the schema is `BadPayload`, classified dead on
  the first attempt.

Do not reintroduce a shared payload struct or a name-based error list. Both
were the reason the queue could only run one payload shape and why every
error was retryable.

## Commands

```
zig build -Doptimize=ReleaseSafe   # build
zig build test                     # 146 tests (Linux/Windows only, see below)
zig build test-unit-probe          # installs zig-out/bin/test, run it directly
zig build test-fuzz-install        # installs zig-out/bin/test-fuzz-tests
zig build fuzz-gate                # 3 fuzz targets, 20k iters each
```

Local zig: `C:\Users\Rizqi\tools\zig-x86_64-windows-0.14.1` (not on PATH).

## CI gotcha: never RUN a test binary via `zig build` on macOS

Zig 0.14.1's **build runner deadlocks on macos-14 arm64** when used to execute a
test binary. It emits nothing and the job burns the full timeout. Compiling is
fine; only running hangs.

| how the binary runs | macos-14 | ubuntu |
|---|---|---|
| executed directly | ~10s, passes | passes |
| `zig build test` / `test-fuzz` | hangs, no output | 6s |

So CI compiles with the build runner and executes the binaries directly
(steps "test unit suite" / "test fuzz target unit tests", each watchdog-guarded
at 300s). Both are still required to pass; coverage is unchanged. If you ever
bump Zig or re-add macos-14 to a `zig build test` step, re-test this first.

## Dead ends — do not re-investigate

Three commits chased this hang and all were wrong: `b693554` (cron impossible
dates), `02ca13c` (metrics depth OOB), `1bf4458` (suite serialization). They
were plausible but unrelated; the signal was always "all tests pass, then
silence", which means the runner, not the tests.

Lessons that cost the most time:
- **Split CI commands into separate steps before theorising.** Three commands in
  one `run:` block make a hang unattributable — the runner prints nothing until
  it finishes.
- **A stalled step that moves when you change the build graph is the tell.**
  That is what proved the runner (not the tests) was at fault.
- Don't verify macOS behaviour from a Windows run. Local green says nothing
  about the runner hang.

## Known, unrelated

- `zig build test` on Windows emits noisy `Access is denied` stack traces: the
  dash server logs to stderr from its thread. Pre-existing, exit code 0.
- `src/dash/server.zig` uses a 100ms `poll` accept loop (not a self-connect
  wakeup). More deterministic; not the cause of any hang.

## Dead ends — Redis and bench (do not re-derive)

- **"RedisCommand" on every operation means a Redis older than 5.0.** The Lua
  scripts call `redis.call('TIME')` and then write; before Redis 5.0
  (effects replication) that is rejected. The server's message is now logged
  and the version is checked at connect time, so this should not come up
  again. If it does, look at the logged server message first.
- **A bench that claims only a handful of jobs was connection contention, not
  a slow broker.** A claim costs about ten times an enqueue, so on one shared
  connection the producers starve the workers. The bench now gives each
  worker its own connection. Do not "optimise" that back to a single
  connection.
- **The bench's `--rate` schedules the next slot from the moment the producer
  actually enqueued.** A running total drifts ahead of the wall clock and
  never becomes due, which is how the limiter used to enqueue nothing at all.
  `rateDecision` is a pure function so this stays testable.

## Permanent CI Requirements (ALWAYS REMEMBER)

1. **Contract suite must build and test on all three OSes** (macOS, Ubuntu, Windows) with both Postgres and Redis backends.
   - The GitHub Actions `contract` job runs on `ubuntu-latest` with postgres:16-alpine and redis:7-alpine services.
   - Contract tests require `BEANLINE_TEST_DSN` and `BEANLINE_TEST_REDIS_URL` env vars + `BEANLINE_CONTRACT_REQUIRED=1`.
   - Build step: `zig build test-contract-install` then run `./zig-out/bin/test-contract` directly (NOT via `zig build test-contract`).

2. **Always run `zig fmt --check src tests build.zig` before committing** — the CI fmt check step runs this on all three OSes and will fail the build if formatting is off. `src/dash/server.zig` has had formatting issues before; run `zig fmt src/dash/server.zig` to fix.

## Mandatory Pre-Push Checklist (ALWAYS RUN)

Before any commit/push, run ALL of the following locally and ensure they pass:

```
# 1. Build release
zig build -Doptimize=ReleaseSafe

# 2. Format check
zig fmt --check src tests build.zig

# 3. Unit tests (all platforms)
zig build test

# 4. Contract suite - PostgreSQL (requires local Postgres + BEANLINE_TEST_DSN)
BEANLINE_TEST_DSN="postgres://..." BEANLINE_CONTRACT_REQUIRED=1 zig build test-contract-install
./zig-out/bin/test-contract

# 5. Contract suite - Redis (requires local Redis + BEANLINE_TEST_REDIS_URL)
BEANLINE_TEST_REDIS_URL="redis://..." BEANLINE_CONTRACT_REQUIRED=1 zig build test-contract-install
./zig-out/bin/test-contract
```

CI runs these on **all three OSes** (macOS, Ubuntu, Windows). Local green on Windows does NOT guarantee macOS/Ubuntu pass.
