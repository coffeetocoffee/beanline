# Benchmark references

Each file here is a recorded baseline for one scenario:

```
<backend>-<workload>.json
```

for example `postgres-noop.json` or `redis-io.json`. The gate in
`beanline bench --gate` loads the matching file and fails when the measured
claim p99 is more than 5% worse than the recorded `p99_ms`.

## Regenerating

```sh
./scripts/bench-reference.sh
```

Run it on the machine that defines the baseline, with the same backend
configuration, and commit the result. The numbers are only meaningful for
that machine: a different CPU, a different database, or a noisy neighbour
will make the comparison meaningless in both directions.

## Current state

**No reference files are committed yet.** Producing them requires a measured
run against a real Postgres and a real Redis on reference hardware, which has
not happened in this repository. Until then the gate reports
`gate: no reference for <backend>/<workload>` and passes, so a new scenario
can be added without breaking CI.

Fabricating numbers here would be worse than having none: the gate would then
compare against fiction and block or wave through real changes at random.

## File format

```json
{
  "workload": "noop",
  "backend": "postgres",
  "workers": 8,
  "p50_ms": 3.1,
  "p99_ms": 18.4,
  "throughput": 5240.0
}
```

`p99_ms` is the claim latency p99 in milliseconds (the gate's comparison
metric), `throughput` is completed jobs per second (informational).
