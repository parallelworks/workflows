# File Browser (filebrowser/filebrowser) in Docker

> Learned porting `workflows/filebrowser` (2026-10-07): the `filebrowser/filebrowser:v2.50.0`
> image with Docker Compose behind a `pw` endpoint, probed by hand on gcpsmall before the
> YAML was written. The workflow's `app/start-template.sh` is the working copy of all of it.

## The image

- Entrypoint `tini -- /init.sh`, user `user` (uid 1000; the `UID`/`GID` environment
  variables in the image do nothing). `init.sh` copies `/defaults/settings.json` to
  `/config/settings.json` when missing (port 80, database `/database/filebrowser.db`,
  root `/srv`) and execs `filebrowser --config=/config/settings.json "$@"`, so a compose
  `command:` is File Browser arguments.
- Run it as the workflow user (`user: "<uid>:<gid>"`, directories owned by that user): files
  created through the UI then belong to the user, and the only trace is `cp: can't preserve
  ownership of '/config/settings.json'` in the log. The source workflow's `chown 1000:1000`
  needed root.
- Every flag is an `FB_` environment variable (`--baseURL` → `FB_BASE_URL`, `--noauth` →
  `FB_NOAUTH`). `GET /health` answers 200 (the image's healthcheck); `GET /` answers 200
  in both auth modes, so `wait_for_endpoint`'s defaults fit.
- `FB_BASE_URL` wants no trailing slash: `${PW_ENDPOINT_PATH%/}` is empty on a subdomain
  endpoint and the prefix on a path-based one, and the page's asset links carry it.

## Authentication is decided at quick setup

`--noauth` and `--password` (a bcrypt hash) only act when the database is created; a later
start ignores them, and v2.50.0 prints a random admin password in the log when none is
given. To make a form choice stick on every run, bootstrap and update the database with
the CLI through one-off containers (`docker compose run --rm -T <service> ...`):

```bash
filebrowser config init --auth.method=noauth|json     # creates the database, no user
filebrowser users add admin "<password>" --perm.admin  # noauth signs everyone in as user 1
filebrowser config set --auth.method=json              # existing database
filebrowser users update admin --password "<password>" # plaintext; hashed by the command
```

Checks: with `noauth`, `POST /api/login` without a body returns a token; with `json`, the
old password gets 403, the new one 200, and anonymous `/api/resources/` 401. Keep the
password lines out of `set -x` (`set +x` around them): the run log is visible.

## Teardown

The container belongs to dockerd, so `cancel.sh` runs `docker compose -p <project> down
--remove-orphans` (the project name alone suffices) and the generic trap calls it on
`pw endpoints delete`; the container was gone three seconds after the delete. A foreground
`docker compose logs -f` is the endpoint's liveness process, as in `open-notebook`.
