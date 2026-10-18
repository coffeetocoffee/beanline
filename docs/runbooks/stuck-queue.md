# Runbook: stuck queue

## Symptom

- `beanline_queue_depth{state="available"}` is above normal and not falling.
- `beanline_jobs_completed_total` is flat or near zero while depth grows.
- Dashboard queue overview shows a growing "oldest pending age".

## Triage

1. **Is the broker reachable from the worker?**

   ```sh
   curl -s 127.0.0.1:9484/readyz     # "broker_down" means broker, not queue
   ```

   `broker_down` means go to [db-failover.md](db-failover.md).

2. **Are workers claiming at all?** Check claim traffic and depth together:

   ```sh
   curl -s 127.0.0.1:9484/metrics | grep -E 'queue_depth|claim_duration_seconds_count|workers'
   ```

   No claims plus growing depth means the claim loop is parked or all slots are
   held by running work.

3. **Are slots saturated by long-running jobs?** Look at `state="running"`
   depth and the oldest running job:

   ```sh
   curl -s -H "Authorization: Bearer $KEY" '127.0.0.1:9484/api/jobs?status=running'
   ```

4. **Backpressure shedding?** Producers may be failing to enqueue rather than
   the queue being stuck. Check producer logs for backpressure errors and the
   configured `max_pending` for that queue.

5. **Is the queue paused?** `GET /api/queues` reports `paused` if an operator
   paused it. Resume with `POST /api/queues/{name}/resume`.

## Likely causes and actions

### All workers dead or crash-looping

```sh
systemctl status beanline-worker || kubectl get pods -l app=beanline
journalctl -u beanline-worker -n 200 --no-pager
```

A worker that exits nonzero repeatedly usually has a schema mismatch (see
[schema-rollback.md](schema-rollback.md)) or a broker connection failure. Start
one worker manually with logs on stderr before restarting the fleet.

### Concurrency saturated by a slow dependency

If `running` depth equals `max_workers` for the queue, the queue is not stuck,
it is full of slow work. Actions, in order of least risk:

1. Raise concurrency for the queue if the downstream can take it:
   `BEANLINE_QUEUES='mailers:8'`, restart workers one at a time.
2. Add a dedicated queue for the slow kind so it cannot starve fast kinds.
3. Cancel the specific stuck jobs and fix the dependency.

### The delayed promoter is not moving scheduled jobs

Delayed and cron jobs land as `scheduled` and are promoted to `available` by the
leader-gated promoter. If `state="scheduled"` is climbing while
`state="available"` is empty, the promoter is not running: check
`beanline_leader_active` and go to [leader-flapping.md](leader-flapping.md).

### Jobs are claimable but never finish

`running` climbs, `completed_total` flat, no `dead_total`. Handlers are hanging.
Per-kind `timeout_ms` should end them; if it is unset, add it, then cancel the
stuck jobs:

```sh
curl -s -X POST -H "Authorization: Bearer $KEY" -H "x-csrf-token: $CSRF" \
  127.0.0.1:9484/api/jobs/12345/cancel -d '{"queue":"mailers"}'
```

Running handlers that ignore cancellation are released when their lease expires.

## Verification

- `beanline_queue_depth{state="available"}` decreases over at least a few lease
  cycles.
- `beanline_jobs_completed_total{outcome="success"}` increments again.
- No growth in `beanline_jobs_reaped_total`.

## Escalate when

- Depth is flat after a restart, and `readyz` is healthy: suspect a broker-side
  lock or a very long-running transaction in Postgres. Capture
  `SELECT * FROM pg_stat_activity` output and hand it over.
- The queue is stuck after a code deploy: suspect a handler that panics on
  input from the backlog. Quarantine per [poison-job.md](poison-job.md).