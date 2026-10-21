-- 0005_unique_dead: a dead job releases its unique key.
--
-- The partial unique index decides which rows "hold" a unique key: a row is
-- in the index while its status is not in the excluded set. Until now the
-- excluded set was (completed, discarded, cancelled), so a dead row kept
-- holding its unique key and a later enqueue with the same key was deduped
-- on Postgres. Redis deletes the guard key when a job goes dead, so Redis
-- accepted the enqueue and the two backends diverged.
--
-- Rebuilding the index with 'dead' added to the excluded set makes the index
-- membership match the Redis guard lifecycle: the key is free again as soon
-- as the job dies.
--
-- The index is rebuilt rather than patched in place because a partial index
-- predicate cannot be altered; DROP + CREATE is atomic enough here (the table
-- is not written by workers during a migration, and `beanline migrate` holds
-- an advisory lock).
DROP INDEX IF EXISTS beanline_jobs_unique;

CREATE UNIQUE INDEX beanline_jobs_unique
    ON beanline_jobs (queue, kind, unique_key)
 WHERE unique_key IS NOT NULL AND status NOT IN ('completed','discarded','cancelled','dead');
