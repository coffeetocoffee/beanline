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
