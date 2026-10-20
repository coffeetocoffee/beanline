-- 0004_queue_state: durable per-queue operator state (pause/resume).
-- Rows are upserted by the dashboard control plane and read by every worker's
-- claim query, so a pause takes effect across processes.
CREATE TABLE IF NOT EXISTS beanline_queue_state (
  queue      TEXT PRIMARY KEY,
  paused     BOOLEAN NOT NULL DEFAULT false,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
