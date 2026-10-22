# Runbook: lease storm

## Symptom

- `beanline_jobs_reaped_total` climbing sharply.
- The same job ids appear repeatedly in the dashboard with attempt counts
  increasing and no corresponding completions.
- Jobs run longer than expected and then restart from the beginning.

## Background

A claim takes a lease (`BEANLINE_LEASE_MS`, default 30 s) and bumps
`lease_epoch`, the fencing token. The worker extends the lease in one batched
heartbeat per tick. When `lock_expires_at` passes, the leader-gated reaper
returns the job to `available` and a fresh claim gets a new epoch. Late writes
from the old holder are rejected because every state write carries
`WHERE id = ? AND lease_epoch = ?`.

So a reap storm means leases are expiring faster than heartbeats extend them.

## Triage

1. **Rate and queue:**

   ```sh
   curl -s 127.0.0.1:9484/metrics | grep -E 'reaped_total|lease'
   ```

2. **Heartbeat traffic.** With 1,000 running jobs the design target is about one
   heartbeat write per tick, not per job per second. A jump in claim duration or
   broker latency is the usual cause.

   ```sh
   curl -s 127.0.0.1:9484/metrics | grep -E 'claim_duration_seconds_(count|sum)'
   ```

3. **Is the worker partitioned or stalled?** A worker that loses broker
   connectivity cannot extend leases; its jobs get reaped while the handler is
   still running. Check worker logs for connection errors and broker latency.

4. **Are the handlers simply longer than the lease?** A job whose worst-case
   runtime exceeds `lease_ms` will be reaped even on a perfectly healthy worker.
   Compare the handler's real duration (`beanline_job_duration_seconds` in
   Prometheus terms, visible on the job's per-attempt events) to the lease.

5. **Postgres only:**

   ```sql
   SELECT count(*) FROM beanline_jobs
    WHERE status = 'running' AND lock_expires_at < now();
   ```

## Actions

### Lease shorter than the work

Raise the lease for that kind or globally, and restart workers one at a time:

```sh
BEANLINE_LEASE_MS=120000
```

Rules of thumb:

- Lease comfortably exceeds worst-case duration plus margin (at least 3x).
- Never below 15 s.
- Long jobs should not rely on heartbeat timing alone; the heartbeat extends in
  batches, so a very large running set can exceed one tick's budget.

### Broker latency spikes during heartbeat

Fix broker capacity first (Postgres: WAL and lock time; Redis: memory and
slowlog). Do not raise the lease to paper over a saturated database: it lengthens
crash-recovery detection too. See [db-failover.md](db-failover.md).

### A partitioned worker keeps running jobs

Cancel the affected jobs, or let their leases expire. Fencing guarantees the
zombie's writes are rejected, so no manual cleanup is needed:

```sh
curl -s -X POST -H "Authorization: Bearer $KEY" -H "x-csrf-token: $CSRF" \
  127.0.0.1:9484/api/jobs/12345/cancel -d '{"queue":"default"}'
```

### Reap loop from a crashing handler

If reaps are followed by worker restarts and jobs that die after losing
`max_lease_losses` leases, that is a poison job, not a lease problem. Go to
[poison-job.md](poison-job.md).

## Verification

- `beanline_jobs_reaped_total` returns to its baseline.
- No job shows an attempt count that keeps climbing without completions.
- `running` depth stays at or below configured concurrency.

## Escalate when

- Reaped jobs complete successfully elsewhere while the original worker still
  reports them running: fencing is behaving as designed, but you are burning
  work. Raise the lease and capture the worker's log for the same job ids.
- Reaps continue with healthy heartbeats and short handlers: suspect clock skew
  between broker and worker. PG mode uses server-side time for leases, so
  verify the broker's clock, not the worker's.