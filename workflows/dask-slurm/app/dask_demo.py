#!/usr/bin/env python3
"""The demo workloads: Dask computations a client runs on the cluster the service keeps.

Connects through the scheduler file dask_cluster.py wrote, runs the chosen
workload(s) at the chosen size and prints, while they run, what the dashboard
shows: how many SLURM workers have joined and how much work remains. The adaptive
cluster submits worker jobs when the tasks arrive and retires them when the work
is over (down to the minimum, so with min_jobs=0 all of them).

Workloads:
  array      mean(x @ x) of a random n x n dask array: a dense matrix product, one
             task per block product, that keeps every core busy
  pi         Monte Carlo pi with client.map: many small independent tasks
  dataframe  groupby aggregation and a correlation over a synthetic time series
             (dask.datasets.timeseries): a dask dataframe, one partition per day
  all        the three in that order
"""
import argparse
import asyncio
import math
import sys
import time

# (matrix size n, chunk size): n x n float64, mean of x @ x costs 2 n^3 flop
ARRAY = {"small": (8_000, 1_000), "medium": (16_000, 2_000), "large": (32_000, 2_000)}
# (batches, points per batch)
PI = {"small": (200, 10_000_000), "medium": (1_000, 10_000_000), "large": (4_000, 10_000_000)}
# (start, end) of a 1-second time series, one partition per day
DATAFRAME = {"small": ("2000-01-01", "2000-02-01"), "medium": ("2000-01-01", "2000-07-01"),
             "large": ("2000-01-01", "2002-01-01")}


def count_in_circle(batch, points):
    import numpy as np
    rng = np.random.default_rng(batch)
    x = rng.random(points)
    y = rng.random(points)
    return int(np.count_nonzero(x * x + y * y <= 1.0))


def task_states(dask_scheduler):
    counts = {}
    for ts in dask_scheduler.tasks.values():
        counts[ts.state] = counts.get(ts.state, 0) + 1
    return counts


class Watch:
    """Polls the scheduler while futures run and prints the cluster's state."""

    def __init__(self, client, timeout):
        self.client = client
        self.timeout = timeout
        self.max_workers = 0
        self.max_threads = 0
        self.first_worker = None
        self.started = time.time()

    def run(self, futures, label):
        started = time.time()
        last = 0.0
        while True:
            if all(f.done() for f in futures):
                break
            now = time.time()
            if now - started > self.timeout:
                self.client.cancel(futures)
                print(f"::error title=Error::{label} did not finish within {self.timeout:.0f} s; "
                      "no worker job may have started (squeue on the login node shows the "
                      "pending jobs and the dask-worker-logs directory their output)")
                sys.exit(1)
            if now - last >= 10:
                self.report(now - started)
                last = now
            time.sleep(2)
        failed = [f for f in futures if f.status == "error"]
        if failed:
            print(f"::error title=Error::{label}: {len(failed)} task(s) failed")
            failed[0].result()
        self.report(time.time() - started)
        return time.time() - started

    def report(self, elapsed):
        info = self.client.scheduler_info()
        workers = info.get("workers", {})
        threads = sum(w.get("nthreads", 0) for w in workers.values())
        if workers and self.first_worker is None:
            self.first_worker = time.time() - self.started
            print(f"  first worker joined after {self.first_worker:.0f} s")
        self.max_workers = max(self.max_workers, len(workers))
        self.max_threads = max(self.max_threads, threads)
        try:
            states = self.client.run_on_scheduler(task_states)
        except Exception:
            states = {}
        executing = states.get("processing", 0)
        remaining = sum(states.get(s, 0) for s in ("waiting", "queued", "processing", "no-worker"))
        if not workers:
            print(f"  {elapsed:5.0f} s  no worker yet: waiting for the SLURM jobs to start "
                  "(cloud nodes can take minutes to boot)")
        else:
            print(f"  {elapsed:5.0f} s  {len(workers)} worker(s), {threads} thread(s), "
                  f"{executing} task(s) executing, {remaining} remaining")


def workload_array(client, size, watch):
    import dask.array as da
    n, chunk = ARRAY[size]
    x = da.random.random((n, n), chunks=(chunk, chunk))
    y = (x @ x).mean()
    print(f"  {n:,} x {n:,} random matrix in {chunk:,} x {chunk:,} chunks "
          f"({x.nbytes / 1e9:.1f} GB, {x.npartitions} chunks), mean of x @ x: "
          f"{2 * n ** 3 / 1e12:.1f} TFLOP; for uniform [0, 1) entries the mean is about n / 4 = {n / 4:,.1f}")
    future = client.compute(y)
    elapsed = watch.run([future], "array")
    print(f"  mean(x @ x) = {future.result():,.3f}")
    return elapsed


def workload_pi(client, size, watch):
    batches, points = PI[size]
    print(f"  {batches:,} tasks of {points:,} random points each ({batches * points:,} points)")
    futures = client.map(count_in_circle, range(batches), points=points, pure=False)
    elapsed = watch.run(futures, "pi")
    inside = sum(client.gather(futures))
    pi = 4 * inside / (batches * points)
    print(f"  pi = {pi:.6f} (error {abs(pi - math.pi):.1e})")
    return elapsed


def workload_dataframe(client, size, watch):
    import dask.datasets
    start, end = DATAFRAME[size]
    df = dask.datasets.timeseries(start=start, end=end, freq="1s", partition_freq="1d", seed=42)
    print(f"  synthetic time series {start} to {end}: {df.npartitions} daily partitions of "
          f"86,400 rows (columns id, name, x, y)")
    by_name = df.groupby("name").agg({"x": "mean", "y": "std", "id": "count"})
    corr = df.x.corr(df.y)
    f_table, f_corr = client.compute([by_name, corr])
    elapsed = watch.run([f_table, f_corr], "dataframe")
    table = f_table.result().sort_values("id", ascending=False)
    print(f"  {int(table['id'].sum()):,} rows, {len(table)} names; corr(x, y) = {f_corr.result():.5f}")
    print("  per name (top 5 by count):")
    for name, row in table.head(5).iterrows():
        print(f"    {name:<8} count {int(row['id']):>9,}  mean x {row['x']:+.5f}  std y {row['y']:.5f}")
    return elapsed


WORKLOADS = {"array": workload_array, "pi": workload_pi, "dataframe": workload_dataframe}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scheduler-file", required=True)
    parser.add_argument("--workload", default="all", choices=["all", *WORKLOADS])
    parser.add_argument("--size", default="small", choices=["small", "medium", "large"])
    parser.add_argument("--timeout", type=float, default=1800, help="seconds each workload may take")
    args = parser.parse_args()

    from dask.distributed import Client

    client = Client(scheduler_file=args.scheduler_file)
    info = client.scheduler_info()
    print(f"Connected to the Dask scheduler at {info.get('address')} with "
          f"{len(info.get('workers', {}))} worker(s) connected")
    watch = Watch(client, args.timeout)
    names = list(WORKLOADS) if args.workload == "all" else [args.workload]
    times = {}
    for name in names:
        print(f"\n=== {name} ({args.size}) ===")
        times[name] = WORKLOADS[name](client, args.size, watch)
        print(f"  {name} done in {times[name]:.0f} s")

    print("\n=== summary ===")
    for name, elapsed in times.items():
        print(f"  {name:<10} {elapsed:7.0f} s")
    print(f"  up to {watch.max_workers} worker(s) and {watch.max_threads} thread(s) took part"
          + (f"; the first worker joined {watch.first_worker:.0f} s after the first task"
             if watch.first_worker is not None else ""))
    print("  idle workers above the minimum are retired now: watch the jobs leave squeue")
    client.close()


if __name__ == "__main__":
    main()
