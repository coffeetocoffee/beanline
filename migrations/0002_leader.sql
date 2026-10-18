-- 0002_leader: row-lease table for scheduler/promoter/reaper leadership
CREATE TABLE IF NOT EXISTS beanline_leaders (
  role       TEXT PRIMARY KEY,
  holder     TEXT NOT NULL,
  epoch      BIGINT NOT NULL DEFAULT 1,
  expires_at TIMESTAMPTZ NOT NULL
);
