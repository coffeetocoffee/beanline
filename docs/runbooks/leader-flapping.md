# Runbook: leader flapping

## Symptom

- `beanline_leader_active{role}` alternates between 0 and 1 (or between worker
  ids).
- Cron schedules fire late, or `beanline_scheduler_skipped_fires_total` rises.
- Delayed jobs (`scheduled` depth) lag behind their `run_at`.

## Background

Three roles are single-instance-per-cluster and chosen by a lease:
`scheduler`, `promoter`, and `reaper`. In Postgres mode the lease is a row in
`beanline_leaders(id, holder, expires_at)` renewed with a compare-and-set; in
Redis mode it is `SET beanline:leader:<role> <worker_id> NX PX <ttl>`.
Followers idle and take over on expiry.

So a flap means leases are being lost, not acquired slowly.

## Triage

1. **Confirm the flap, and which role:**

   ```sh
   watch -n1 "curl -s 127.0.0.1:9484/metrics | grep beanline_leader_active"
   ```

2. **Leader churn or total loss?** Churn shows the holder id changing; loss
   shows a persistent 0.

3. **Can each worker reach the broker?** Every worker must reach the same
   database. A network partition between workers is the classic cause:

   ```sh
   # from each worker host
   pg_isready -d "$BEANLINE_DATABASE_URL"
   ```

4. **Clock or DB contention?** In PG mode lease expiry is stored with
   server-side time, so skew is not the cause; a saturated primary is. Check
   `pg_stat_activity` for the leader's renewal statements blocking.

5. **Postgres only:**

   ```sql
   SELECT id, holder, expires_at, expires_at - now() AS ttl
     FROM beanline_leaders ORDER BY id;
   ```

## Likely causes and actions

### Broker connectivity flaps between workers

Fix connectivity first; the queue keeps working because claims do not need
leadership, but delayed and scheduled work stalls. Go to
[db-failover.md](db-failover.md).

### Workers restarting repeatedly

Each new worker takes over, then dies, and the next one takes over. That is not
leader election failing, it is a crash loop. Check worker logs; see
[schema-rollback.md](schema-rollback.md) if the message is a schema mismatch.

### Renewal statements are too slow

The lease TTL must comfortably exceed the renewal interval and the worst-case
renewal latency. With a busy primary, shorten `BEANLINE_LEASE_MS` for
leadership purposes or reduce contention. Do not set it below 15 s.

### Misfire policy is hiding the flap

If schedules use `misfire = "skip"`, fires during a leader gap are skipped by
design and counted in `beanline_scheduler_skipped_fires_total`. After the flap
ends, decide per schedule whether to use `fireOnce` or `catchUp` (bounded).

## Recovery

1. Restore stable connectivity or DB capacity.
2. Confirm a single leader holds each role for longer than one lease cycle.
3. Confirm `scheduled` depth is draining and skipped-fire counters stop rising.
4. For schedules that missed windows during the flap, trigger them deliberately:

   ```sh
   curl -s -X POST -H "Authorization: Bearer $KEY" \
     127.0.0.1:9484/api/schedules/{id}/run
   ```

## Verification

- `beanline_leader_active` is stable at 1 for each of `scheduler`, `promoter`,
  `reaper` for at least 5 lease cycles.
- `scheduled` depth returns to normal.
- `beanline_scheduler_skipped_fires_total` stops increasing.

## Escalate when

- Leadership flaps with healthy connectivity and no worker restarts: capture the
  `beanline_leaders` rows and worker logs with timestamps; this is a scheduler
  defect, not an operational problem.
- More than one worker claims leadership for the same role simultaneously: that
  breaks single-instance assumptions. Take the whole fleet to drain, then bring
  it back one node at a time.