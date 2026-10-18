# Runbook: database failover / broker outage

## Symptom

- `/readyz` returns `broker_down` on workers.
- Producers using the library API get a typed error on enqueue.
- Logs show connection resets, timeouts, or "cannot open backend".
- Queue depth freezes rather than dropping (loops park with backoff).

## Background

Correctness never depends on the broker being up:

- Producers are told, never silently black-holed. In-process enqueues fail with
  a typed error; the app decides whether to retry or fail the request.
- In-flight jobs keep running; their leases cannot be extended, so after the
  lease expires the reaper returns them to `available` and another worker picks
  them up. Handlers are at-least-once, so a partition during execution can
  duplicate a side effect. This is the documented contract, not a bug.
- `LISTEN/NOTIFY` is treated as a latency optimization only; correctness rests
  on the adaptive poll (1 s to 30 s) and the reaper.

## Triage

1. **Confirm the outage, and where:**

   ```sh
   curl -s 127.0.0.1:9484/readyz
   pg_isready -h db.internal -p 5432      # Postgres
   redis-cli -h redis.internal ping       # Redis
   ```

2. **Is it the client or the database?** Try from the same host as a failing
   worker, not from your laptop. A VPN-only failure is usually egress config.

3. **Postgres: which state?**

   ```sql
   SELECT pg_is_in_recovery();          -- true on a replica after failover
   SELECT now();                        -- compare with the app host's clock
   ```

4. **Redis: which state?**

   ```sh
   redis-cli -h redis.internal info persistence | grep -E 'aof_last_bgrewrite_status|rdb_last_bgsave_status'
   redis-cli -h redis.internal info memory | grep used_memory_human
   ```

5. **Check what each worker is doing during the outage.** Claim loops park with
   backoff; heartbeats fail. Both recover on their own once the broker returns.

## Actions during the outage

- Do not scale workers up: extra workers add connection pressure to a database
  that is already failing over.
- Do not restart workers repeatedly. Each restart costs a lease cycle of
  recovery time.
- Keep the dashboard up. It serves `/healthz`, `/readyz`, `/metrics`, and the
  job browser, which is exactly what you need to see what happened.
- For high-value producers, switch to the transactional-outbox pattern in
  Postgres mode so job creation survives the outage inside the app's own
  transaction, then let the outbox drain after recovery.

## After the broker returns

1. Confirm `/readyz` is `ready` on every worker.
2. Expect a burst of reaped jobs to be re-claimed. Watch
   `beanline_jobs_reaped_total` and `beanline_queue_depth` settle.
3. Confirm the leader roles re-acquire (see
   [leader-flapping.md](leader-flapping.md) if they do not settle).
4. Check for duplicate side effects in the window between last successful
   heartbeat and lease expiry. This window is bounded by
   `BEANLINE_LEASE_MS`; use it to scope the audit:
   - job ids with attempt counts greater than expected,
   - downstream records created twice for the same business key.
5. Check the delayed watermark. In Redis mode, a long outage plus `BGSAVE`
   stalls can lose in-flight delayed state depending on AOF settings; the
   metric tells you what to trust.

## Postgres-specific

- After a failover, prepared connections are dead. Workers reconnect with backoff;
  if a worker does not recover, restart it one at a time.
- Verify the runtime role can still `SELECT/INSERT/UPDATE/DELETE` on
  `beanline_*`. A failover to a replica restored from an older snapshot can
  present a stale privilege set.
- If the new primary is read-only (split brain), stop workers from claiming:
  they will park anyway, but stopping avoids noisy retry churn.

## Redis-specific

- Redis mode's durability is Redis durability (AOF everysec by default). Jobs
  can be lost in the window Redis documents; the metrics expose
  `aof_last_bgrewrite_status` so you can see whether that window applied.
- Export the dead letter list and event trail periodically if compliance cares;
  Redis treats jobs as hot state.

## Verification

- `/readyz` returns `ready` on all workers.
- `available` depth is draining again.
- No growth in reaped totals beyond the expected post-outage burst.

## Escalate when

- Jobs are lost after recovery in Redis mode: treat as data loss, capture
  persistence state and the last known `delayed` watermark before restarting
  anything.
- Postgres jobs are missing after failover: check whether the primary was
  restored from a replica snapshot taken before the enqueue. Job state follows
  the database; there is no separate job store to reconcile against.