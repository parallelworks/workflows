#!/usr/bin/env python3
"""Monitor the CPU and memory usage of a node, or plot a recorded monitoring file.

--write-usage --txt FILE   sample psutil every second into FILE (timestamp,cpu%,mem%)
                           and scancel the SLURM job when memory use exceeds 98%
--plot-usage  --txt FILE   plot FILE to the PNG of the same name
"""
import argparse
import os
import subprocess
import time
from datetime import datetime

import psutil

MEMORY_LIMIT_PERCENT = 98


def kill_job():
    job_id = os.environ.get("SLURM_JOB_ID")
    if not job_id:
        print("SLURM_JOB_ID is not set; cannot cancel the job.", flush=True)
        return
    try:
        subprocess.run(["scancel", job_id], check=True)
        print(f"Job {job_id} cancelled.", flush=True)
    except subprocess.CalledProcessError as e:
        print(f"Failed to cancel job {job_id}: {e}", flush=True)


def write_usage_data(txt_file):
    with open(txt_file, "w") as data_file:
        print("Monitoring CPU and memory usage...", flush=True)
        while True:
            cpu_usage = psutil.cpu_percent()
            memory_usage = psutil.virtual_memory().percent
            if memory_usage > MEMORY_LIMIT_PERCENT:
                print(f"Memory exceeded {MEMORY_LIMIT_PERCENT}%. Killing job.", flush=True)
                kill_job()
            data_file.write(f"{datetime.now()},{cpu_usage},{memory_usage}\n")
            data_file.flush()
            time.sleep(1)


def plot_usage_data(txt_file):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    timestamps, cpu_usages, memory_usages = [], [], []
    with open(txt_file, "r") as data_file:
        for line in data_file:
            timestamp, cpu_usage, memory_usage = line.strip().split(",")
            timestamps.append(datetime.fromisoformat(timestamp))
            cpu_usages.append(float(cpu_usage))
            memory_usages.append(float(memory_usage))
    plt.figure(figsize=(10, 6))
    plt.plot(timestamps, cpu_usages, label="CPU Usage (%)")
    plt.plot(timestamps, memory_usages, label="Memory Usage (%)")
    plt.xlabel("Time")
    plt.ylabel("Usage (%)")
    plt.title("CPU and Memory Usage Over Time")
    plt.legend()
    plt.grid(True)
    plt.xticks(rotation=45)
    plt.tight_layout()
    img_path = os.path.splitext(txt_file)[0] + ".png"
    plt.savefig(img_path)
    print(f"Plot image saved as {img_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write-usage", action="store_true", help="record CPU and memory usage to --txt")
    parser.add_argument("--plot-usage", action="store_true", help="plot the CPU and memory usage recorded in --txt")
    parser.add_argument("--txt", required=True, help="the usage data file")
    args = parser.parse_args()
    if args.write_usage:
        write_usage_data(args.txt)
    elif args.plot_usage:
        plot_usage_data(args.txt)
    else:
        parser.error("specify --write-usage or --plot-usage")
