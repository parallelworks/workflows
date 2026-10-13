# File Browser (filebrowser/filebrowser) in Docker

> From `workflows/filebrowser` (2026-10-07), image `filebrowser/filebrowser:v2.50.0`; its
> `app/start-template.sh` is the working copy of all of this.

- Entrypoint `tini -- /init.sh` as uid 1000: copies `/defaults/settings.json` (port 80,
  database `/database/filebrowser.db`, root `/srv`) to `/config/` when missing and execs
  `filebrowser --config=/config/settings.json "$@"`. Run it as the workflow user
  (`user: "<uid>:<gid>"`, directories owned by that user) so created files are theirs;
  the only trace is a `cp: can't preserve ownership` warning.
- Flags are `FB_` environment variables (`FB_BASE_URL`, `FB_NOAUTH`). `FB_BASE_URL`
  takes no trailing slash: `${PW_ENDPOINT_PATH%/}`. `GET /` and `GET /health` answer
  200 in both auth modes, so `wait_for_endpoint`'s defaults fit.
- `--noauth` and `--password` (a hash) act only when the database is created; v2.50.0
  prints a random admin password otherwise. To apply a form choice on every start, use
  the CLI through `docker compose run --rm -T <service> ...`: `config init
  --auth.method=…` + `users add admin <pw> --perm.admin` on a new database (noauth
  signs everyone in as user 1); `config set --auth.method=…` + `users update admin
  --password <pw>` on an existing one. Keep those lines out of `set -x`.
- The container belongs to dockerd: `cancel.sh` runs `docker compose -p <project> down
  --remove-orphans` (no compose file needed) and a foreground `compose logs -f` keeps
  the endpoint alive, as in `open-notebook`.
