# Dask on SLURM with dask-jobqueue (`workflows/dask-slurm`)

> What a `SLURMCluster` kept alive behind a `pw` endpoint needed, verified on
> gcpsmall 2026-10-07 with dask and distributed 2026.8.0, dask-jobqueue 0.9.0,
> bokeh 3.10.0 and Python 3.14.7 from conda-forge (the environment pinned in
> `workflows/dask-slurm/app/dask2026.8.0-python3.14.7.yaml`).

- **Omit an option to get its default; `None` is not the same.**
  `SLURMCluster(processes=None)` fails in `JobQueueCluster.__init__` with
  `TypeError: '>' not supported between instances of 'NoneType' and 'int'` (its
  `processes > 1` check runs before the Job's own `None` handling). The service builds
  the kwargs and adds `queue`, `account`, `interface` and `processes` only when the form
  gave a value (`app/dask_cluster.py`).
- **The scheduler lives in the service process; clients come through a scheduler
  file.** `scheduler_options={"scheduler_file": <job dir>/scheduler.json,
  "dashboard_address": "127.0.0.1:<port>"}` writes the file when the scheduler starts and
  binds the dashboard on the port `pw endpoints run` assigns (`{port}` on the command
  line, `$PORT` in the environment). The dashboard's `/` answers `301` to `/status`,
  which answers `200`, so `--slug status` lands the endpoint on the status page and the
  default `2*|3*` health pattern passes either way. `cluster.adapt(minimum_jobs=,
  maximum_jobs=)` counts SLURM jobs, not workers: 2 cores default to 2 processes of 1
  thread, each with half the job's memory.
- **Validate the worker job script before any task:** `cluster.job_script()` written to
  a file and `sbatch --test-only <file>` rejects a wrong partition, account or QoS in
  seconds (`invalid partition specified`, rc 1) without submitting, where the adaptive
  scaler would otherwise log sbatch failures while the workload waits for workers that
  never come.
- **gcpsmall's nodes have no memory accounting** (`sinfo` shows 1 MB): any `--mem` makes
  sbatch answer `Requested node configuration is not available`, so the workflow skips the
  directive dask-jobqueue derives from `memory` (`job_directives_skip=["--mem"]`) unless
  the form asks for it; `memory` still sets the workers' memory limit.
- **Pin the BLAS threads in the job:** `job_script_prologue=["export OMP_NUM_THREADS=1",
  "export OPENBLAS_NUM_THREADS=1", "export MKL_NUM_THREADS=1"]`, or numpy's own pools
  oversubscribe the job's cores under several Dask threads.
- **distributed sets its loggers when imported**: a `logging.getLogger("distributed")
  .setLevel(WARNING)` placed before the import is overridden (every client connection and
  `run_on_scheduler` call then logs at INFO); set the level after `from dask_jobqueue
  import SLURMCluster`.
- **Worker metrics carry no `executing` count in this version**; count tasks from the
  scheduler with `client.run_on_scheduler(lambda dask_scheduler: ...)` over
  `dask_scheduler.tasks` states (`processing`, `waiting`, `queued`, `no-worker`), as
  `app/dask_demo.py` does.
- **Timeline on gcpsmall (idle~ nodes):** the first task made the adaptive scaler submit
  the jobs within 3 s; the nodes booted and the workers joined after 150 s; once the work
  was done the workers above the minimum were retired and their jobs cancelled within 10 s
  (`slurmstepd: JOB CANCELLED` in `dask-worker-logs/`). `cluster.close()` on a STOP
  file took under a second and `scancel`ed nothing (no job left); a killed service leaves
  its jobs to `--death-timeout 60` and to `cancel.sh`'s `scancel --name dask-<slug>`.
