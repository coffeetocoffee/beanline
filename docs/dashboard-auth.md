# Dashboard authentication

The dashboard serves UI, REST, SSE, and `/metrics` from the same binary. Auth is
on by default; there is no unauthenticated mode unless nothing at all is
configured (and then only on a loopback bind).

## Local users

```sh
BEANLINE_DASH_USERS='ops:hunter2:admin;ro:hunter2:viewer'
```

Spec is `name:password:role`. Passwords are stored as argon2id PHC hashes, never
in plaintext. `admin` can mutate (retry, discard, cancel, enqueue, pause);
`viewer` is read-only. Five consecutive failures lock an account for 60 seconds.

## API keys

```sh
BEANLINE_DASH_KEYS='opskey:s3cret:jobs_read,jobs_write,queues_control'
```

Sent as `Authorization: Bearer <prefix>.<secret>`. Keys bypass CSRF (they are
not cookies) and are the right choice for automation and Prometheus scraping.

Scopes are enforced on every request. `jobs_read` allows reads; `jobs_write`
implies `jobs_read` and allows enqueue plus job actions; `queues_control`
allows queue pause/resume and grants no reads. An unknown or malformed key is
treated as unauthenticated (`401`); a valid key lacking the scope gets `403`.

## OIDC SSO (authorization code flow with PKCE)

Set the provider endpoints explicitly; there is no `.well-known` discovery, so
an unconfigured dashboard makes no outbound calls.

```sh
BEANLINE_DASH_OIDC_ISSUER='https://idp.example.com'
BEANLINE_DASH_OIDC_AUTHORIZE_ENDPOINT='https://idp.example.com/authorize'
BEANLINE_DASH_OIDC_TOKEN_ENDPOINT='https://idp.example.com/token'
BEANLINE_DASH_OIDC_USERINFO_ENDPOINT='https://idp.example.com/userinfo'
BEANLINE_DASH_OIDC_CLIENT_ID='beanline'
BEANLINE_DASH_OIDC_CLIENT_SECRET='...'
BEANLINE_DASH_OIDC_REDIRECT_URI='https://beanline.example.com/auth/oidc/callback'
BEANLINE_DASH_OIDC_SCOPE='openid profile email'          # default
BEANLINE_DASH_OIDC_EMAIL_DOMAINS='example.com,corp.test' # optional allowlist
BEANLINE_DASH_OIDC_DEFAULT_ROLE='viewer'                 # role for first sign-in
```

Routes the provider must register:

- Redirect URI: exactly `BEANLINE_DASH_OIDC_REDIRECT_URI`.
- The dashboard issues `state` and a PKCE `S256` challenge; the provider must
  echo `state` and allow public clients (no secret) as well as confidential ones.

How a sign-in works:

1. `GET /auth/oidc` mints a random `state` and a PKCE verifier, stores them for
   10 minutes, and 302-redirects to the provider.
2. The provider redirects back to `/auth/oidc/callback?code=...&state=...`.
3. The dashboard consumes the state (single use; a replay is rejected with
   `bad_request`), posts the code plus the verifier to the token endpoint, and
   calls userinfo with the access token.
4. The email is checked against `allowed_email_domains` if set. A matching local
   user keeps its role; an unknown identity is provisioned as
   `default_role` (viewer by default).
5. A session cookie (`HttpOnly`, `Secure`, `SameSite=Strict`, 24 h) and a CSRF
   cookie are set, and the browser lands on the dashboard.

Design notes:

- The access token is presented to the provider over TLS; no local signature
  verification of an `id_token` is performed, so the provider's userinfo
  endpoint is the identity source of truth.
- Pending authorizations expire after 10 minutes and there are at most 32 in
  flight; the oldest slot is reused rather than dropping a login.
- Configuring OIDC counts as "auth configured": a `0.0.0.0` bind is allowed,
  anonymous API reads are refused, and the UI shows a "sign in with SSO" link.

## Other controls

| Setting | Effect |
|---|---|
| `BEANLINE_DASH_READONLY` | All mutations refused, including for admins and API keys |
| `BEANLINE_DASH_BIND` | Default `127.0.0.1:9484`; a `0.0.0.0` bind with no users, keys, or OIDC is refused at startup |
| `BEANLINE_DASH_ENABLED` | Serve the dashboard from a worker process (the `server` command always serves it) |
| `BEANLINE_LOG_PAYLOAD` | Off by default; job args are not logged unless enabled |

Session cookies are `Secure`, so plain-HTTP access to the dashboard will not
persist a login. Terminate TLS in front of the dashboard, or use it over
loopback / an SSH tunnel.