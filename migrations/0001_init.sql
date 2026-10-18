-- 0001_init: Beanline schema (PostgreSQL backend)
-- Applies in order; forward-only. Run via `beanline migrate` under an advisory lock.

CREATE TABLE beanline_jobs (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  queue           TEXT        NOT NULL,
  kind            TEXT        NOT NULL,
  args            JSONB       NOT NULL DEFAULT '{}',
  status          TEXT        NOT NULL DEFAULT 'available'
                  CHECK (status IN ('available','scheduled','running',
                                    'completed','dead','discarded','cancelled')),
  priority        SMALLINT    NOT NULL DEFAULT 1,
  run_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  max_attempts    INT         NOT NULL DEFAULT 25,
  attempts        INT         NOT NULL DEFAULT 0,
  lock_expires_at TIMESTAMPTZ,
  lease_epoch     BIGINT      NOT NULL DEFAULT 0,
  worker_id       TEXT,
  unique_key      TEXT,
  dedup_run_id    TEXT,
  batch_id        BIGINT,
  tags            TEXT[]      NOT NULL DEFAULT '{}',
  context         JSONB       NOT NULL DEFAULT '{}',
  inserted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at      TIMESTAMPTZ,
  finished_at     TIMESTAMPTZ
);

CREATE INDEX beanline_jobs_claim
    ON beanline_jobs (queue, priority, run_at)
 WHERE status = 'available';

CREATE INDEX beanline_jobs_promote
    ON beanline_jobs (run_at)
 WHERE status = 'scheduled';

CREATE INDEX beanline_jobs_batch
    ON beanline_jobs (batch_id) WHERE batch_id IS NOT NULL;

CREATE UNIQUE INDEX beanline_jobs_dedup
    ON beanline_jobs (kind, dedup_run_id) WHERE dedup_run_id IS NOT NULL;

CREATE UNIQUE INDEX beanline_jobs_unique
    ON beanline_jobs (queue, kind, unique_key)
 WHERE unique_key IS NOT NULL AND status NOT IN ('completed','discarded','cancelled');

CREATE TABLE beanline_job_events (
  job_id BIGINT NOT NULL REFERENCES beanline_jobs(id) ON DELETE CASCADE,
  seq    INT    NOT NULL,
  type   TEXT   NOT NULL,
  data   JSONB  NOT NULL DEFAULT '{}',
  at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (job_id, seq)
);

CREATE TABLE beanline_workers (
  worker_id TEXT PRIMARY KEY,
  boot_id   UUID NOT NULL,
  host      TEXT NOT NULL,
  pid       INT  NOT NULL,
  roles     TEXT[] NOT NULL,
  seen_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE beanline_schedules (
  id        TEXT PRIMARY KEY,
  kind      TEXT NOT NULL,
  queue     TEXT NOT NULL DEFAULT 'default',
  cron      TEXT NOT NULL,
  tz        TEXT NOT NULL DEFAULT 'UTC',
  args      JSONB NOT NULL DEFAULT '{}',
  misfire   TEXT NOT NULL DEFAULT 'skip',
  jitter_ms INT  NOT NULL DEFAULT 5000,
  enabled   BOOL NOT NULL DEFAULT true
);

CREATE TABLE beanline_batches (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  total         INT NOT NULL,
  remaining     INT NOT NULL,
  callback_kind TEXT,
  callback_args JSONB,
  status        TEXT NOT NULL DEFAULT 'open',
  inserted_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);