# Dask on SLURM

Starts a [Dask](https://www.dask.org) cluster on a SLURM cluster with
[dask-jobqueue](https://jobqueue.dask.org): the scheduler and the
[Dask dashboard](https://docs.dask.org/en/stable/dashboard.html) run on the login
node, served through a `pw` endpoint named `dask-<run-slug>`, and the workers are
SLURM jobs the cluster submits as work arrives and cancels when it is done
(`SLURMCluster.adapt`). The run then submits demo workloads, so the dashboard shows
the worker jobs join, compute and leave, and completes with the cluster still running
(or stopped, by choice). It needs a SLURM cluster: the form says so when the selected
resource has no SLURM scheduler, and preprocessing fails before installing anything.

![A scheduler feeding three SLURM worker jobs](thumbnails/dask-slurm.png)

## How it works

1. **preprocessing**, on the login node, checks the resource is a SLURM cluster, installs
   Miniforge with Dask, distributed, dask-jobqueue and bokeh from conda-forge under the
   parent install directory (default `${HOME}/pw/software/.miniforge3-dask`) if missing,
   or takes the environment the form's load command provides, and writes `dask-env.sh`,
   the file that puts that Python on the PATH for the service and the workloads.
2. **session_runner** runs `app/start-template.sh` on the login node through the shared
   [`script_submitter`](../script_submitter/): `pw endpoints run` starts
   `app/dask_cluster.py`, which creates the `SLURMCluster` from the form's worker job
   settings, serves the dashboard on the endpoint's port, validates the worker job
   script with `sbatch --test-only` (a bad partition, account or QoS fails the run in
   seconds), sets the adaptive range of jobs, writes `scheduler.json` and waits.
3. **wait_for_endpoint** probes the dashboard URL until it answers, then releases the
   submitter so the service outlives the run.
4. **workload** runs `app/dask_demo.py` on the login node: it connects through the
   scheduler file, runs the chosen workloads and prints, every ten seconds, how many
   workers have joined and how many tasks remain. The first tasks make the cluster
   submit worker jobs; on a cloud cluster the nodes take minutes to boot, which the
   log and the dashboard both show. Once the work is done the workers above the
   minimum are retired and their jobs leave `squeue`. With **Keep the cluster alive**
   on, the run completes and the cluster keeps running; off, the run stops it (a
   `STOP` file next to the service closes the cluster, which cancels the worker jobs)
   and no endpoint is left behind.

A run that is cancelled or fails before the workloads finish stops its cluster the same
way. `cancel.sh` cancels any worker job (`scancel --name dask-<run-slug>`) a killed
service left behind.

## Form options

| Group | Input | Meaning |
|---|---|---|
| `cluster` | `resource` | the SLURM cluster; on `hsp` and `noaa` the top-level `resource` input |
| | `slurm.partition` | `--partition` of the worker jobs (empty: the cluster default) |
| | `slurm.cores`, `slurm.memory` | one worker job's cores and memory (`SLURMCluster` `cores`, `memory`): its Dask threads and the workers' memory limit |
| | `slurm.processes` | worker processes per job, each with `cores / processes` threads; empty for Dask's default |
| | `slurm.walltime` | `--time` of the worker jobs; a worker ends with its job and the cluster requests another while there is work |
| | `slurm.min_jobs`, `slurm.max_jobs` | the adaptive range of worker jobs (`adapt(minimum_jobs, maximum_jobs)`); with 0 every worker leaves once the work is done |
| | `slurm.mem_directive` | `true` to request `memory` from SLURM with `--mem`; off by default because the platform's cloud clusters have no memory accounting and reject it |
| | `slurm.interface` | network interface the scheduler and workers talk over (e.g. `ib0`); empty for the default route |
| | `slurm.scheduler_directives` | extra `#SBATCH` lines of the worker jobs (`job_extra_directives`) |
| | `slurm.account`, `slurm.qos`, `slurm.node_type` | `hsp` and `noaa` (`node_type` only `hsp`): `--account`, `--qos` and `--constraint` of the worker jobs, shown for on-prem `existing` resources |
| `service` | `workload` | `all`, `array`, `pi`, `dataframe` or `none` (start the cluster and complete the run) |
| | `workload_size` | `small`, `medium` or `large` (below) |
| | `workload_timeout` | minutes each workload may take, queueing and node boot included; past it the run fails and the cluster is stopped |
| | `keep_alive` | keep the scheduler and dashboard running after the run (default) or stop the cluster when the workloads are done |
| | `conda_install`, `parent_install_dir`, `conda_install_dir`, `conda_env`, `install_instructions`, `yaml` | the Miniforge installation: the pinned environment, the latest versions from conda-forge, or a pasted environment YAML |
| | `load_env` | with `conda_install` off, the command that puts a Python with dask, distributed, dask-jobqueue, bokeh, numpy and pandas on the PATH |

## Workloads

| Workload | What it does | small / medium / large |
|---|---|---|
| `array` | `mean(x @ x)` of a random `n x n` dask array: a dense matrix product, one task per block product, that keeps every core busy; the mean is about `n / 4` | `n` = 8,000 / 16,000 / 32,000 (1 / 8 / 66 TFLOP) |
| `pi` | Monte Carlo pi with `client.map`: many small independent tasks | 200 / 1,000 / 4,000 tasks of 10 million points |
| `dataframe` | a `groupby("name")` aggregation and `corr(x, y)` over `dask.datasets.timeseries`, one partition per day | one month / six months / two years of 1-second rows |

The workload log shows, per workload, the elapsed time, the workers and threads that
took part and when the first worker joined; the dashboard shows the task stream.

## Connecting to the cluster

The scheduler file is in the run's job directory on the login node
(`~/pw/jobs/<run-slug>/scheduler.json` for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/`
for registered ones). From any node of the cluster:

```bash
source ~/pw/jobs/<run>/dask-env.sh
python -c "from dask.distributed import Client; client = Client(scheduler_file='$HOME/pw/jobs/<run>/scheduler.json'); print(client)"
```

Work submitted through that client makes the cluster request worker jobs, up to the
maximum, which appear in `squeue` as `dask-<run-slug>`. Stop the cluster with
`pw endpoints delete dask-<run-slug>`.

## Files in the job directory

```
run.<id>.out            the service output: the worker job script, scheduler address, worker counts
scheduler.json          the scheduler's address, for Client(scheduler_file=...)
dask-worker.sbatch      the job script dask-jobqueue submits for each worker job
dask-worker-logs/       the worker jobs' output (one file per job)
dask-env.sh             puts the Python environment with Dask on the PATH
ENDPOINT_URL            the dashboard URL
logs/workload/          the workload step's output
```

## Variants

| File | Target |
|---|---|
| `yamls/general.yaml` | standard cloud and on-prem SLURM clusters |
| `yamls/hsp.yaml` | HSP (`activate.hpc.mil`): the `hsp` submitter; SLURM account, QoS and node type for the worker jobs on on-prem resources |
| `yamls/noaa.yaml` | NOAA (`noaa.parallel.works`): the `noaa` submitter; SLURM account and QoS; Miniforge in the cluster's shared software tree when the account can write there |

On a cloud cluster the three behave alike; `tests/hsp/` and `tests/noaa/` exercise
them there. PBS clusters and resources without a scheduler are not supported: the
workers are SLURM jobs.

## Run

```bash
pw workflows run "$PWD/workflows/dask-slurm/yamls/general.yaml" -i '{
  "cluster": {"resource": "pw://<user>/<cluster>",
              "slurm": {"partition": "compute", "cores": 2, "memory": "4GB", "walltime": "01:00:00",
                        "min_jobs": 0, "max_jobs": 4}},
  "service": {"workload": "all", "workload_size": "small", "keep_alive": true}}'
```

`pw workflows runs logs <slug> --job workload` has the workload output;
`pw workflows runs errors <slug>` the summary when the run failed.

## Tests

`tests/<variant>/`: the three workloads with the cluster kept alive, the pi workload
with the cluster stopped afterwards, the cluster alone, and the failure path of a
partition that does not exist, all on `pw://alvaro/gcpsmall`. Run them with
`tools/tests/run-workflow-test.py`.

## Files

- `app/controller.sh` — installs the environment (or takes the form's) and writes `dask-env.sh`
- `app/start-template.sh` — writes `cancel.sh` and starts the cluster service behind the endpoint
- `app/dask_cluster.py` — the service: `SLURMCluster`, dashboard, adaptive workers, scheduler file
- `app/dask_demo.py` — the workloads a client runs on the cluster
