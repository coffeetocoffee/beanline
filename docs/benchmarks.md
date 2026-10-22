# Benchmarks

`beanline bench` is the workload generator. It drives the real broker (not a
mock), so the numbers include the database round trips that dominate a real
queue.

The bench workers resolve each job's kind through the registry and run it
through the same path a production worker uses: the payload is decoded into
the kind's own argument type, the handler runs, and the error is classified by
the kind. A payload that does not fit the kind's schema is a permanent
failure, not a retry.

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
| `--gate` | Compare against the stored reference, fail on >5% p99 regression |
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
- `queue depth`: jobs waiting when the measurement window opened and when it
  closed
- `claim p50/p99`, `run p50/p99`, `e2e p50/p99`, `throughput`

### Connections, and why the numbers are repeatable

A broker connection is one request/response stream, so it serves one command
at a time. The bench gives **each worker its own connection** and the
producers their own, the way a deployment does: one connection per worker
process, plus whatever the producers use.

This matters more than it sounds. A claim costs roughly ten times an enqueue
(about 7 ms against 1.3 ms on a local Postgres, and the claim is `O(queue
depth)` because it sorts the waiting jobs by age). When the workers and the
producers shared one connection, the producers took it away from the workers:
the same command reported 16, 16 and 848 claimed jobs on three consecutive
runs, and a throughput that swung by a factor of fifty. With one connection
per worker the same command reports 5083, 4679 and 4174, and the workers
drain everything they are given.

### Reading a report

- `queue depth` near zero throughout means the workers kept up and the run
  measured steady state.
- A depth that grows across the window means the run saturated: the queue was
  the bottleneck, and the claim cost was rising with the depth. That is a
  legitimate thing to measure, but it is not a latency measurement of the
  broker.
- `claimed` is bounded by what the workers drained, not by what the producers
  enqueued. A saturating run enqueues far more than it claims.
- `--rate` caps the producer rate. It is the way to get a steady-state run:
  pick a rate the workers can drain, and the queue stays shallow and the
  latencies are comparable between runs. The rate limiter schedules each
  producer's next slot from the moment it actually enqueued, so the rate does
  not drift.

### Latency series

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
