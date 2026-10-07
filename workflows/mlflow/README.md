# MLflow

Starts an [MLflow](https://mlflow.org) tracking server (UI and REST API) on a compute
cluster or a Kubernetes cluster and serves it through a `pw` endpoint named
`mlflow-<run-slug>`.

| YAML | Runs on |
|---|---|
| `yamls/general.yaml`, `hsp.yaml`, `noaa.yaml` | a SLURM/PBS cluster: the login node or a scheduler job |
| `yamls/k8s.yaml` | a Kubernetes cluster |
| `yamls/general_k8s.yaml` | either, from one form (the compute-cluster path of `general.yaml` plus the Kubernetes path of `k8s.yaml`) |

## Compute clusters

The run completes once the endpoint answers; the server keeps running until
`pw endpoints delete mlflow-<run-slug>`.

1. `app/controller.sh` runs on the login node: installs Miniforge and MLflow from
   conda-forge under the parent install directory (default
   `${HOME}/pw/software/.miniforge3-mlflow`) if missing, or loads an existing
   environment with the command you provide. The default installation is the
   environment pinned in `app/mlflow3.16.1-python3.14.7.yaml`, exported from a tested
   install and bootstrapped with the Miniforge release it came from.
2. `app/start-template.sh` runs on the login node or inside a scheduler job
   (SLURM/PBS, your choice in the form) and launches `mlflow server` behind
   `pw endpoints run`, with the backend store and the artifacts destination from the
   form (`--serve-artifacts`: clients log artifacts through the server, so they need no
   access to its storage).

The server listens on every interface of its node so jobs on the cluster can log to it
directly. Its in-cluster address is printed by the run and written to the `tracking_uri`
file in the job directory (`~/pw/jobs/<run-slug>/tracking_uri` for a CLI run). MLflow 3
rejects requests whose `Host` header or `Origin` it does not know (HTTP 403), so the
launcher allow-lists the endpoint host and the node's own names and addresses; a
`--allowed-hosts` or `--cors-allowed-origins` in **Additional Flags** replaces that list.

```bash
export MLFLOW_TRACKING_URI=$(cat ~/pw/jobs/<run-slug>/tracking_uri)   # http://<node>:<port>
```

From outside the cluster, point clients at the endpoint URL with a platform API key as
the bearer token, which the platform's login proxy accepts:

```bash
export MLFLOW_TRACKING_URI=https://<endpoint host>/
export MLFLOW_TRACKING_TOKEN=<your pw API key>
```

### Form options

- **Backend Store URI**: where experiments, runs, metrics and parameters are kept. A
  SQLAlchemy URI (default `sqlite:///${HOME}/mlflow/mlflow.db`; `postgresql://...`,
  `mysql://...`) or a local directory for MLflow's file store. Local directories are
  created when missing. Reuse the value across runs to keep the history.
- **Artifacts Destination**: where the server stores the artifacts logged through it
  (default `${HOME}/mlflow/artifacts`; `s3://`, `gs://`, `abfs://` work too).
- **Port**: a fixed port, e.g. `5000`, so the in-cluster address stays the same across
  runs; empty takes a free port.
- **Additional Flags**: anything else for
  [`mlflow server`](https://mlflow.org/docs/latest/cli.html#mlflow-server), e.g.
  `--workers 2` or `--app-name basic-auth`.
- **Enable server-side job execution?**: MLflow 3's job runner, which executes GenAI
  evaluation and scorer jobs on the server. Off by default: it is seven worker processes
  of about 250 MB each on top of the request workers (about 250 MB each, four by default),
  and experiment tracking does not use it.
- **Installation**: the pinned environment, the latest MLflow and Miniforge from
  conda-forge, or paste your own conda environment YAML. Or skip the installation and
  point at an existing environment with a load command (MLflow 3 needs Python 3.10 or
  newer). The noaa form also offers a `pip install --user` into the system `python`
  module on the on-premise clusters.

## Kubernetes

The workflow authenticates `kubectl` against the selected cluster, creates a Deployment
from the chosen image (default `ghcr.io/mlflow/mlflow:v3.17.0`, the official image)
running `mlflow server` on the configured port (default 5000), with a `pw` client sidecar
that publishes that port as the endpoint, waits for the pod to be ready and for the
endpoint to answer, and streams the pod logs into the run for the life of the
deployment.

Memory: each request worker is about 250 MB and the optional job runner about 1.8 GB,
so the form defaults to two workers, job execution off, and 1Gi requested / 2Gi limit;
a 1Gi limit with MLflow's own defaults (four workers, job runner on) is `OOMKilled` in a
restart loop while the endpoint answers 503. Raise the memory limit when you turn the
job runner on or add workers.

Storage: a PersistentVolumeClaim is mounted at the configured mount path (default
`/mnt`); create a new PVC (size, storage class) or select an existing one. The sqlite
backend store (`<mount path>/mlflow.db`) and the artifacts (`<mount path>/artifacts`)
live on it, so the tracking data outlives the pod.

Canceling the run is the teardown: it deletes the Deployment and the API key Secret, and
the endpoint disappears with the sidecar. A new PVC is also deleted unless you set
**Persist PVC After Completion**.

## Tests

`tests/<variant>/` holds one test per form path, run with
`python3 tools/tests/run-workflow-test.py <test.json>`: the compute-cluster variants on
`pw://alvaro/gcpsmall` (login node and SLURM job, pinned and latest installations) and
the Kubernetes lanes on `k3sgpu`.
