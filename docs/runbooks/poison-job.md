# Runbook: poison job quarantine

## Symptom

- One job id recurs in the dashboard with the same error on every attempt.
- One handler burns its whole retry budget per job and blocks queue throughput.
- One job id repeats with `claimed` and `reaped` events and no completion:
  the handler kills its worker, so the lease is lost every time.
- A queue shows steady failing throughput with no successful completions.

A poison job is one specific job (bad args, unparseable payload) or one kind
(one handler path is broken for all inputs). Both are contained the same way:
stop the bleeding, preserve the evidence, quarantine, then replay later.

## Triage

1. **One job or many?** Compare failure counts per kind:

   ```sh
   curl -s -H "Authorization: Bearer $KEY" '127.0.0.1:9484/api/jobs?status=running'
   curl -s -H "Authorization: Bearer $KEY" '127.0.0.1:9484/api/jobs?status=dead'
   ```

2. **What is the error, exactly?** Read the attempt history, not just the last
   line:

   ```sh
   curl -s -H "Authorization: Bearer $KEY" 127.0.0.1:9484/api/jobs/12345
   ```

3. **Did the worker die, or did the handler fail?** The event trail
   distinguishes them. A handler that returned an error leaves an
   `attempt_failed` (or `dead`) event. A handler that killed its worker
   leaves a `reaped` event, and the job's `attempts` count stays flat while
   `lease_losses` climbs.

4. **Are args sensitive?** Fields marked `sensitive` render as `***`. If you need
   the values to diagnose, get them from the producer side instead of disabling
   masking; that is a disclosure event and must be logged as one.

5. **Does it repeat after cancellation?** Cancel it first (see below). If a new
   job with the same args arrives, this is a producer bug, not a queue problem.

## Contain: stop the retry burn

Options, safest first:

1. **Pause the queue** if the failing kind has the queue to itself:

   ```sh
   curl -s -X POST -H "Authorization: Bearer $KEY" -H "x-csrf-token: $CSRF" \
     127.0.0.1:9484/api/queues/import/pause
   ```

   Resuming afterwards:

   ```sh
   curl -s -X POST -H "Authorization: Bearer $KEY" -H "x-csrf-token: $CSRF" \
     127.0.0.1:9484/api/queues/import/resume
   ```

2. **Cancel the job** if it is running and you do not want the handler to
   finish:

   ```sh
   curl -s -X POST -H "Authorization: Bearer $KEY" -H "x-csrf-token: $CSRF" \
     127.0.0.1:9484/api/jobs/12345/cancel -d '{"queue":"import"}'
   ```

3. **Discard the job** once the evidence is captured and it cannot ever succeed.
   This is terminal; the event log keeps the record.

4. **Cap the damage with the budget.** The attempt budget is an upper bound,
   and the worker enforces the kind's `max_attempts` however the job was
   enqueued, so lowering it on the kind takes effect immediately for every
   job of that kind, including the ones already queued. A producer that
   keeps re-enqueueing the same payload is the other half of the problem:
   stop re-enqueueing, and pause the queue until the producer is fixed.
   Every retry costs real handler time.

## Quarantine a kind that kills its worker

A segfault, an OOM kill, or a Zig panic in a handler takes the whole worker
process down: there is no in-process crash isolation. The jobs that worker
was holding lose their leases, the reaper requeues them, and the attempt the
reaper consumed is refunded, because a lease expiry is usually not the job's
fault (the worker died, the host rebooted, the heartbeat was lost).

The consequence is that a job whose handler kills the worker on every attempt
never spends an attempt, so `max_attempts` never dead-letters it. The
separate `lease_losses` counter is the bound: it is never refunded, and once a
job has lost `max_lease_losses` leases (default 3) it is dead-lettered and
appears in the dead list. Actions:

1. Pause the queue if the crashing kind has the queue to itself. A worker
   restart loop takes every other job on that worker down with it.
2. Confirm the loop from the job's event trail: a repeated `claimed` /
   `reaped` alternation with a flat `attempts` count and a climbing
   `lease_losses` count.
3. Capture the failing job id and its args.
4. Fix the handler before unpausing. Replay into a staging queue after the fix
   rather than into production.

There is no per-kind crash isolation in this release, so the handler has to be
fixed in place. The lease-loss bound stops the job from churning forever; it
does not stop the worker from restarting until the handler is fixed.

## Evidence to keep before discarding

- Job id, kind, queue, attempt count, lease loss count.
- Full event trail (`enqueued`, each `attempt_failed`, each `reaped`, `dead`).
- Args, with sensitive fields left masked in any shared report.
- The deploy or config change that correlates in time with the first failure.

## After the fix

1. Fix the handler or the producer.
2. Re-enqueue the affected work. Prefer new jobs with corrected args over
   replaying unchanged poison payloads.
3. Replay in batches from the dead list; watch for an immediate repeat of the
   same error, which means the fix is not deployed yet.
4. Unpause the queue.

## Verification

- No job id repeats across attempts.
- `beanline_jobs_failed_total{kind=...}` returns to baseline.
- Successful completions for that kind resume.
- The producer no longer enqueues the bad payload (check for a new poison job
  within a few minutes of traffic).
- No job is left cycling with `lease_losses` climbing.

## Escalate when

- The same args recur from a producer you do not own: the producer needs to stop
  or be feature-flagged off. Escalate to that team's on-call with the job ids.
- Discarding is not acceptable because the work is regulated or billable: keep
  the job in `dead`, notify the data owner, and schedule the replay with the
  business owner.
- A handler segfaults or OOMs: the worker process dies with it, and every
  other job it was holding is requeued. Restart the worker, fix the handler,
  and only then resume the queue.
