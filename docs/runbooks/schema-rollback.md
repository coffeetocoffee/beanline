# Runbook: schema mismatch and rollback

## Symptom

- A worker exits at startup with an error naming a missing or unexpected
  migration id.
- Workers refuse to serve `/readyz`; the dashboard tier may still be up.
- After a deploy, some workers run and others refuse to start.

## Background

Migrations are embedded in the binary and applied forward-only by
`beanline migrate` under a lock. Each worker checks the schema version at
startup and refuses to run on a mismatch. Mixed versions fail safe: the old
workers keep draining the jobs they understand, the new ones stay down until the
schema catches up.

## Triage

1. **Read the error.** It names the expected and the applied migration id.

   ```sh
   journalctl -u beanline-worker -n 50 --no-pager
   kubectl logs <pod> | tail -50
   ```

2. **Compare binary version to schema version:**

   ```sh
   beanline version
   beanline migrate      # dry behaviour: it only reports and applies pending SQL
   ```

3. **Postgres: what is recorded?**

   ```sql
   SELECT * FROM beanline_schema_migrations ORDER BY id;
   ```

   The recorded set must be a prefix of the migrations embedded in the binary
   you are about to run.

4. **Which direction?**

   | Situation | Meaning |
   |---|---|
   | Schema older than binary | Migrate before rolling out the new binary |
   | Schema newer than binary | You rolled back the binary; see below |

## Migrating forward

1. Take a backup of the database. Migrations are forward-only and audited.
2. Run the migrate step once, from a single host, with the DDL role:

   ```sh
   BEANLINE_DATABASE_URL='postgres://ddl-role@...' beanline migrate
   ```

3. Roll workers out gradually. New workers start cleanly; old workers keep
   serving.
4. Watch `readyz`, `queue_depth`, and dead totals for one lease cycle.

Because enqueues keep flowing while you migrate, do the migration during a
low-traffic window, and expect a brief claim latency bump from the DDL lock.

## Rolling back a release

Forward-only means a binary rollback needs a forward fix. Choose one:

1. **Preferred: roll the binary back and keep the new schema**, if the new
   migrations are additive (new columns with defaults, new tables). Additive
   changes are backward compatible; old workers ignore columns they do not
   know about.
2. **Otherwise: roll forward.** Fix forward with a new migration and deploy it.
   Do not hand-edit `beanline_schema_migrations`; the recorded set must match
   what is actually in the database.
3. **Last resort: restore from backup.** Only if the new migration did something
   destructive. Restoring loses every job enqueued after the backup, so
   reconcile deliberately: compare the affected tables before and after.

## Verifying

```sql
-- Schema as the database sees it
SELECT * FROM beanline_schema_migrations ORDER BY id;
```

```sh
# Every worker healthy
curl -s 127.0.0.1:9484/readyz
```

- All workers report `ready`.
- No worker logs a schema mismatch after a restart.
- Queue depth and completion rate match the pre-deploy baseline.

## Escalate when

- The recorded migration set does not match the tables that exist (for example a
  migration marked applied but its table missing). Stop. Take a physical backup,
  capture `\d beanline_jobs` and the migration table, and escalate: this is
  corruption of migration state and no automated action is safe.
- The DDL lock blocks for more than a few seconds and workers are erroring
  during the migration: stop the migration, let the lock clear, and retry in a
  quieter window.