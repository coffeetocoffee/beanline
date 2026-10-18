# Benchmarks

`beanline bench` is the workload generator. It drives the real broker (not a
mock), so the numbers include the database round trips that dominate a real
queue.

## Running a bench

```sh
export BEANLINE_DATABASE_URL='postgres://...'   # or BEANLINE_REDIS_URL

beanline bench --workload noop --duration 120 --warmup 10 \
  --workers 8 --queues 2 --report bench-report.json
```

| Flag | Meaning |
|---|---|
| `--workload noop\|io\|cpu\|flaky\|poison` | Workload shape (see below) |
| `--duration <seconds>` | Measurement window (default 120) |
| `--warmup <seconds>` | Warmup before measuring (default 5) |
| `--workers <n>` | Worker threads (default 4) |
| `--queues <n>` | Number of queues (default 1) |
| `--payload <bytes>` | Args payload size (default 1024) |
| `--rate <n>` | Enqueue rate per second across all producers, 0 = unthrottled |
| `--lease-ms <n>` | Lease duration (default 30000) |
| `--claim-batch <n>` | Jobs claimed per round trip (default 4) |
| `--seed <n>` | PRNG seed, so failure injection is reproducible |
| `--report <path>` | Write a JSON report |
| `--gate` | Compare against the stored reference, fail on a p99 regression |
| `--gate-pct <pct>` | Regression budget (default 5) |
| `--dry-run` | Print the plan and exit without touching a broker |

### Workloads

| Workload | Shape | Exercises |
|---|---|---|
| `noop` | Handler returns immediately | Broker round trip, claim, finish |
| `io` | 20 ms sleep | DB/HTTP bound handlers, concurrency limits |
| `cpu` | ~10 ms of arithmetic | CPU bound handlers, tail latency |
| `flaky` | 10% transient failures | Retry, backoff, jitter, dead-letter path |
| `poison` | 1% permanent failures | Non-retryable classification, dead letters |

### Reported metrics

- `enqueued`, `claimed`, `completed`, `failed (retryable)`, `failed (permanent)`, `errors`
- `claim p50/p99`: time from enqueue to claim (the queue latency users feel)
- `run p50/p99`: handler duration
- `e2e p50/p99`: enqueue to terminal state
- `throughput`: completed jobs per second

## The release gate

```sh
beanline bench --workload noop --duration 120 --workers 8 --queues 2 --gate
```

The gate loads `bench/reference/<backend>-<workload>.json` and fails the run
when the measured claim p99 is more than 5% worse than the reference. A faster
result always passes; a missing reference reports `no reference` and passes
(it is a warning, not a failure, so a new scenario can be introduced without
failing CI).

Regenerate the references on the reference machine:

```sh
./scripts/bench-reference.sh
```

References are hardware- and backend-specific, so they are only meaningful
when regenerated on the same kind of machine. The nightly CI job (03:17 UTC)
runs the same scenario and reports the delta; the gate itself runs only when
the job is scheduled, so ordinary pull requests are not blocked by a noisy
neighbour.

## Targets

From the architecture document (§19), single node, 2023-class hardware, 1 KB
payloads:

| Metric | Postgres mode | Redis mode |
|---|---|---|
| Sustained completes/s | >= 5,000 | >= 25,000 |
| Enqueue to claim p50 / p99 | <= 5 ms / 25 ms | <= 2 ms / 10 ms |
| Claim round trips per job | 1 | 1 |
| Baseline RSS | <= 50 MB | <= 50 MB |
| Heartbeat traffic (1,000 running jobs) | <= 1 tx/s | <= 1 pipeline/s |
| Crash to requeue detection | <= lease (60 s) | <= expires poll (5 s) |
| Cold start | <= 100 ms | <= 100 ms |

**No published numbers yet.** The reference files in `bench/reference/` are
empty on purpose: they must come from a measured run on real hardware with a
real backend, and inventing them would make the gate meaningless. Until a
reference run is recorded and committed, the gate reports `no reference`.

## Known ceilings

- Postgres claim throughput is WAL- and index-bound. Above roughly 10k to 15k
  completions per second per cluster, use Redis mode or shard queues across
  databases.
- Redis mode's durability is Redis durability. Jobs can be lost in the window
  Redis documents; the metrics expose that truth rather than hiding it.
