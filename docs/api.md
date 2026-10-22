# REST API

The dashboard binary serves the UI, the REST API, the SSE stream, and the
Prometheus endpoint on one port (default `127.0.0.1:9484`).

## Authentication

| Surface | Credential |
|---|---|
| UI (`/`, `/login`) | Session cookie (`beanline_session`) plus `x-csrf-token` on POSTs |
| `/api/*` (including `/api/live`) | Session cookie, or `Authorization: Bearer <prefix>.<secret>` |
| `/metrics`, `/healthz`, `/readyz` | Open |

API keys carry scopes: `jobs_read`, `jobs_write`, `queues_control`. Reads
require `jobs_read` (a `jobs_write` key may also read); `POST /api/enqueue` and
the job action endpoints require `jobs_write`; queue control requires
`queues_control`. Queue control alone grants no reads.

## Endpoints

### System

| Method | Path | Description |
|---|---|---|
| GET | `/healthz` | Process is alive. Always `200 ok`. |
| GET | `/readyz` | `200 ready`, or `503 broker_down` when the broker is unreachable. |
| GET | `/metrics` | Prometheus exposition (`text/plain; version=0.0.4`). |

### Queues

| Method | Path | Description |
|---|---|---|
| GET | `/api/queues` | Depth, state, and `paused` flag per queue. |
| POST | `/api/queues/{name}/pause` | Stop claiming from a queue. Scope `queues_control`. |
| POST | `/api/queues/{name}/resume` | Resume claiming. Scope `queues_control`. |

Pause state is stored in the broker (Postgres table `beanline_queue_state` or
the Redis key `beanline:{<queue>}:paused`), so it applies to every worker
process, not just the dashboard. Paused queues keep accepting enqueues; claims
simply return nothing until resumed.

### Jobs

| Method | Path | Description |
|---|---|---|
| GET | `/api/jobs?status=&kind=&queue=&limit=&offset=` | Paginated job list. |
| GET | `/api/jobs/{id}` | One job plus its event trail. |
| POST | `/api/jobs/{id}/retry` | Move a dead or failed job back to `available`. |
| POST | `/api/jobs/{id}/discard` | Terminal: park the job as discarded. |
| POST | `/api/jobs/{id}/cancel` | Cancel a scheduled or running job. |

The action endpoints accept an optional JSON body `{"queue": "name"}` when the
job id alone is ambiguous (Redis mode keys jobs per queue).

### Enqueue

| Method | Path | Description |
|---|---|---|
| POST | `/api/enqueue` | Enqueue a job. Scope `jobs_write`. |

```json
{ "kind": "emails.send", "args": { "to": "a@b.test", "subject": "hi" }, "queue": "mailers" }
```

`args` must fit the kind's payload schema. When the dashboard process knows
the kind, the payload is validated before the job is stored and a mismatch is
rejected with `400 bad_args`, because the worker could never run it. A kind
the dashboard does not know is accepted: the worker tier owns that kind's
schema.

When the kind is known, its own `queue` and `max_attempts` are used unless
the request overrides the queue. The attempt budget is an upper bound the
worker enforces whatever the row says, so a kind that declares a smaller
budget than the row still gets the smaller one.

### Schedules

| Method | Path | Description |
|---|---|---|
| GET | `/api/schedules` | List configured schedules. |

Schedules live in the worker process, not the broker, so the server tier
cannot address them by id: there is no run-now endpoint.

### Live stream

| Method | Path | Description |
|---|---|---|
| GET | `/api/live?queue={name}` | Server-sent events: claim, complete, dead. Requires `jobs_read`. |

### Session

| Method | Path | Description |
|---|---|---|
| POST | `/login` | `{"username": "...", "password": "..."}`; returns a CSRF token and sets cookies. |
| POST | `/logout` | Drops the session. |
| GET | `/auth/oidc` | Redirects to the OIDC provider (when configured). |
| GET | `/auth/oidc/callback` | OIDC redirect target. |

## Status codes

| Code | Meaning |
|---|---|
| 200 | Success |
| 400 | Bad request (malformed body, missing id, bad OIDC state) |
| 401 | Unauthenticated, or the OIDC provider rejected the login |
| 403 | Authenticated but not permitted (missing scope, viewer role, bad CSRF, readonly mode) |
| 404 | Unknown route or job |
| 409 | Conflict (for example, cancelling a job that already finished) |
| 429 | Login lockout after repeated failures |
| 500 | Broker or internal error |
| 501 | Queue control not supported by the configured broker |
| 503 | `broker_down` |

## Examples

```sh
KEY='opskey.s3cret'

curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:9484/api/queues
curl -s -H "Authorization: Bearer $KEY" 'http://127.0.0.1:9484/api/jobs?status=dead&limit=20'

curl -s -X POST -H "Authorization: Bearer $KEY" \
  -H 'content-type: application/json' \
  -d '{"kind":"emails.send","args":{"to":"a@b.test","subject":"hi"}}' \
  http://127.0.0.1:9484/api/enqueue

# SSE
curl -N -H "Authorization: Bearer $KEY" 'http://127.0.0.1:9484/api/live?queue=default'
```

Every mutating call is recorded in the job's event trail with the acting
credential, so an operator action is auditable after the fact.
