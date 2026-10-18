# Configuration

Precedence: CLI flags > environment > config file > defaults. Today everything
is read from the environment (`BEANLINE_*`); a JSON5 config file decoder is
planned and will use the same struct.

## Backend

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_BACKEND` | auto | `postgres` or `redis`. Auto-detected from the URLs below. |
| `BEANLINE_DATABASE_URL` | - | Postgres DSN. Setting it selects Postgres mode. |
| `BEANLINE_REDIS_URL` | - | Redis URL. Setting it selects Redis mode. |

## Queues and workers

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_QUEUES` | `default` at the default concurrency | `name:concurrency` pairs, semicolon separated. |
| `BEANLINE_QUEUE_CONCURRENCY` | `4` | Concurrency for queues without an explicit value. |
| `BEANLINE_LEASE_MS` | `30000` | Lease duration. Minimum 15 s. |
| `BEANLINE_DRAIN_TIMEOUT_MS` | `30000` | How long running jobs may finish during shutdown. |

## Retention

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_RETENTION_COMPLETED_MS` | `72h` | How long completed jobs are kept. |
| `BEANLINE_RETENTION_EVENTS_MS` | `7d` | How long job events are kept. |

## Dashboard

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_DASH_ENABLED` | `false` | Serve the dashboard from a worker process. The `server` command always serves it. |
| `BEANLINE_DASH_BIND` | `127.0.0.1:9484` | Listen address. A `0.0.0.0` bind with no auth configured is refused at startup. |
| `BEANLINE_DASH_SECRET` | - | Secret for the dashboard. |
| `BEANLINE_DASH_READONLY` | `false` | Refuse every mutating operation. |
| `BEANLINE_DASH_USERS` | - | `name:password:role` entries, semicolon separated. Roles: `admin`, `viewer`. |
| `BEANLINE_DASH_KEYS` | - | `prefix:secret:scope1,scope2` entries, semicolon separated. |

OIDC SSO has its own block of variables; see
[dashboard-auth.md](dashboard-auth.md).

## Observability

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_OTEL_ENDPOINT` | - | OTLP endpoint (`http://otel:4318`). |
| `BEANLINE_LOG_PAYLOAD` | `false` | Log job args. Off by default for PII discipline. |

## Notes

- **Secrets stay out of the process arguments.** URLs and secrets come from the
  environment, never from flags.
- **Least privilege.** The runtime role needs `SELECT/INSERT/UPDATE/DELETE` on
  `beanline_*` only. Migrations are a separate, DDL-privileged step
  (`beanline migrate`).
- **Clock skew.** In Postgres mode, leases and leader expiry are stored with
  server-side time, so worker clock skew does not cause spurious reaping.
