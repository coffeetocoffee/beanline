# Runbook: poison job quarantine

## Symptom

- One job id recurs in the dashboard with the same error on every attempt.
- One handler burns its whole retry budget per job and blocks queue throughput.
- Sandbox kinds reach `crash_loop` dead jobs (`reason = "crash_loop"`).
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

3. **Are args sensitive?** Fields marked `sensitive` render as `***`. If you need
   the values to diagnose, get them from the producer side instead of disabling
   masking; that is a disclosure event and must be logged as one.

4. **Does it repeat after cancellation?** Cancel it first (see below). If a new
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

4. **Cap the damage with the budget.** If a poison job is enqueued at high rate
   (a retrying producer), lower `max_attempts` for the kind and pause the queue
   until the producer is fixed. Every retry costs real handler time.

## Quarantine a crashing kind

For kinds run with `isolation = "subprocess"`, a crash is already isolated:
the supervisor releases the job with reason `worker_crash`, and
`max_crash_attempts` stops the loop and parks the job as `crash_loop`. Actions:

1. Keep the kind isolated; do not move it in-process to "fix" the symptom.
2. Capture the failing job id and its args.
3. Replay into a staging queue after the fix rather than into production.

## Evidence to keep before discarding

- Job id, kind, queue, attempt count.
- Full event trail (`enqueued`, each `attempt_failed`, `dead`).
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

## Escalate when

- The same args recur from a producer you do not own: the producer needs to stop
  or be feature-flagged off. Escalate to that team's on-call with the job ids.
- Discarding is not acceptable because the work is regulated or billable: keep
  the job in `dead`, notify the data owner, and schedule the replay with the
  business owner.
- A handler segfaults or OOMs outside sandbox mode: the worker process is at
  risk. Restart the worker and move that kind to `isolation = "subprocess"`
  before resuming the queue.