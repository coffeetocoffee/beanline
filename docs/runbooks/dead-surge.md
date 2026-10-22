# Runbook: dead-letter surge

## Symptom

- `beanline_jobs_dead_total{reason}` climbing rapidly.
- The dead list in the dashboard fills with the same `kind`.
- Alert fires on dead rate per minute per kind.

## Triage

1. **How fast and of what?**

   ```sh
   curl -s 127.0.0.1:9484/metrics | grep beanline_jobs_dead_total
   curl -s -H "Authorization: Bearer $KEY" '127.0.0.1:9484/api/jobs?status=dead&kind=emails.send'
   ```

2. **What error?** Open one dead job and read its event trail (each attempt logs
   `attempt_failed` with the error and the next run time):

   ```sh
   curl -s -H "Authorization: Bearer $KEY" 127.0.0.1:9484/api/jobs/12345
   ```

3. **Which reason?** There is no `dead_reason` field. The event trail carries
   the reason:

   | Last event | Meaning |
   |---|---|
   | `dead` after `attempt_failed` | The handler returned an error. The event carries `error` and `retryable`. |
   | `dead` after `reaped` | The job lost `max_lease_losses` leases: the handler kept killing its worker. |
   | `dead` after `claimed` | The job spent its `max_attempts` budget. |
   | `discarded_by_operator` | A human threw it away |

## Likely causes and actions

### Permanent input errors (`non_retryable`)

A malformed address, an unknown user id, a schema violation. Retrying cannot
help.

1. Fix the producer or the handler classification.
2. Discard the hopeless rows after exporting their args for the fix:
   `POST /api/jobs/{id}/discard`.
3. Re-enqueue corrected work with a new job; do not replay the broken args.

### A downstream outage (`attempts_exhausted`)

Retries burned through the budget during an outage. Fix the downstream first,
then replay. Use the dry-run filter to size the blast radius:

```sh
curl -s -H "Authorization: Bearer $KEY" \
  '127.0.0.1:9484/api/jobs?status=dead&kind=emails.send&since=24h'
```

Replay in batches rather than all at once, so the recovered downstream is not
stampeded. Start with 20, watch latency and error rate, then continue.

### Classification bug (`attempts_exhausted` on a fatal error)

The kind's error set maps an error to retryable when it should be `dead_on`.
Fix the mapping and rebuild; dead jobs that failed for this reason are safe to
replay after the fix.

### A handler that kills its worker

The job lost `max_lease_losses` leases (default 3): the handler segfaulted, was
OOM-killed, or panicked, and the worker process died with it each time. See
[poison-job.md](poison-job.md).

## Prevention

- Raise `max_attempts` (and the retry cap) only for kinds that are genuinely
  tolerant of long outages, not to silence a surge. The kind's budget is the
  tighter of the two bounds, so raising it on the kind is what takes effect.
- Alert on `dead_rate` per kind, not on the absolute dead count.
- Scheduled bulk replays get `jitter_ms`, but manual replays do not: always
  replay in batches.

## Verification

- `beanline_jobs_dead_total` stops increasing.
- Replayed jobs complete: `completed_total{outcome="success"}` rises.
- No new dead entries appear for the same kind.

## Escalate when

- Dead jobs carry args you are not permitted to read in the dashboard (masked
  as `***`): a disclosure event, notify security.
- A replay itself causes a surge of failures: stop replaying, keep the rest
  parked, and hand over to the code owner.