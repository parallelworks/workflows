# Multi-Site Ray Cluster

Unified compute fabric across ACTIVATE resources using [Ray](https://ray.io). Deploys
a Ray head node on any resource, connects workers from one or more additional sites
via SSH tunnels, and provides a live dashboard showing cluster topology and task
placement.

The dashboard is served through a **`pw` endpoint** named `ray-cluster-<run-slug>`,
registered by the head job itself (`pw endpoints run` wraps the dashboard; there is no
`script_submitter`). Unlike the other compute-cluster workflows here, the **run holds
the cluster**: it stays `running` while the head, the dashboard and the workers are
alive, and **cancelling the run is the teardown** — its cleanup steps stop Ray, kill the
dashboard (which deregisters the endpoint) and cancel every SLURM/PBS worker job, local
and remote. This is the Kubernetes workflows' lifecycle.

## Architecture

```
                ACTIVATE Workflow
                      |
           +----------+----------+------------ ...
           v          v          v
        Site 1      Site 2     Site N
       Ray HEAD    Ray WORKER  Ray WORKER
       Dashboard   (SSH/SLURM) (SSH/SLURM)
           |          |          |
           +--- Ray Cluster -----+
                      |
              Workload Options:
              - Fractal rendering (visual)
              - Mathematical benchmark (charts)
              - Cluster only (bring your own workload)
```

## Quick Start

1. Add this workflow to your ACTIVATE account
2. Configure:
   - **Head Node**: Select any resource — runs the Ray coordinator + dashboard (no compute)
   - **Compute Workers**: Add one or more worker sites (SSH, SLURM, or PBS resources)
   - **Workload**: Choose fractal rendering, benchmark, or cluster-only mode
3. Click **Execute**
4. Open the endpoint `ray-cluster-<run-slug>` (Sessions page, or `pw endpoints list`) to
   view the live dashboard; the run's `complete` job prints its URL

## Workload Modes

### Fractal Rendering
Distributes Mandelbrot tile rendering across all sites. Tiles appear live on a canvas,
color-coded by which site rendered them.

### Mathematical Benchmark
Three phases:
1. **Task Throughput** — Bursts many small tasks to measure scheduling rate and placement distribution
2. **CPU Compute** — Matrix multiplications (NumPy) measuring GFLOPS per node
3. **Scaling Test** — Compares multi-site vs single-site throughput

### Cluster Only
Deploys the Ray cluster with no built-in workload. The dashboard shows connection
instructions with copy-paste commands for SSH tunnels, Ray job submission, and direct
head node access. Use this mode to run your own Ray jobs, training scripts, or
interactive workloads; optionally run a user script on the head node once the cluster
is ready.

## Worker Dispatch

Each worker node registers **1 task slot** with Ray. Ray handles placement across
nodes; tasks use internal parallelism (OpenMP, MPI, PyTorch, etc.) for multi-core/GPU
work within each node.

Worker dispatch modes:
- **SSH**: Direct connection to the remote host (single node per site)
- **SLURM**: Submit via `sbatch` with configurable partition, nodes, GPUs per node and walltime
- **PBS**: Submit via `qsub` with configurable directives

A worker site on the **same resource as the head** is submitted to that resource's
scheduler directly (no tunnels). A worker site on a **different resource** is reached
with `pw ssh` from the head: the head opens the SSH tunnels, clones this repository
there (sparse, `workflows/ray-cluster/app`) to run `setup.sh`, and the workers connect
back through unique loopback IPs (`127.0.X.Y`) for multi-node support. The head needs
the platform SSH key (`~/.ssh/pwcli`) for that, which the user workspace has.

## Adding workers to a running cluster

`yamls/<variant>_add_worker.yaml` attaches more worker sites to a cluster that is
still running. Select the resource that runs the head, leave **Cluster Job Directory**
on `auto` (the latest job directory with a Ray head is used) or point it at the
cluster run's job directory, and add the new sites. The added workers connect to the
existing head and appear in its dashboard; this run completes once they are dispatched
and the workers stay attached. Same-resource workers are SLURM/PBS jobs whose ids are
also recorded in the cluster run's `slurm_jobids`, so cancelling the cluster run cancels
them too.

## Dashboard

- **Cluster tab** — Node topology grouped by site, task placement bar chart, throughput over time
- **Connect tab** — SSH tunnel commands, Python examples, Ray Jobs CLI, cluster info table (cluster_only mode)
- **Logs tab** — Per-site worker setup and connection logs, streamed live
- **Ray Dashboard tab** — Proxied Ray native dashboard (port 8265)

## Files

```
workflows/ray-cluster/
├── yamls/
│   ├── general.yaml            # Multi-site cluster: standard cloud/on-prem SLURM & PBS clusters
│   ├── hsp.yaml                # Same, HSP form (SLURM account/QoS fields, DSRC hints)
│   ├── general_add_worker.yaml # Attach workers to a running cluster
│   └── hsp_add_worker.yaml
├── app/                        # The only subtree a run checks out
│   ├── setup.sh                # Install Ray + NumPy via uv/pip (handles old Python)
│   ├── start_ray_head.sh       # Start Ray head (--num-cpus=0) + dashboard
│   ├── dispatch_workers.sh     # Connect workers from all sites (SSH/SLURM/PBS)
│   ├── run_benchmark.sh        # Run benchmark, POST results to dashboard
│   ├── benchmark.py            # Ray distributed benchmark + fractal tasks
│   ├── dashboard.py            # FastAPI live dashboard server (WebSocket)
│   ├── stream_logs.py          # Tee worker SSH output into the dashboard's Logs tab
│   ├── check_shell.sh          # POSIX sh shell-compat check (bash present, warn on csh/tcsh)
│   ├── diagnose_cluster.py     # Ray cluster health checker
│   ├── gpu_hello.py            # Example GPU job to submit to the cluster
│   └── templates/index.html    # Dashboard UI
├── tests/<variant>/            # End-to-end tests (see Testing)
├── thumbnails/ray-cluster.png
├── diagnose.sh                 # Developer tool: run diagnose_cluster.py on a live run over pw ssh
├── generate-thumbnail.py       # Developer tool: regenerate the thumbnail
├── ROADMAP.md
└── README.md
```

## Variants

`yamls/general.yaml` targets standard cloud and on-prem SLURM/PBS clusters: SLURM
account, QoS and constraints go in the **Additional Directives** editor as `#SBATCH`
lines, PBS accounts as `#PBS -A`. `yamls/hsp.yaml` is the HSP (`activate.hpc.mil`)
form: it adds the SLURM **Account** and **QoS** fields and a PBS **Account** field per
worker site and pre-fills the DSRC `--constraint=mla` hint. The orchestration and
scripts are identical; on a cloud cluster the two variants behave the same. The
`*_add_worker.yaml` forms differ in the same way.

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/ray-cluster/yamls/general.yaml" -i '{
  "head": {"resource": "pw://<user>/<cluster>"},
  "workers": [{"resource": "pw://<user>/<cluster>", "scheduler": true,
               "slurm": {"partition": "compute", "nodes": 1, "time": "01:00:00"}}],
  "ray_settings": {"ray_version": "2.40.0"},
  "workload_settings": {"workload_type": "cluster_only"}
}'
pw workflows runs cancel <slug>     # tears the cluster down
```

## Testing

Tests live under `tests/<variant>/` and run with the repository's runner
(`tools/tests/README.md`). Because the run holds the cluster, the tests set
`_test.ready_job`: the `complete` job completing while the run is still `running`
means the head came up, the `wait_for_endpoint` subworkflow saw the endpoint answer,
the SLURM worker joined and the benchmark ran across it; the runner also checks that
the endpoint is listed, then cancels the run and verifies that no endpoint wrapper,
Ray, dashboard or dispatcher process and no SLURM job is left on the resource.

The `*_add_worker` tests need a running cluster: keep one from the main test, run the
add-worker test against it, then cancel the cluster run.

```bash
python3 tools/tests/run-workflow-test.py --keep workflows/ray-cluster/tests/general/gcp-head-gcp-worker.json
python3 tools/tests/run-workflow-test.py workflows/ray-cluster/tests/general_add_worker/gcp-worker.json
pw workflows runs cancel <slug of the kept run>
```

## Debugging

Everything is in the run's job directory on the head resource (`~/pw/jobs/<run-slug>/`
for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/` for registered ones):
`RAY_HEAD_IP`, `SESSION_PORT`, `HOSTNAME`, `PYTHON_VERSION` and `RAY_VENV_DIR` are the
coordination files the jobs and the add-worker workflow read, `ENDPOINT_NAME` the
endpoint's name and `dashboard.pid` the `pw endpoints run` wrapper's PID,
`logs/dashboard.log` the wrapper's and the dashboard's output,
`logs/worker_local_<i>.out` a same-resource SLURM worker's
output, and `slurm_jobids` the SLURM jobs the cleanup cancels. Remote worker sites
keep theirs under `~/pw/jobs/ray_worker_remote/` on their own login node. From
anywhere:

```bash
pw workflows runs logs <slug> --job start_ray_head
pw workflows runs logs <slug> --job dispatch_workers
pw workflows runs errors <slug>
```

`diagnose.sh <run-slug>` runs `diagnose_cluster.py` inside a live run over `pw ssh`.

## Shell Compatibility

The workflow requires **bash** on every node (head and workers). It supports users
whose **login shell** is bash, sh, or tcsh/csh — the scripts do not care about the
interactive login shell, only that `/bin/bash` exists.

How it stays compatible:
- Every entry-point script starts with `#!/bin/bash` and re-execs under bash if invoked
  from a non-bash parent: `if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi`.
- Remote dispatch uses `ssh host 'bash -s' < script.sh` — bypasses the remote login shell entirely.
- Scheduler jobs (SLURM/PBS) carry `#!/bin/bash` shebangs, which the scheduler honors
  regardless of the submitting user's shell.
- `app/check_shell.sh` runs at head-node startup to confirm `/bin/bash` is available
  and print a note if `$SHELL` is in the csh family.

Caveat for tcsh users: sourcing the Python venv interactively
(`source .venv/bin/activate`) fails under tcsh because the script uses bash `export`.
Use `source .venv/bin/activate.csh` instead, or drop into bash with `bash -l`.

## Provenance

Moved from the standalone `parallelworks/ray-cluster` repository (`main` @ `98bb3dd`,
2026-07-22). Its `scripts/` became `app/`, `workflow.yaml` became `yamls/hsp.yaml`
(the form already carried the HSP fields) with `yamls/general.yaml` derived from it,
and `add_worker.yaml` became the two `*_add_worker.yaml` forms. The scripts changed
where they locate themselves and each other (`SCRIPT_DIR` and the remote worker clone
point at `workflows/ray-cluster/app` in this repository; `RAY_REPO_URL` /
`RAY_REPO_BRANCH` override the clone target), in two behaviors the tests exposed (the
worker-site ssh calls disable connection multiplexing, and the add-worker mode no
longer leaves a log streamer behind), and in how the dashboard is exposed: the source
registered a platform session (`sessions:` block + `parallelworks/update-session`);
here `start_ray_head.sh` wraps the dashboard in `pw endpoints run` pinned to the port
it already allocated, and a `wait_for_endpoint` job replaces `update_session`. The
add-worker YAMLs also gained the fixes that make same-resource workers work (venv
marker, cleanup only on failure, job ids registered with the cluster run). Details and
test results: `MIGRATION.md`.
