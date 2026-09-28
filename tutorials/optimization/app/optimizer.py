#!/usr/bin/env python3
"""Dakota placeholder: a small multi-objective EA driving file-based case evaluations.

Called once per loop iteration:

    optimizer.py --state-dir S --app-dir A --batch-size B \
                 --max-iterations G --stall-generations K

Each call ingests the results of the generation it proposed last time, then either
proposes the next generation or stops:

  propose:  S/iter_<N>/case_<j>/{params.in,run.sh}  (j = 1..B)
            S/status = CONTINUE, S/proposal.env with N_CASES=<B> and ITER_DIR=<abs>
  stop:     S/pareto.csv (the non-dominated front found)
            S/status = CONVERGED (budget or stagnation) or FAILED, N_CASES=0

The per-case file interface mirrors Dakota's fork driver: `params.in` in
("<value> <name>" per line), `results.out` out (one "<value> <label>" objective per
line). A case with a missing or unparseable results.out is treated as a failed
evaluation and dropped. Swapping in Dakota keeps the contract: read all results so
far, emit the next batch of case dirs or stop.

Every call is idempotent: mutable state lives in S/state.json, written atomically
after the case dirs, so a crashed attempt re-runs safely (a generation that comes
back with zero results is re-proposed as-is; twice in a row means something is
systematically broken -> FAILED).
"""

import argparse
import glob
import json
import os
import random
import sys

N_VAR = 30            # ZDT1 dimension; variables live in [0, 1]
HV_REF = (1.1, 11.0)  # hypervolume reference; must dominate the whole attainable
                      # region (ZDT1 reaches f2 = g <= 10 at f1 = 0)
STALL_TOL = 1e-3      # front counts as stagnant when hv gains less than this


def notice(msg):
    print("::notice::optimizer: %s" % msg)


def load_state(state_dir):
    path = os.path.join(state_dir, "state.json")
    if os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    return {"gen": 0, "pool": [], "front": [], "hv_history": [],
            "zero_results": 0, "evals": 0}


def write_atomic(path, content):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.rename(tmp, path)


def save_state(state_dir, state):
    write_atomic(os.path.join(state_dir, "state.json"),
                 json.dumps(state, indent=1))


def emit(state_dir, status, n_cases, iter_dir):
    write_atomic(os.path.join(state_dir, "status"), status + "\n")
    write_atomic(os.path.join(state_dir, "proposal.env"),
                 "N_CASES=%d\nITER_DIR=%s\n" % (n_cases, iter_dir))


def read_floats(path):
    vals = []
    with open(path) as fh:
        for line in fh:
            tok = line.split()
            if tok:
                vals.append(float(tok[0]))
    return vals


def ingest(state_dir, gen):
    """Collect {x, f} for every case of generation `gen` that produced a result."""
    out = []
    for case_dir in sorted(glob.glob(os.path.join(state_dir, "iter_%d" % gen, "case_*"))):
        try:
            f = read_floats(os.path.join(case_dir, "results.out"))
            x = read_floats(os.path.join(case_dir, "params.in"))
        except (OSError, ValueError):
            continue
        if len(f) >= 2 and len(x) == N_VAR:
            out.append({"x": x, "f": f[:2]})
    return out


def dominates(a, b):
    return a[0] <= b[0] and a[1] <= b[1] and (a[0] < b[0] or a[1] < b[1])


def select_front(individuals):
    fs = [ind["f"] for ind in individuals]
    return [ind for i, ind in enumerate(individuals)
            if not any(dominates(fs[j], fs[i]) for j in range(len(fs)) if j != i)]


def nd_ranks(fs):
    ranks = [0] * len(fs)
    remaining = set(range(len(fs)))
    rank = 0
    while remaining:
        front = [i for i in remaining
                 if not any(dominates(fs[j], fs[i]) for j in remaining if j != i)]
        for i in front:
            ranks[i] = rank
        remaining -= set(front)
        rank += 1
    return ranks


def crowding(fs, ranks):
    dist = [0.0] * len(fs)
    for rank in set(ranks):
        idx = [i for i in range(len(fs)) if ranks[i] == rank]
        for m in (0, 1):
            idx.sort(key=lambda i: fs[i][m])
            dist[idx[0]] = dist[idx[-1]] = float("inf")
            lo, hi = fs[idx[0]][m], fs[idx[-1]][m]
            if hi > lo:
                for k in range(1, len(idx) - 1):
                    dist[idx[k]] += (fs[idx[k + 1]][m] - fs[idx[k - 1]][m]) / (hi - lo)
    return dist


def select_best(individuals, size):
    fs = [ind["f"] for ind in individuals]
    ranks = nd_ranks(fs)
    dist = crowding(fs, ranks)
    order = sorted(range(len(individuals)), key=lambda i: (ranks[i], -dist[i]))
    return [individuals[i] for i in order[:size]]


def offspring(pool, batch, rng):
    fs = [ind["f"] for ind in pool]
    ranks = nd_ranks(fs)
    dist = crowding(fs, ranks)

    def tournament():
        i, j = rng.randrange(len(pool)), rng.randrange(len(pool))
        return i if (ranks[i], -dist[i]) <= (ranks[j], -dist[j]) else j

    kids = []
    for _ in range(batch):
        a, b = pool[tournament()]["x"], pool[tournament()]["x"]
        child = []
        for k in range(N_VAR):
            v = a[k] + rng.uniform(-0.25, 1.25) * (b[k] - a[k])
            if rng.random() < 3.0 / N_VAR:
                v += rng.gauss(0.0, 0.08)
            child.append(min(1.0, max(0.0, v)))
        kids.append(child)
    return kids


def hypervolume(fs):
    pts = sorted(tuple(f) for f in fs if f[0] < HV_REF[0] and f[1] < HV_REF[1])
    hv, prev = 0.0, HV_REF[1]
    for f1, f2 in pts:
        if f2 < prev:
            hv += (HV_REF[0] - f1) * (prev - f2)
            prev = f2
    return hv


def write_cases(state_dir, app_dir, gen, population):
    iter_dir = os.path.join(state_dir, "iter_%d" % gen)
    for j, x in enumerate(population, start=1):
        case_dir = os.path.join(iter_dir, "case_%d" % j)
        os.makedirs(case_dir, exist_ok=True)
        write_atomic(os.path.join(case_dir, "params.in"),
                     "".join("%.10f x%d\n" % (v, k + 1) for k, v in enumerate(x)))
        # script_submitter inlines the script body, so bake the absolute case path
        # in rather than relying on $0
        write_atomic(os.path.join(case_dir, "run.sh"),
                     '#!/bin/bash\ncd "%s"\npython3 "%s"\n'
                     % (case_dir, os.path.join(app_dir, "simulator.py")))
    return iter_dir


def stop(state_dir, state, status, reason):
    front = sorted(state["front"], key=lambda ind: ind["f"][0])
    header = "f1,f2,g," + ",".join("x%d" % (k + 1) for k in range(N_VAR))
    rows = [header]
    for ind in front:
        g = 1.0 + 9.0 * sum(ind["x"][1:]) / (N_VAR - 1)
        rows.append(",".join(["%.10f" % ind["f"][0], "%.10f" % ind["f"][1],
                              "%.6f" % g] + ["%.6f" % v for v in ind["x"]]))
    write_atomic(os.path.join(state_dir, "pareto.csv"), "\n".join(rows) + "\n")
    save_state(state_dir, state)
    emit(state_dir, status, 0, os.path.join(state_dir, "iter_%d" % state["gen"]))
    notice("%s after %d generations, %d evaluations: %s (front of %d written to pareto.csv)"
           % (status, state["gen"], state["evals"], reason, len(front)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--app-dir", required=True)
    ap.add_argument("--batch-size", type=int, required=True)
    ap.add_argument("--max-iterations", type=int, required=True)
    ap.add_argument("--stall-generations", type=int, default=3)
    args = ap.parse_args()

    state_dir = os.path.abspath(args.state_dir)
    app_dir = os.path.abspath(args.app_dir)
    state = load_state(state_dir)
    rng = random.Random(4242 + state["gen"])

    if state["gen"] >= 1:
        results = ingest(state_dir, state["gen"])
        if not results:
            state["zero_results"] += 1
            if state["zero_results"] >= 2:
                state["front"] = state["front"] or []
                stop(state_dir, state, "FAILED",
                     "generation %d returned no results twice in a row" % state["gen"])
                print("::error::optimizer: no case of generation %d produced a "
                      "results.out on two attempts; check the workers' logs"
                      % state["gen"])
                return
            # the case dirs are intact; hand the same generation back to the workers
            save_state(state_dir, state)
            iter_dir = os.path.join(state_dir, "iter_%d" % state["gen"])
            n = len(glob.glob(os.path.join(iter_dir, "case_*")))
            emit(state_dir, "CONTINUE", n, iter_dir)
            notice("generation %d returned no results; re-proposing its %d cases"
                   % (state["gen"], n))
            return
        state["zero_results"] = 0
        state["evals"] += len(results)
        state["front"] = select_front(state["front"] + results)
        state["pool"] = select_best(state["pool"] + results, 2 * args.batch_size)
        hv = hypervolume([ind["f"] for ind in state["front"]])
        gain = hv - state["hv_history"][-1] if state["hv_history"] else hv
        state["hv_history"].append(hv)
        notice("gen %d: %d/%d results, %d evaluations total, front %d, "
               "hypervolume %.4f (%+.4f)"
               % (state["gen"], len(results), args.batch_size, state["evals"],
                  len(state["front"]), hv, gain))

    hist = state["hv_history"]
    if state["gen"] >= args.max_iterations:
        stop(state_dir, state, "CONVERGED", "generation budget reached")
        return
    if len(hist) > args.stall_generations and \
            hist[-1] - hist[-1 - args.stall_generations] < STALL_TOL:
        stop(state_dir, state, "CONVERGED",
             "front stagnated for %d generations" % args.stall_generations)
        return

    next_gen = state["gen"] + 1
    if state["pool"]:
        population = offspring(state["pool"], args.batch_size, rng)
    else:
        population = [[rng.random() for _ in range(N_VAR)]
                      for _ in range(args.batch_size)]
    iter_dir = write_cases(state_dir, app_dir, next_gen, population)
    state["gen"] = next_gen
    save_state(state_dir, state)
    emit(state_dir, "CONTINUE", len(population), iter_dir)
    notice("gen %d: proposed %d cases under %s"
           % (next_gen, len(population), iter_dir))


if __name__ == "__main__":
    sys.exit(main())
