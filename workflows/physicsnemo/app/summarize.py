#!/usr/bin/env python3
"""Summarize a PhysicsNeMo training run (standard library only, on the login node).

Usage: summarize.py <work dir> <results dir> <outputs file>

Reads <work dir>/train.log, writes every metric metrics.py recognises to
<results dir>/metrics.csv (namespace, step, metric, value) and a summary to
<results dir>/summary.txt, lists the checkpoints and figures the run left, and
writes KEY=value lines (the last value of each metric, the counts, the paths) to
<outputs file> for the workflow's outputs.
"""

import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metrics  # noqa: E402


def key(text):
    return re.sub(r"[^A-Za-z0-9]+", "_", text).strip("_").lower()


def main():
    work_dir, results_dir, outputs_file = sys.argv[1:4]
    log = os.path.join(work_dir, "train.log")
    os.makedirs(results_dir, exist_ok=True)
    records = metrics.parse_file(log) if os.path.exists(log) else []

    last = {}
    with open(os.path.join(results_dir, "metrics.csv"), "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["namespace", "step", "metric", "value"])
        for namespace, step, values, _ in records:
            for name, value in values.items():
                writer.writerow([namespace, step, name, "%.6g" % value])
                last[(namespace, name)] = (step, value)

    checkpoints, figures = [], []
    for root, dirs, files in os.walk(work_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "tensorboard"]
        for name in files:
            path = os.path.join(root, name)
            if name.endswith((".mdlus", ".pt", ".pth", ".ckpt")):
                checkpoints.append(path)
            elif name.lower().endswith(".png"):
                figures.append(path)

    lines = []
    for (namespace, name), (step, value) in sorted(last.items()):
        lines.append("%-40s %12.4e  (step %d)" % ("%s/%s" % (namespace, name), value, step))
    steps = max((step for _, step, _, _ in records), default=0)
    with open(os.path.join(results_dir, "summary.txt"), "w") as f:
        f.write("Last value of each metric:\n")
        f.write("\n".join("  " + l for l in lines) + "\n" if lines else "  none recognised in the log\n")
        f.write("\nCheckpoints (%d):\n" % len(checkpoints))
        f.write("".join("  %s\n" % p for p in sorted(checkpoints)))
        f.write("\nFigures (%d):\n" % len(figures))
        f.write("".join("  %s\n" % p for p in sorted(figures)))

    outputs = {
        "RESULTS_DIR": results_dir,
        "WORK_DIR": work_dir,
        "TRAIN_LOG": log,
        "METRICS_CSV": os.path.join(results_dir, "metrics.csv"),
        "last_step": steps,
        "checkpoints": len(checkpoints),
        "figures": len(figures),
    }
    for (namespace, name), (_, value) in last.items():
        outputs["%s_%s" % (key(namespace), key(name))] = "%.6g" % value
    with open(outputs_file, "w") as f:
        for k, v in outputs.items():
            f.write("%s=%s\n" % (k, v))

    print(open(os.path.join(results_dir, "summary.txt")).read())
    if not records:
        print("::warning::No metric lines (Epoch N Metrics: ...) in %s, so there is nothing to plot or report" % log)


if __name__ == "__main__":
    main()
