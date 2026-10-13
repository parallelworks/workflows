# Multi-Site Ray Cluster

Unified compute fabric across ACTIVATE resources using [Ray](https://ray.io). Deploys
a Ray head node on any resource, connects workers from one or more additional sites
via SSH tunnels, and provides a live dashboard showing cluster topology and task
placement.

The cluster lives behind a **`pw` endpoint** named `ray-cluster-<run-slug>`, like every
other service in this repository: one start script, submitted through
`script_submitter` on the head resource's login node, installs Ray, starts the head,
dispatches the workers and wraps the dashboard in `pw endpoints run`. The **run
completes** once the endpoint answers and the workload step is done (the benchmark ran,
or the first worker joined in `cluster_only` mode); the cluster keeps running after it.
**`pw endpoints delete ray-cluster-<run-slug>` is the teardown**: it kills the
dashboard wrapper, the start script's trap runs `cancel.sh`, and a detached
`teardown.sh` cancels every SLURM/PBS worker job (same-resource and remote, including
sites attached later by add_worker), stops Ray and removes the endpoint. Cancelling the
run before the endpoint is up tears down the same way. In `cluster_only` mode with
**Run User Script** on and **Keep Cluster Alive** off, the run itself deletes the
endpoint when the script finishes (a batch job), and fails if the script failed.

Good to know:

- **One cluster head per host.** Ray's head is host-wide: starting a head runs
  `ray stop --force` and kills any other Ray on that host, and the head's health check
  (`ray status`) reads whichever GCS answers on the host. Run a second cluster with its
  head on another resource (another cluster, or the workspace).
- **One Ray worker per compute node.** A worker starts with `ray stop --force`, so a
  second worker job that the scheduler places on a node already running one replaces it
  instead of adding capacity (upstream behaviour). This matters most for add_worker on
  the head's resource: add `#SBATCH --exclusive` to the worker row's directives to get a
  node of its own.
- **If the Ray head dies**, the head's health check notices after three failed checks
  (a few minutes: each check against a dead GCS takes about 45 s to time out), stops
  the dashboard and tears the workers down. The endpoint then stays listed as
  `stopped`, because the run that registered it has ended; `pw endpoints delete
  ray-cluster-<run-slug>` removes the entry.
- **Cancelling the run** before it completes tears the cluster down (before the
  endpoint is up, the script submitter's cleanup does it; after, the benchmark or
  worker-wait step deletes the endpoint). Once the run has completed, only the
  endpoint delete stops the cluster.

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
5. When done, `pw endpoints delete ray-cluster-<run-slug>` (or delete the session in the
   UI) tears the whole cluster down

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
also recorded in the cluster run's `slurm_jobids`; a remote site's SSH tunnel session
is detached from the run (its output goes to `logs/dispatch_<site>.out` in the
add-worker run's job directory) and its rows are appended to the cluster run's
`added_workers.jsonl`. Cancelling the cluster run therefore tears down the added
workers too. Add one site per remote resource: a second dispatch to a resource that
already hosts a remote worker replaces that worker's tunnels.

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
│   ├── noaa.yaml               # Same, NOAA form (account/QoS on on-prem sites, /contrib/pw installs)
│   ├── general_add_worker.yaml # Attach workers to a running cluster
│   ├── hsp_add_worker.yaml
│   └── noaa_add_worker.yaml
├── app/                        # The only subtree a run checks out
│   ├── start-template.sh       # The submitted start script: writes cancel.sh, runs start_ray_head.sh
│   ├── teardown.sh             # Detached teardown run by cancel.sh (workers, head, endpoint)
│   ├── setup.sh                # Install Ray + NumPy via uv/pip (handles old Python)
│   ├── start_ray_head.sh       # Start Ray head (--num-cpus=0), dashboard endpoint, dispatcher
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
worker site and pre-fills the DSRC `--constraint=mla` hint. `yamls/noaa.yaml` is the
NOAA (`noaa.parallel.works`) form: it submits through the `noaa` script submitter,
shows the SLURM **Account** and **QoS** fields only for on-prem (`existing`) worker
resources, and installs Ray under `/contrib/pw` on a head that has it (NOAA's shared
software directory; elsewhere the default applies). The orchestration and scripts
are identical; on a cloud cluster the three variants behave the same. The
`*_add_worker.yaml` forms differ in the same way (the install directory does not
apply there: added same-resource workers reuse the cluster's Ray environment, and a
remote site installs in its own default location).

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/ray-cluster/yamls/general.yaml" -i '{
  "head": {"resource": "pw://<user>/<cluster>"},
  "workers": [{"resource": "pw://<user>/<cluster>", "scheduler": true,
               "slurm": {"partition": "compute", "nodes": 1, "time": "01:00:00"}}],
  "ray_settings": {"ray_version": "2.40.0"},
  "workload_settings": {"workload_type": "cluster_only"}
}'
pw endpoints delete ray-cluster-<slug>     # tears the cluster down
```

## Testing

Tests live under `tests/<variant>/` and run with the repository's runner
(`tools/tests/README.md`) on its standard criterion: the run completes (head up,
`wait_for_endpoint` saw the endpoint answer, the SLURM worker joined and the benchmark
ran across it, or `cluster_ready` fired) and `ray-cluster-<run-slug>` is listed; the
runner then deletes the endpoint and verifies that no endpoint wrapper, Ray, dashboard,
dispatcher or start-script process and no SLURM job is left on the resource. The batch
tests (`defaults-user-script`) and the failure-path tests (`fail-bad-partition`,
`fail-user-script`, with `_test.expect: error`) expect no endpoint: the workflow tears
the cluster down itself.

`tests/general/defaults-workspace-head.json` is the form's defaults as the UI sends
them (workspace head, one gcpsmall worker with the default row, `cluster_only`);
`tests/hsp/defaults-user-script.json` runs the user-script path with a Ray job that
fails unless its tasks ran on the worker. The `*_add_worker` tests need a running
cluster: keep one from a main test (`--keep`; `head-only-workspace.json` for the
remote-site add), run the add-worker test against it, then delete the endpoint.

```bash
python3 tools/tests/run-workflow-test.py --keep workflows/ray-cluster/tests/general/gcp-head-gcp-worker.json
python3 tools/tests/run-workflow-test.py workflows/ray-cluster/tests/general_add_worker/gcp-worker.json
pw workflows runs cancel <slug of the kept run>
```

## Debugging

Everything is in the run's job directory on the head resource (`~/pw/jobs/<run-slug>/`
for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/` for registered ones):
`RAY_HEAD_IP`, `SESSION_PORT`, `HOSTNAME`, `PYTHON_VERSION` and `RAY_VENV_DIR` are the
coordination files the jobs and the add-worker workflow read, `workers.json` the
worker rows, `ENDPOINT_NAME` the endpoint's name and `dashboard.pid` the
`pw endpoints run` wrapper's PID, `DISPATCH_FAILED` a marker the dispatcher leaves when
it gave up, `logs/dashboard.log` the wrapper's and the dashboard's output,
`logs/dispatch.out` the dispatcher's, `logs/teardown.log` the teardown's
(`TEARDOWN_DONE` when it finished), the start script's own output
`subworkflows/session_runner/step_0/run.<id>.out`,
`logs/worker_local_<i>.out` a same-resource SLURM worker's
output, and `slurm_jobids` the SLURM jobs the cleanup cancels. Remote worker sites
keep theirs under `~/pw/jobs/ray_worker_remote/` on their own login node. From
anywhere:

```bash
pw workflows runs logs <slug> --job session_runner     # the start script, until the endpoint came up
pw workflows runs logs <slug> --job cluster_ready      # worker wait (with the dispatcher output) and user script
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

Moved from the standalone `parallelworks/ray-cluster` repository (`main` @ `98bb3dd`):
`scripts/` became `app/`, `workflow.yaml` the variant YAMLs and `add_worker.yaml` the
`*_add_worker.yaml` forms, and the dashboard moved from a platform session to a `pw`
endpoint. What else changed, and the test results: `MIGRATION.md`.
