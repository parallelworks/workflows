# pgAdmin 4

The [pgAdmin 4](https://www.pgadmin.org) web client for PostgreSQL on a compute cluster or
a Kubernetes cluster, served through a `pw` endpoint named `pgadmin4-<run-slug>`. Open the
endpoint URL and log in with the form's **Email** and **Password**; then register servers
in pgAdmin, or have the form register one for you.

| YAML | Runs on |
|---|---|
| `yamls/general.yaml` | a SLURM/PBS cluster: the login node or a scheduler job |
| `yamls/general_k8s.yaml` | the same cluster path or a Kubernetes cluster, from one form |

## Compute clusters

The run completes once the account has logged in and pgAdmin answers on `/misc/ping`
through the endpoint; the container runs until `pw endpoints delete pgadmin4-<run-slug>`.

- `app/controller.sh` creates the data directory on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job. It pulls the
  image, starts it with Docker Compose on a port of the node's loopback, waits for
  pgAdmin, checks that the email and password log in, and only then publishes that port
  with `pw endpoints run --port`. The container runs as your user (in the image's root
  group, which the image is built for), so the data directory's files belong to you.

Form options:

- **Email** (default `admin@example.com`), **Password**: the account pgAdmin creates with
  a new data directory. **A data directory keeps the account it was created with**: a later
  run must use the same email and password, or it stops with an error before the endpoint
  registers. pgAdmin rejects emails on reserved domains (`.local`, `.test`, `localhost`).
- **Data Directory** (default `${HOME}/pgadmin4`): pgAdmin's `pgadmin4.db` (the account,
  the registered servers and their saved passwords, the preferences), its sessions, and
  `storage/<email>/`, the only directory its file dialogs see (backups, exports, imports).
  Reuse it to keep the setup of earlier sessions.
- **PostgreSQL Server to Register**: with a **Host**, one server is registered in pgAdmin
  when the data directory is new (a reused one keeps its own list), with the **Port**,
  **Maintenance Database** and **Username** given. For a
  [postgres](../postgres/) workflow run, that is the node and Database Port its log
  prints, as seen from the node pgAdmin runs on. pgAdmin asks for the password when you
  connect and can save it.
- **pgAdmin 4 Image** (default `dpage/pgadmin4:9.18`).

Requirements: Docker with the Compose plugin on the service node (directly or through
`sudo`) and internet access there on the first launch. pgAdmin is served at the URL root,
so the endpoint must be a subdomain one (the default).

## Kubernetes

**Not run yet.** No Kubernetes cluster was reachable when this workflow was written
(2026-10-12); `yamls/general_k8s.yaml` validates with `pw workflows run --dry-run` on both
lanes and its compute lane is tested. The Kubernetes lane follows the
[metabase](../metabase/) and [postgres](../postgres/) hybrids: a Deployment
(`strategy: Recreate`) with the pgAdmin container and a `pw` client sidecar that publishes
it as the endpoint; the PersistentVolumeClaim (new or existing) is mounted at
`/var/lib/pgadmin` from its `pgadmin4/` directory, which an init container gives to the
image's user (uid 5050, group 0); the password comes from a Secret
(`PGADMIN_DEFAULT_PASSWORD_FILE`); the readiness probe is `/misc/ping`. An existing volume
keeps the account it was created with; this lane does not check the login before the
endpoint registers. Cancelling the run is the teardown: Deployment, Secrets and (unless
persisted) PVC are deleted and the endpoint disappears with the sidecar. The defaults
request 512Mi and 500m CPU, with limits of 1Gi and 1 CPU.

## Tests

`tests/general/` holds one test per form path on `pw://alvaro/gcpsmall`
(`python3 tools/tests/run-workflow-test.py <test.json>`, with the password in
`PGADMIN_TEST_PASSWORD`): the login node (`gcp-controller`, which also registers a
server), a SLURM job (`gcp-compute`), and a wrong password on an existing data directory
(`gcp-wrong-password`: the run must fail and leave nothing behind, so run it after one of
the others has created `${HOME}/pgadmin4`). `tests/general_k8s/` holds the hybrid's
compute lane (`gcp-controller`) and its Kubernetes lane (`k3sgpu`, not run yet).
