# Metabase

[Metabase](https://www.metabase.com) business intelligence server (questions, dashboards,
SQL editor) on a compute cluster or a Kubernetes cluster, served through a `pw` endpoint
named `metabase-<run-slug>`. Open the endpoint URL to run Metabase's setup wizard (admin
account, first database connection).

| YAML | Runs on |
|---|---|
| `yamls/general.yaml` | a SLURM/PBS cluster: the login node or a scheduler job |
| `yamls/general_k8s.yaml` | the same cluster path or a Kubernetes cluster, from one form |

## Compute clusters

The run completes once `/api/health` answers; the container runs until
`pw endpoints delete metabase-<run-slug>`.

- `app/controller.sh` creates the data directory on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job: pulls the image
  and runs it with Docker Compose behind `pw endpoints run`. The container runs as your
  user (`MUID`/`MGID`), so the files it writes belong to you.

Form options:

- **Data Directory** (default `${HOME}/metabase`): Metabase's H2 application database
  and plugins. Reuse it to keep users, questions and dashboards across sessions.
- **Metabase Image** (default `metabase/metabase:v0.64.1`).
- **Environment Variables**: extra `MB_*` settings, one per line, e.g. `MB_DB_TYPE` and
  `MB_DB_CONNECTION_URI` for a PostgreSQL application database instead of H2.

Requirements: Docker with the Compose plugin on the service node (directly or through
`sudo`) and internet access there on the first launch. Metabase does not serve under a
URL prefix, so the endpoint must be a subdomain one (the default).

## Kubernetes

The workflow creates a Deployment from the image with Metabase on the configured port
(default 3000) and a `pw` client sidecar that publishes it as the endpoint, waits for the
pod and for `/api/health`, and streams the pod logs for the life of the deployment. The
application database and plugins live on the PersistentVolumeClaim (new or existing,
mounted at `/mnt` by default). Memory: the JVM takes most of the pod's memory limit as
heap; the defaults are 1Gi requested and 2Gi limit. Cancelling the run is the teardown:
Deployment, Secret and (unless persisted) PVC are deleted and the endpoint disappears
with the sidecar.

## Tests

`tests/general/` and `tests/general_k8s/` hold one test per form path
(`python3 tools/tests/run-workflow-test.py <test.json>`): login node and SLURM job on
`pw://alvaro/gcpsmall`, the Kubernetes lane on `k3sgpu`.
