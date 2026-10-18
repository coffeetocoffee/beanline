# Soak testing and the error budget

A soak run answers one question: does the queue keep its promises for a long
period under continuous load, without drifting into failure modes that only
show up after a day?

## Running a soak

```sh
export BEANLINE_DATABASE_URL='postgres://...'
./scripts/soak.sh 168          # one week
```

The harness starts a worker tier and a dashboard tier, samples `/metrics` once
a minute, and checks each sample against the budget below. It writes a JSON
summary to `soak-report.json` and exits non-zero if any budget was blown.

| Variable | Default | Meaning |
|---|---|---|
| `SOAK_HOURS` | `168` | Duration (also accepted as the first argument) |
| `SOAK_WORKERS` | `8` | Worker count (the harness uses the binary's own concurrency setting) |
| `SOAK_REPORT` | `soak-report.json` | Report path |
| `MAX_DEAD_RATE` | `0.001` | Dead jobs per completed job |
| `MAX_REAP_RATE` | `0.001` | Reaped jobs per completed job |
| `MAX_P99_MS` | `250` | Claim p99 ceiling |
| `MAX_QUEUE_AGE_MS` | `60000` | Oldest pending job age |

## The error budget

A week-long soak is not expected to be perfect; it is expected to stay inside
a budget that says "the failure modes we care about did not happen".

| Signal | Budget | Why |
|---|---|---|
| Dead jobs / completed jobs | <= 0.001 | A permanent failure class is supposed to be rare. A rising ratio means a handler or a downstream broke. |
| Reaped jobs / completed jobs | <= 0.001 | Reaping means a lease expired under a live worker: a heartbeat failure or a lease shorter than the work. |
| Claim p99 | <= 250 ms | The queue latency a user waits before work starts. |
| Oldest pending age | <= 60 s | A queue that stops draining is a stuck queue, not a slow one. |
| Lost jobs | 0 | The one hard failure. A job that was accepted and never completed is a correctness bug, not a budget item. |

The lost-job count is the one that cannot be traded off. At the end of a soak,
the number of enqueued jobs must equal completed + dead + discarded + cancelled
+ still-pending.

## What a soak is for

A soak finds the bugs that unit tests and short chaos runs do not:

- **Memory growth.** A leak shows up as a slowly rising RSS. A week is the
  shortest run where a small per-job leak becomes visible.
- **Lease and heartbeat drift.** Clock behaviour, connection pool churn, and
  slow queries only interact badly over hours.
- **Leader flapping.** Long gaps between leader acquisitions, and the
  misfire policies that hide them.
- **Retention and growth.** Completed-job cleanup must keep the table from
  growing without bound, or the claim index degrades.
- **Backlog behaviour.** A producer that suddenly submits 100x the normal rate
  should see backpressure, not an unbounded queue.

## Running the chaos variants

The soak harness is the steady state; the chaos suites in the architecture
document (§21) are the adversarial state. Run both before a release:

- `kill -9` a worker mid-job: the job must be reaped and re-run, never lost.
- Partition a worker from the broker while it holds a lease: the job must be
  reaped and any late write must be rejected by the fencing token.
- Stall the database mid-claim: the worker must park and recover, not lose the
  job.
- Restart the leader repeatedly: cron fires must be idempotent (no duplicate
  jobs for the same scheduled instant).

## Interpreting a failure

When the budget is blown, do not immediately restart everything; the state at
the moment of failure is the evidence.

1. Save `/metrics` output, the worker logs, and the dashboard's job list.
2. Find the first minute where the budget was exceeded: earlier samples are the
   steady state, later ones are the consequence.
3. If the first violation is a reaped-job spike, look at the heartbeat
   timeline, not the job. If it is a dead-job spike, look at the failing kind.
4. Reproduce the shape in a shorter run (a chaos test, not another soak) before
   attempting a fix.

## Exit criteria for a release

- 168 h soak with zero lost jobs.
- Dead and reap rates inside the budget for the whole run.
- No memory growth trend (RSS flat within noise after the first hour).
- A chaos suite run with the same binary passes.
