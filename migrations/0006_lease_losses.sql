-- 0006_lease_losses: bound the lease-loss retry loop.
--
-- The reaper refunds the attempt it consumes when a lease expires, because a
-- lease expiry is usually not the job's fault: the worker was killed, the
-- host rebooted, the VM was paused, or the heartbeat never reached the
-- broker. Charging those to max_attempts would burn the retry budget of
-- jobs that would have succeeded.
--
-- The side effect is that a job whose handler kills its worker on every
-- attempt oscillates between claim and reap forever. The attempt counter
-- goes 1 -> 0 -> 1 -> 0, so max_attempts is never reached and the job is
-- never dead-lettered: it churns until an operator notices.
--
-- lease_losses counts the lease expiries separately and is never refunded.
-- Once a job has lost max_lease_losses leases it is dead-lettered, which
-- bounds the loop without spending the failure budget of jobs that were
-- merely interrupted.
--
-- max_lease_losses = 0 disables the bound and keeps the old behaviour.
ALTER TABLE beanline_jobs
    ADD COLUMN IF NOT EXISTS lease_losses INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_lease_losses INT NOT NULL DEFAULT 3;
