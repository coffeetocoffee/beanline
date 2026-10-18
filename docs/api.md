# REST API

The dashboard binary serves the UI, the REST API, the SSE stream, and the
Prometheus endpoint on one port (default `127.0.0.1:9484`).

## Authentication

| Surface | Credential |
|---|---|
| UI (`/`, `/login`) | Session cookie (`beanline_session`) plus `x-csrf-token` on POSTs |
| `/api/*` | Session cookie, or `Authorization: Bearer <prefix>.<secret>` |
| `/metrics`, `/healthz`, `/readyz` | Open |

API keys carry scopes: `jobs_read`, `jobs_write`, `queues_control`.

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
| GET | `/api/queues` | Depth and state per queue. |
| POST | `/api/queues/{name}/pause` | Stop claiming from a queue. |
| POST | `/api/queues/{name}/resume` | Resume claiming. |

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

### Schedules

| Method | Path | Description |
|---|---|---|
| GET | `/api/schedules` | List configured schedules. |
| POST | `/api/schedules/{id}/run` | Fire a schedule now. |

### Live stream

| Method | Path | Description |
|---|---|---|
| GET | `/api/live?queue={name}` | Server-sent events: claim, complete, dead. |

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
