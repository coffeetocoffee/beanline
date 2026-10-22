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

### Backend requirements

| Backend | Minimum | Why |
|---|---|---|
| Postgres | 13 | `SKIP LOCKED`, `GENERATED ALWAYS AS IDENTITY`, JSONB. |
| Redis | **5.0** | The Lua scripts call `redis.call('TIME')` and then write. Before Redis 5.0 (effects replication) a script that called a non-deterministic command and then wrote was rejected outright, so every write path fails. Beanline checks the server version at connect time and refuses an older one with a clear message. |

## Queues and workers

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_QUEUES` | `default` at the default concurrency | `name:concurrency` pairs, semicolon separated. |
| `BEANLINE_QUEUE_CONCURRENCY` | `4` | Concurrency for queues without an explicit value. |
| `BEANLINE_LEASE_MS` | `30000` | Lease duration. Minimum 15 s. |
| `BEANLINE_DRAIN_TIMEOUT_MS` | `30000` | How long running jobs may finish during shutdown. |

## Retries

Retry policy is per kind: a kind declares its own backoff and its own error
classification, and the classification is checked by the compiler (an
unclassified error is a build error). The variables below are the default for
kinds that do not declare a backoff of their own.

| Variable | Default | Meaning |
|---|---|---|
| `BEANLINE_RETRY_BASE_MS` | `1000` | Base delay of the exponential backoff. |
| `BEANLINE_RETRY_CAP_MS` | `1800000` (30 min) | Maximum delay between attempts. |
| `BEANLINE_RETRY_FACTOR` | `2.0` | Growth factor of the exponential backoff. |
| `BEANLINE_RETRY_JITTER` | `full` | Jitter mode: `none`, `full`, `equal` or `decorrelated`. |
| `BEANLINE_MAX_ATTEMPTS` | `25` | Attempt budget for jobs enqueued for a kind this process does not know. A kind that is known uses its own `max_attempts`. |

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
| `BEANLINE_METRICS_MAX_KINDS` | `500` | Cap on distinct `kind` label values. |
| `BEANLINE_METRICS_MAX_QUEUES` | `200` | Cap on distinct `queue` label values. |

## Metrics label policy

Prometheus label values are interned under a hard cap. Once a cap is reached,
further values collapse into a single `__other__` series and the drop is
counted in `beanline_metrics_label_overflow_total{label="kind"}` (same for
`queue`), so the limit is visible rather than silent. Raise the caps if you
run genuinely that many kinds; otherwise the overflow series tells you the
labels are too noisy to be useful.

Labels are deliberately narrow:

- Counters and gauges: `kind`, `queue`, `state`, `label`.
- Histograms (`beanline_job_duration_seconds`, `beanline_job_e2e_seconds`):
  `kind` and `outcome` only.
- Never attempt numbers, tags, job ids, or worker ids. Those are per-event
  detail and belong in traces and the job event log, not in scraped series.

The two histograms are separate on purpose. Handler duration is the fast
per-attempt signal; enqueue-to-terminal widens by the whole retry backoff chain
(§10.2), so folding the two together would blur the p99 you actually alert on.

## Notes

- **Secrets stay out of the process arguments.** URLs and secrets come from the
  environment, never from flags.
- **Least privilege.** The runtime role needs `SELECT/INSERT/UPDATE/DELETE` on
  `beanline_*` only. Migrations are a separate, DDL-privileged step
  (`beanline migrate`).
- **Clock skew.** In Postgres mode, leases and leader expiry are stored with
  server-side time, so worker clock skew does not cause spurious reaping.
