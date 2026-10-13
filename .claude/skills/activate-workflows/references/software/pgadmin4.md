# pgAdmin 4 (`dpage/pgadmin4`) in Docker

> From `workflows/pgadmin4` (2026-10-12), image `dpage/pgadmin4:9.18`; its
> `app/start-template.sh` is the working copy.

- **Runs as any uid in group 0.** The image is built for OpenShift's arbitrary uids:
  `/var/lib/pgadmin` and `/pgadmin4/config_distro.py` are group-root writable, so
  `user: "<uid>:0"` in compose runs pgAdmin as the workflow user on a bind-mounted data
  directory the user owns (files come out `<user>:root`). 9.18's entrypoint also takes
  `PUID`/`PGID` when the container starts as root; the arbitrary-uid path works on older
  tags too. A non-zero gid cannot write `config_distro.py`.
- **The account is created once.** With no `/var/lib/pgadmin/pgadmin4.db` the entrypoint
  creates the account from `PGADMIN_DEFAULT_EMAIL` and `PGADMIN_DEFAULT_PASSWORD` or
  `PGADMIN_DEFAULT_PASSWORD_FILE` (one or the other, never both; a mode-600 compose
  `secrets` file works) and imports `PGADMIN_SERVER_JSON_FILE` for it (log line
  `Added 0 Server Group(s) and 1 Server(s)`; format `{"Servers": {"1": {"Name", "Group",
  "Host", "Port", "MaintenanceDB", "Username", "SSLMode"}}}`). A reused data directory
  keeps the account and the server list; `PGADMIN_REPLACE_SERVERS_ON_STARTUP=True`
  re-imports the file on every start but drops the servers the user added. No minimum
  password length is enforced at setup (a 3-character password logs in).
- **Email validation**: `email_validator` with `GLOBALLY_DELIVERABLE` rejects special-use
  domains (`.local`, `.test`, `.invalid`, `localhost`) with `does not appear to be a valid
  email address` and the container exits; `example.com` passes
  (`PGADMIN_CONFIG_ALLOW_SPECIAL_EMAIL_DOMAINS` lifts it).
- **Port and mail**: `PGADMIN_LISTEN_PORT` (default 80 through a setcap'd python; the
  entrypoint falls back to 8080 under `no-new-privileges`), `PGADMIN_DISABLE_POSTFIX=true`
  (the default starts postfix through `sudo` for password-reset mail).
- **Routes**: `/misc/ping` answers `200 PING` without a login, also with an
  `Authorization: Bearer` header, so it is the health route; `/` answers `302
  /login?next=/`. Cold start (account creation) took about 35 s on gcpsmall, a warm start
  about 15 s.
- **Logging in by HTTP** (verified 9.18): `GET /login` with a cookie jar; the page is React
  and carries the CSRF token in a JSON blob as `"csrfToken": "..."` (there is no `<form>`
  or hidden input to scrape). `POST /authenticate/login` with the form fields `email`,
  `password` and `csrf_token` answers `302` to `/browser/` on success and `302` to `/login`
  on a wrong email or password (the `X-pgA-CSRFToken` header alone is rejected); `GET
  /browser/` with the jar then answers `200` or `302`. The start script checks a reused
  data directory's password this way before the endpoint registers.
- **Check before registering.** Once `pw endpoints run` starts, `wait_for_endpoint` sees
  `/misc/ping` answer and completes the run, so the login check has to precede it: the
  script picks a free loopback port, starts compose on it, checks, then runs
  `pw endpoints run --port <port> -- docker compose logs -f` (pitfalls.md, "Endpoints and
  the service").
