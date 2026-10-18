# Beanline runbooks

Operational playbooks for the failure modes listed in the architecture doc (§22).
Each runbook is written to be followed top to bottom under pressure: symptom,
triage, action, verification, and the escalation trigger that says stop and get
a human.

## Contents

| Runbook | Symptom |
|---|---|
| [stuck-queue.md](stuck-queue.md) | Queue depth is not draining, throughput is zero |
| [dead-surge.md](dead-surge.md) | `beanline_jobs_dead_total` climbing, dead list full of one kind |
| [leader-flapping.md](leader-flapping.md) | `beanline_leader_active` oscillating, cron fires lag or duplicate |
| [lease-storm.md](lease-storm.md) | `beanline_jobs_reaped_total` climbing, jobs restart repeatedly |
| [db-failover.md](db-failover.md) | Broker unreachable, `/readyz` returns `broker_down` |
| [schema-rollback.md](schema-rollback.md) | Workers refuse to start, schema version mismatch |
| [poison-job.md](poison-job.md) | One job (or one handler) blocks or crashes its queue |

## Conventions used in every runbook

Commands assume the binary is on `PATH` and the backend is configured:

```sh
export BEANLINE_DATABASE_URL='postgres://...'   # or BEANLINE_REDIS_URL
```

Useful entry points, all safe to run read-only first:

```sh
beanline version
curl -s 127.0.0.1:9484/healthz
curl -s 127.0.0.1:9484/readyz
curl -s 127.0.0.1:9484/metrics
curl -s -H "Authorization: Bearer $KEY" 127.0.0.1:9484/api/queues
curl -s -H "Authorization: Bearer $KEY" '127.0.0.1:9484/api/jobs?status=dead'
curl -s -H "Authorization: Bearer $KEY" 127.0.0.1:9484/api/jobs/12345
```

Metrics referenced throughout (`/metrics`):

- `beanline_queue_depth{queue,state}`
- `beanline_jobs_enqueued_total{kind,queue}`
- `beanline_jobs_completed_total{outcome}`
- `beanline_jobs_dead_total{reason}`
- `beanline_jobs_reaped_total{queue}`
- `beanline_jobs_failed_total{kind,queue}`
- `beanline_claim_duration_seconds` (histogram)
- `beanline_scheduler_skipped_fires_total{schedule}`
- `beanline_leader_active{role}`
- `beanline_uptime_seconds`

## Ground rules

1. **Never delete rows to fix a queue.** Replay, pause, or drain. The event log
   is the audit trail; hand-edited rows break the fencing story.
2. **A stuck queue is a symptom, not a cause.** Confirm the broker is reachable
   and workers are claiming before touching any queue.
3. **One change at a time.** After every action, wait long enough for at least
   one lease cycle (`BEANLINE_LEASE_MS`, default 30 s) before judging the effect.
4. **Anything that touches running jobs can duplicate side effects.** Handlers
   are at-least-once; use `POST /api/jobs/{id}/cancel` and let the lease expire
   rather than killing workers mid-job when the job is idempotent-tolerant.