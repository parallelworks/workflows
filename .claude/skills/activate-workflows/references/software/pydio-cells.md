# Pydio Cells (pydio/cells) with MySQL in Docker

> From `workflows/pydio-cells` (2026-10-09), images `pydio/cells:5.1.0` and `mysql:8.4`;
> its `app/start-template.sh` is the working copy of all of this.

- Entrypoint `tini -- docker-entrypoint.sh cells start`, as root by default. It runs
  `cells admin config check`; while that fails it swaps `cells start` for `cells
  configure`, which installs from `CELLS_INSTALL_YAML` (`frontendlogin`,
  `frontendpassword`, `dbconnectiontype: tcp`, `dbtcp*`) and **exits**. Install with a
  one-shot `docker compose run --rm -T -v <conf>:/pydio/config/install.yml:ro -e
  CELLS_INSTALL_YAML=... cells`, then `compose up -d`; a restart policy also works but
  loops forever on a failed install. The admin password only applies at install.
- Runs as any uid (`user: "<uid>:<gid>"`, plus `HOME: /var/cells` or it warns about
  `/.local`), as does `mysql:8.4` on a user-owned datadir. Pre-create every nested
  bind-mount point under `/var/cells` as that user, or Docker makes the parent root's and
  the install fails with `mkdir /var/cells/data/pydiods1: permission denied`.
- `CELLS_NO_TLS=1`, `CELLS_SITE_BIND=0.0.0.0:8080`, `CELLS_SITE_EXTERNAL=<public URL>`
  (share links; applied on every start). The web client's URLs are all relative to `/`
  (`<base href="/">`, `ENDPOINT_REST_API: /a`, `/io`, `/ws/event`), so a subdomain
  endpoint needs no proxy; a URL prefix would need nginx `sub_filter` rewriting.
- `GET /` answers 200 with any `Authorization: Bearer` header; the API (`/a/...`) answers
  401 to a bearer token that is not its own. `wait_for_endpoint`'s defaults fit.
- A host directory becomes browsable only through a **structured** datasource (the
  installer creates flat ones) and a workspace, over REST as admin: `POST
  /a/frontend/session` (`{"AuthInfo":{"login","password","type":"credentials"}}` →
  `JWT`), `POST /a/config/datasource/<name>` (`StorageConfiguration.folder` inside the
  container, `FlatStorage: false`), wait for `POST /a/tree/admin/list` on it, then `PUT
  /a/workspace/<slug>` with `RootNodes {"DATASOURCE:<name>": ...}` and `Attributes
  {"DEFAULT_RIGHTS":"rw"}` (the backend creates the ROOT_GROUP ACLs from it). Structured
  storage writes a `.pydio` file into every folder. Host-side changes appear on restart
  or `cells admin datasource resync -d <name>`. `CELLS_MINIO_ALLOW_CROSSMOUNT=true`
  lets that folder sit on another filesystem than `/var/cells/data`.
- MySQL is reachable from the host on its container address: no constant password.
- `docker compose logs -f cells` exits when the container stops, so it is the endpoint's
  liveness process; `cancel.sh` runs `compose down --remove-orphans`.
