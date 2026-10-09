# PostgreSQL

A [PostgreSQL](https://www.postgresql.org) server on a compute cluster or a Kubernetes
cluster, with the [pgweb](https://github.com/sosedoff/pgweb) SQL client served through a
`pw` endpoint named `postgres-<run-slug>`. Open the endpoint URL to browse tables and run
queries. Applications and `psql` connect to the database itself over TCP: a `pw` endpoint
carries HTTP only.

| YAML | Runs on |
|---|---|
| `yamls/general.yaml` | a SLURM/PBS cluster: the login node or a scheduler job |
| `yamls/general_k8s.yaml` | the same cluster path or a Kubernetes cluster, from one form |

When the run completes, its log shows two notices: the connection string, and the
command to reach the database from your computer.

## Compute clusters

The database listens on **Database Port** (default 5432) on the node it runs on:

- **From jobs on the cluster:** `postgresql://<user>@<node>:<port>/<database>`.
- **From your computer:** forward the port, then use any client:

  ```bash
  pw forward -L 5432:<node>:5432 pw://<owner>/<cluster>
  psql -h localhost -p 5432 -U postgres postgres
  ```

The run completes once pgweb answers on `/api/connection`, which it only does while it
holds a database connection. The server keeps running until
`pw endpoints delete postgres-<run-slug>`, which stops both containers. The data stays
in the data directory.

- `app/controller.sh` creates the data directory on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job. It pulls the
  images, starts PostgreSQL with Docker Compose and checks that the user and password log
  in (creating the database if it is missing). It then runs pgweb behind
  `pw endpoints run`. Both containers run as your user, so the database files belong to
  you. pgweb has no login of its own, so it only listens on the node's loopback, where
  the endpoint reaches it.

Form options:

- **User**, **Password**, **Database** (default `postgres`): the superuser and database
  created with a new data directory. **A data directory keeps the user and password it
  was created with**: a later run must use the same ones, or it stops with an error before
  the endpoint registers. A database that does not exist yet is created.
- **Database Port** (default 5432): the run stops with an error if the port is taken on
  the node.
- **Data Directory** (default `${HOME}/postgres`): the database cluster lives in its
  `pgdata/` subdirectory. Reuse it to keep your databases across sessions. Only one run at
  a time can serve a data directory. A second run stops with an error naming the run that
  holds it, because two servers on the same files would corrupt them.
- **PostgreSQL Image** (default `postgres:18`): the official image or one built on it,
  e.g. `pgvector/pgvector:pg18` or `postgis/postgis:18-3.6`. A data directory only opens
  with the major version that created it; upgrading needs `pg_upgrade` or a dump and
  restore.

Requirements: Docker with the Compose plugin on the service node (directly or through
`sudo`), internet access there on the first launch, and a filesystem for the data
directory that the node can lock and write.

## Kubernetes

The workflow creates a Deployment with three containers: PostgreSQL, pgweb, and a `pw`
client sidecar that publishes pgweb as the endpoint. It also creates a ClusterIP Service
named after the Deployment that exposes port 5432 inside the cluster. The workflow waits
for the database, checks the login and creates the database if it is missing, waits for
`/api/connection`, then streams the pod logs for the life of the deployment. The database
cluster lives on the PersistentVolumeClaim (new or existing, mounted at `/mnt` by
default, in `pgdata/`). With an existing PVC, the user and password are those of the run
that created it.

- **From pods in the cluster:**
  `postgresql://<user>@<deployment>.<namespace>.svc.cluster.local:5432/<database>`.
- **From your computer:**

  ```bash
  pw kube auth <cluster>
  kubectl port-forward -n <namespace> service/<deployment> 5432:5432
  psql -h localhost -p 5432 -U postgres postgres
  ```

The run log prints both with the real names. Cancelling the run is the teardown: the
Deployment, Service and Secrets are deleted, the PVC too unless it is persisted, and the
endpoint disappears with the sidecar. The defaults request 512Mi and 1 CPU for
PostgreSQL, with limits of 1Gi and 2 CPUs; pgweb and the sidecar request 50m CPU and 64Mi
each.

## Tests

`tests/general/` and `tests/general_k8s/` hold one test per form path
(`python3 tools/tests/run-workflow-test.py <test.json>`, with the password in
`POSTGRES_TEST_PASSWORD`): login node and SLURM job on `pw://alvaro/gcpsmall`, a wrong
password on an existing data directory (the run must fail and leave nothing behind), and
the Kubernetes lane on `k3sgpu`.
