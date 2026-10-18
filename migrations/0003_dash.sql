-- 0003_dash: dashboard auth + audit tables (M5)
-- Read/write roles own beanline_users / beanline_api_keys / beanline_audit_log.
-- Sessions live in memory; the schema keeps the user/key registry and the
-- operator-action audit trail durable.

CREATE TABLE IF NOT EXISTS beanline_users (
  name       TEXT PRIMARY KEY,
  hash       TEXT NOT NULL,
  role       TEXT NOT NULL DEFAULT 'admin'
             CHECK (role IN ('admin','viewer')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS beanline_api_keys (
  prefix     TEXT PRIMARY KEY,
  hash       TEXT NOT NULL,
  scopes     TEXT[] NOT NULL DEFAULT '{jobs_read}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS beanline_audit_log (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor      TEXT NOT NULL,
  action     TEXT NOT NULL,
  job_id     BIGINT,
  queue      TEXT,
  detail     JSONB NOT NULL DEFAULT '{}',
  at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS beanline_audit_log_at
    ON beanline_audit_log (at);
