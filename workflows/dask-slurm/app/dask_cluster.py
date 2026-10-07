#!/usr/bin/env python3
"""The Dask cluster service: a dask-jobqueue SLURMCluster kept alive on the login node.

start-template.sh runs this under `pw endpoints run`, which assigns the dashboard
port ({port}, also $PORT) and serves the Dask dashboard as the run's endpoint. The
scheduler lives in this process; the workers are SLURM jobs that dask-jobqueue
submits with sbatch and scales between the minimum and maximum job counts as work
arrives and drains (cluster.adapt). Clients connect through the scheduler file
written in the job directory.

The configuration is read from the environment (the run's inputs.sh, dask_*
variables; start-template.sh lists them). The process exits when a STOP file
appears in the job directory or on SIGTERM/SIGINT/SIGHUP: it closes the cluster,
which cancels the workers' SLURM jobs, and leaves a CLUSTER_CLOSED marker.
"""
import argparse
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

log = logging.getLogger("dask-slurm")

MARKERS = ("STOP", "CLUSTER_CLOSED", "ENDPOINT_URL", "scheduler.json", "dask-worker.sbatch")


def env(name, default=""):
    value = os.environ.get(name, "").strip()
    # a hidden or empty form input can reach inputs.sh as the string "undefined"
    return value if value and value != "undefined" else default


def env_int(name, default):
    value = env(name)
    if not value:
        return default
    try:
        return int(float(value))
    except ValueError:
        fail(f"{name} must be a number, got {value!r}")


def fail(message):
    log.error("::error title=Error::%s", message)
    sys.exit(1)


def read_directives(path):
    """The extra #SBATCH lines typed in the form, as dask-jobqueue's job_extra_directives."""
    directives = []
    if not path.is_file():
        return directives
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith("#SBATCH"):
            directive = line[len("#SBATCH"):].strip()
            if directive:
                directives.append(directive)
    return directives


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dashboard-port", type=int, default=int(os.environ.get("PORT") or 0),
                        help="port the dashboard listens on (default: $PORT, set by pw endpoints run)")
    parser.add_argument("--job-dir", default=env("PW_PARENT_JOB_DIR") or os.getcwd(),
                        help="the run's job directory: the scheduler file, markers and worker logs go there")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S", stream=sys.stdout)

    if args.dashboard_port <= 0:
        fail("No dashboard port: run this script under pw endpoints run (or pass --dashboard-port)")
    job_dir = Path(args.job_dir).resolve()
    for marker in MARKERS:
        (job_dir / marker).unlink(missing_ok=True)

    cores = env_int("dask_cores", 2)
    memory = env("dask_memory", "4GB")
    processes = env_int("dask_processes", 0) or None
    walltime = env("dask_walltime", "01:00:00")
    min_jobs = env_int("dask_min_jobs", 0)
    max_jobs = env_int("dask_max_jobs", 4)
    if max_jobs < 1:
        fail(f"The maximum number of worker jobs must be at least 1, got {max_jobs}")
    if min_jobs < 0 or min_jobs > max_jobs:
        fail(f"The minimum number of worker jobs must be between 0 and the maximum ({max_jobs}), got {min_jobs}")
    job_name = env("dask_job_name") or f"dask-{env('PW_RUN_SLUG', 'workers')}"

    directives = read_directives(job_dir / "dask-directives.txt")
    for variable, flag in (("dask_qos", "--qos"), ("dask_node_type", "--constraint")):
        if env(variable):
            directives.append(f"{flag}={env(variable)}")
    # memory sets the workers' memory limit; the --mem directive it also writes is
    # only requested from SLURM when asked (clusters without memory accounting
    # reject it: "Requested node configuration is not available")
    skip = [] if env("dask_mem_directive") == "true" else ["--mem"]

    log_dir = job_dir / "dask-worker-logs"
    log_dir.mkdir(exist_ok=True)
    scheduler_file = job_dir / "scheduler.json"

    from dask_jobqueue import SLURMCluster

    # distributed sets its loggers' levels when imported (every client connection
    # and out-of-band call at INFO), so the quieting comes after the import
    logging.getLogger("distributed").setLevel(logging.WARNING)
    logging.getLogger("bokeh").setLevel(logging.WARNING)

    options = dict(
        cores=cores,
        memory=memory,
        walltime=walltime,
        job_name=job_name,
        job_extra_directives=directives,
        job_directives_skip=skip,
        # one BLAS thread per Dask thread: the workers would otherwise oversubscribe
        # the cores with numpy's own thread pools
        job_script_prologue=["export OMP_NUM_THREADS=1", "export OPENBLAS_NUM_THREADS=1", "export MKL_NUM_THREADS=1"],
        log_directory=str(log_dir),
        scheduler_options={"dashboard_address": f"127.0.0.1:{args.dashboard_port}",
                           "scheduler_file": str(scheduler_file)},
    )
    # an option left empty in the form keeps dask-jobqueue's default; passing None
    # is not the same (processes=None fails its "processes > 1" check)
    for option, value in (("queue", env("dask_partition")), ("account", env("dask_account")),
                          ("interface", env("dask_interface")), ("processes", processes)):
        if value:
            options[option] = value
    cluster = SLURMCluster(**options)
    try:
        script = cluster.job_script()
        (job_dir / "dask-worker.sbatch").write_text(script)
        log.info("Worker job script (dask-worker.sbatch):\n%s", script.rstrip())
        # sbatch validates the directives without submitting: a wrong partition,
        # account or QoS fails the run now, in seconds, instead of leaving the
        # workload waiting for workers that never come
        test = subprocess.run(["sbatch", "--test-only", str(job_dir / "dask-worker.sbatch")],
                              capture_output=True, text=True)
        if test.returncode != 0:
            fail("sbatch rejects the worker job script: " + (test.stderr or test.stdout).strip().replace("\n", " "))

        cluster.adapt(minimum_jobs=min_jobs, maximum_jobs=max_jobs)
        (job_dir / "ENDPOINT_URL").write_text(env("PW_ENDPOINT_URL") + "\n")
        log.info("Scheduler at %s; scheduler file %s", cluster.scheduler_address, scheduler_file)
        log.info("Dashboard at %s (local %s)", env("PW_ENDPOINT_URL") or "(no endpoint URL)", cluster.dashboard_link)
        log.info("Workers: %d to %d SLURM job(s) named %s, %d core(s) and %s each, walltime %s%s",
                 min_jobs, max_jobs, job_name, cores, memory, walltime,
                 f", partition {env('dask_partition')}" if env("dask_partition") else "")
        log.info("The cluster scales with the work: submit tasks to see the jobs appear in squeue")

        stop_signals = []
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda signum, frame: stop_signals.append(signum))
        stop_file = job_dir / "STOP"
        last_state, last_log = None, 0.0
        while not stop_signals and not stop_file.exists():
            workers = cluster.scheduler_info.get("workers", {})
            state = (len(workers), sum(w.get("nthreads", 0) for w in workers.values()), len(cluster.worker_spec))
            if state != last_state or time.time() - last_log > 600:
                log.info("%d worker(s) connected, %d thread(s); %d SLURM job(s) requested", *state)
                last_state, last_log = state, time.time()
            time.sleep(3)
        reason = "STOP file" if stop_file.exists() else f"signal {stop_signals[0]}"
        log.info("Closing the cluster (%s): cancelling the worker jobs", reason)
    finally:
        cluster.close()
        scheduler_file.unlink(missing_ok=True)
        (job_dir / "CLUSTER_CLOSED").touch()
    log.info("Cluster closed")


if __name__ == "__main__":
    main()
