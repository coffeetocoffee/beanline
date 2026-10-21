# beanline — agent notes

Zig 0.14.1 job queue (Postgres/Redis broker, cron scheduler, dashboard). Tests
live inline in `src/`; `zig build test` = 137 unit + 10 fuzz (`tests/fuzz/all.zig`).
Shared contract suite (tests/contract/all.zig): 56 cases run identically against
both backends; `zig build test-contract` (needs BEANLINE_TEST_DSN /
BEANLINE_TEST_REDIS_URL).

## Commands

```
zig build -Doptimize=ReleaseSafe   # build
zig build test                     # 140 tests (Linux/Windows only, see below)
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
