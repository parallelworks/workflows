#!/usr/bin/env python3
"""Dakota optimizer step: propose-or-stop, driven by Dakota's restart file.

    optimizer.py --state-dir S --app-dir A \
                 --variables-file V --objectives "f1 f2" \
                 --batch-size B --max-generations G --stall-generations K \
                 [--seed N] [--dakota-env FILE]

The problem: V holds one "<name> <lower> <upper>" line per continuous design
variable; --objectives names the two responses, both minimized (negate one to
maximize it). The spec is frozen in S/problem.json on the first call and every
later call must repeat it: Dakota's restart replay is only valid for the study it
was written by. --dakota-env is a file sourced to put `dakota` on PATH; without
it the conda-forge install under --software-dir is used.

Each call ingests the results of the generation it proposed last time, then either
proposes the next generation or stops:

  propose:  S/iter_<N>/case_<j>/{params.in,param.hash}  (j = 1..n, n <= B)
            S/iter_<N>/proposals.csv (the same designs as a table)
            S/status = CONTINUE, S/proposal.env with STATUS, GENERATION, N_CASES, ITER_DIR
  stop:     S/status = CONVERGED (budget, stagnation or Dakota's own criteria)
            or FAILED, N_CASES = 0
  always:   S/evaluations.csv (every evaluated design: generation, case, status,
            variables, objectives), S/pareto.csv + S/pareto.svg (the current
            non-dominated front), S/state.json

The evaluator's contract is per case directory: read params.in, leave results.out
(one "<value> <label>" line per objective, atomically) — or leave an exit_code
file with no results.out to say the evaluation ran and failed. A case directory
with neither means the evaluation never ran.

Dakota (MOGA) is the search strategy, but Dakota drives evaluations itself and has
no "emit a batch and exit" mode, so each call resumes the study through Dakota's
crash-recovery semantics: run `dakota -read_restart S/dakota/dakota.rst` with a
fixed seed, let it replay every completed evaluation, satisfy the ones the platform
evaluated meanwhile from S/results_db/ (driver.py's replay path), and capture the
first batch of NEW points it requests — the fork drivers write those case dirs and
block, and once the pending set is stable this wrapper kills Dakota's process
group. The next call replays to the same spot, deterministically, and continues.
Dakota exiting on its own instead means its convergence criteria are satisfied.

Every call is idempotent: mutable state lives in S/state.json, written atomically
after the case dirs, so a crashed attempt re-runs safely. Failure semantics: a case
that ran (exit_code) without a results.out failed in the evaluator and is fed back
to Dakota as FAIL — a whole generation of them too (a marginal design diverging is
a result, not an outage). Only a generation none of whose cases ran is re-proposed
as-is, and twice in a row -> FAILED; so does a generation that ran and failed
entirely before any design ever succeeded (the setup, not a design, is broken) or
three of them in a row.
"""

import argparse
import glob
import json
import os
import signal
import subprocess
import sys
import time

CAPTURE_STABLE_S = 15       # no new capture for this long = the wave is complete
CAPTURE_TIMEOUT_S = 300
STALL_TOL = 1e-3            # on the normalized hypervolume


def notice(msg):
    print("::notice::optimizer: %s" % msg)


def write_atomic(path, content):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.rename(tmp, path)


def parse_variables(path):
    variables = []
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.split("#")[0].strip()
            if not line:
                continue
            tok = line.replace(",", " ").split()
            if len(tok) != 3:
                sys.exit("::error::optimizer: %s line %d: expected '<name> <lower> <upper>', got %r"
                         % (path, lineno, line))
            name, lo, hi = tok[0], float(tok[1]), float(tok[2])
            if not name.replace("_", "").isalnum():
                sys.exit("::error::optimizer: variable name %r must be alphanumeric/underscore" % name)
            if not lo < hi:
                sys.exit("::error::optimizer: variable %s needs lower < upper, got %g %g" % (name, lo, hi))
            variables.append([name, lo, hi])
    if not variables:
        sys.exit("::error::optimizer: %s defines no variables" % path)
    if len(set(v[0] for v in variables)) != len(variables):
        sys.exit("::error::optimizer: duplicate variable names in %s" % path)
    return variables


def parse_objectives(text):
    names = text.replace(",", " ").split()
    if len(names) != 2:
        sys.exit("::error::optimizer: exactly two objectives are supported (the front "
                 "and its hypervolume are two-dimensional), got %d: %r" % (len(names), names))
    return names


def load_problem(state_dir, variables, objectives):
    """Freeze the problem on the first call; a later call must match it."""
    path = os.path.join(state_dir, "problem.json")
    problem = {"variables": variables, "objectives": objectives}
    if os.path.exists(path):
        with open(path) as fh:
            frozen = json.load(fh)
        if frozen != problem:
            sys.exit("::error::optimizer: the problem differs from the one this study was "
                     "started with (%s); Dakota's restart file cannot be replayed for a "
                     "different problem — point state_dir at a fresh directory" % path)
    else:
        write_atomic(path, json.dumps(problem, indent=1))
    return problem


def load_state(state_dir):
    path = os.path.join(state_dir, "state.json")
    if os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    return {"gen": 0, "front": [], "hv_history": [], "zero_results": 0,
            "failed_generations": 0, "evals": 0, "history": [], "norm": None}


def save_state(state_dir, state):
    write_atomic(os.path.join(state_dir, "state.json"), json.dumps(state, indent=1))


def emit(state_dir, status, gen, n_cases, iter_dir):
    write_atomic(os.path.join(state_dir, "status"), status + "\n")
    write_atomic(os.path.join(state_dir, "proposal.env"),
                 "STATUS=%s\nGENERATION=%d\nN_CASES=%d\nITER_DIR=%s\n"
                 % (status, gen, n_cases, iter_dir))


def read_pairs(path):
    pairs = []
    with open(path) as fh:
        for line in fh:
            tok = line.split()
            if tok:
                pairs.append((tok[1] if len(tok) > 1 else "", float(tok[0])))
    return pairs


def ingest(state_dir, gen, problem):
    """Sort the cases of generation `gen` into results ({x, f, key, case}), failed
    ((case_dir, key, x): the evaluator ran and left an exit_code but no usable
    results.out) and unrun ((case_dir, key, x): neither file, the evaluation never
    ran or was killed mid-way)."""
    done, failed, unrun = [], [], []
    n_var, n_obj = len(problem["variables"]), len(problem["objectives"])
    for case_dir in sorted(glob.glob(os.path.join(state_dir, "iter_%d" % gen, "case_*")),
                           key=lambda d: int(d.rsplit("_", 1)[1])):
        try:
            with open(os.path.join(case_dir, "param.hash")) as fh:
                key = fh.read().strip()
            x = [v for _, v in read_pairs(os.path.join(case_dir, "params.in"))]
        except (OSError, ValueError):
            continue
        if len(x) != n_var:
            continue
        try:
            f = [v for _, v in read_pairs(os.path.join(case_dir, "results.out"))]
        except (OSError, ValueError):
            f = None
        case = os.path.basename(case_dir)
        if f is not None and len(f) >= n_obj:
            done.append({"x": x, "f": f[:n_obj], "key": key, "case": case})
        elif os.path.exists(os.path.join(case_dir, "exit_code")):
            failed.append((case, key, x))
        else:
            unrun.append((case, key, x))
    return done, failed, unrun


def dominates(a, b):
    return a[0] <= b[0] and a[1] <= b[1] and (a[0] < b[0] or a[1] < b[1])


def select_front(individuals):
    fs = [ind["f"] for ind in individuals]
    return [ind for i, ind in enumerate(individuals)
            if not any(dominates(fs[j], fs[i]) for j in range(len(fs)) if j != i)]


def hypervolume(state):
    """2D hypervolume of the front, on objectives normalized by the bounds frozen
    at the first ingest (the objective scales are arbitrary), ref (1.1, 1.1)."""
    lo = state["norm"]["lo"]
    span = state["norm"]["span"]
    fs = [[(ind["f"][m] - lo[m]) / span[m] for m in (0, 1)] for ind in state["front"]]
    ref = (1.1, 1.1)
    pts = sorted(tuple(f) for f in fs if f[0] < ref[0] and f[1] < ref[1])
    hv, prev = 0.0, ref[1]
    for f1, f2 in pts:
        if f2 < prev:
            hv += (ref[0] - f1) * (prev - f2)
            prev = f2
    return hv


def append_evaluations(state_dir, problem, gen, results, failed, unrun):
    """One row per evaluated design in S/evaluations.csv, the record the live
    Pareto page and any post-processing read; the header is written once."""
    path = os.path.join(state_dir, "evaluations.csv")
    names = [v[0] for v in problem["variables"]] + problem["objectives"]
    rows = []
    if not os.path.exists(path):
        rows.append("generation,case,status," + ",".join(names))
    for r in results:
        rows.append("%d,%s,OK,%s,%s" % (gen, r["case"], ",".join("%.8e" % v for v in r["x"]),
                                        ",".join("%.10e" % v for v in r["f"])))
    for case, _, x in failed:
        rows.append("%d,%s,FAIL,%s,," % (gen, case, ",".join("%.8e" % v for v in x)))
    for case, _, x in unrun:
        rows.append("%d,%s,UNRUN,%s,," % (gen, case, ",".join("%.8e" % v for v in x)))
    with open(path, "a") as fh:
        fh.write("\n".join(rows) + "\n")


def write_front(state_dir, state, problem):
    front = sorted(state["front"], key=lambda ind: ind["f"][0])
    header = ",".join(problem["objectives"]) + "," + ",".join(v[0] for v in problem["variables"])
    rows = [header]
    for ind in front:
        rows.append(",".join(["%.10f" % v for v in ind["f"]] + ["%.8e" % v for v in ind["x"]]))
    write_atomic(os.path.join(state_dir, "pareto.csv"), "\n".join(rows) + "\n")
    write_plot(state_dir, state, problem)


def write_plot(state_dir, state, problem):
    """Render state/pareto.svg: every evaluation and the current front. Pure
    stdlib so it renders anywhere the loop runs."""
    pts = [p[:2] for p in state["history"]]
    if not pts:
        return
    front = sorted(ind["f"] for ind in state["front"])
    objectives = problem["objectives"]
    width, height = 640, 480
    ml, mr, mt, mb = 64, 16, 16, 46
    iw, ih = width - ml - mr, height - mt - mb
    lo = [min(p[m] for p in pts) for m in (0, 1)]
    hi = [max(p[m] for p in pts) for m in (0, 1)]
    for m in (0, 1):
        pad = 0.05 * (hi[m] - lo[m]) or 0.5
        lo[m] -= pad
        hi[m] += pad

    def sx(v):
        return ml + (v - lo[0]) / (hi[0] - lo[0]) * iw

    def sy(v):
        return mt + ih - (v - lo[1]) / (hi[1] - lo[1]) * ih

    s = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
         'font-family="sans-serif">' % (width, height),
         '<rect width="100%" height="100%" fill="#fcfcfb"/>']
    for i in range(6):
        vx = lo[0] + (hi[0] - lo[0]) * i / 5
        vy = lo[1] + (hi[1] - lo[1]) * i / 5
        s.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="#f0efec"/>'
                 % (sx(vx), mt, sx(vx), mt + ih))
        s.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#f0efec"/>'
                 % (ml, sy(vy), ml + iw, sy(vy)))
        s.append('<text x="%.1f" y="%d" font-size="11" text-anchor="middle" '
                 'fill="#52514e">%.3g</text>' % (sx(vx), mt + ih + 16, vx))
        s.append('<text x="%d" y="%.1f" font-size="11" text-anchor="end" '
                 'fill="#52514e">%.3g</text>' % (ml - 6, sy(vy) + 4, vy))
    s.append('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#52514e"/>'
             % (ml, mt, iw, ih))
    s.append('<text x="%.1f" y="%d" font-size="13" fill="#0b0b0b" '
             'text-anchor="middle">%s</text>' % (ml + iw / 2, height - 8, objectives[0]))
    s.append('<text x="16" y="%.1f" font-size="13" fill="#0b0b0b" text-anchor="middle" '
             'transform="rotate(-90 16 %.1f)">%s</text>'
             % (mt + ih / 2, mt + ih / 2, objectives[1]))
    for f1, f2 in pts:
        s.append('<circle cx="%.1f" cy="%.1f" r="2.2" fill="#2a78d6"/>' % (sx(f1), sy(f2)))
    s.append('<polyline points="%s" fill="none" stroke="#eb6834" stroke-width="1.5"/>'
             % " ".join("%.1f,%.1f" % (sx(f[0]), sy(f[1])) for f in front))
    for f in front:
        s.append('<circle cx="%.1f" cy="%.1f" r="3.5" fill="#eb6834"/>' % (sx(f[0]), sy(f[1])))
    lx, ly = ml + iw - 220, mt + 14
    s.append('<circle cx="%d" cy="%d" r="3" fill="#2a78d6"/>' % (lx, ly))
    s.append('<text x="%d" y="%d" font-size="12" fill="#0b0b0b">all evaluations '
             '(%d)</text>' % (lx + 10, ly + 4, len(pts)))
    s.append('<circle cx="%d" cy="%d" r="3.5" fill="#eb6834"/>' % (lx, ly + 20))
    s.append('<text x="%d" y="%d" font-size="12" fill="#0b0b0b">Pareto front '
             '(%d points)</text>' % (lx + 10, ly + 24, len(front)))
    s.append('</svg>')
    write_atomic(os.path.join(state_dir, "pareto.svg"), "\n".join(s) + "\n")


def stop(state_dir, state, problem, status, reason):
    write_front(state_dir, state, problem)
    save_state(state_dir, state)
    emit(state_dir, status, state["gen"], 0, os.path.join(state_dir, "iter_%d" % state["gen"]))
    notice("%s after %d generations, %d evaluations: %s (front of %d written to "
           "pareto.csv, plotted in pareto.svg)"
           % (status, state["gen"], state["evals"], reason, len(state["front"])))


def write_dakota_input(dak_dir, app_dir, problem, batch, seed):
    variables, objectives = problem["variables"], problem["objectives"]
    names = " ".join("'%s'" % v[0] for v in variables)
    lower = " ".join("%.12g" % v[1] for v in variables)
    upper = " ".join("%.12g" % v[2] for v in variables)
    obj = " ".join("'%s'" % name for name in objectives)
    recovery = " ".join("1.0e3" for _ in objectives)
    content = """\
# Generated by optimizer.py on every call; identical content each time so the
# restart replay is deterministic.
environment
  tabular_data
    tabular_data_file = 'dakota_tabular.dat'

method
  moga
    seed = %d
    population_size = %d
    max_function_evaluations = 100000
    # a small population breeds many duplicate offspring, which Dakota's
    # evaluation cache absorbs without proposing anything; mutate more so each
    # generation carries new points
    mutation_type replace_uniform
      mutation_rate = 0.2
    convergence_type metric_tracker
      percent_change = 0.01
      num_generations = 5

variables
  continuous_design = %d
    descriptors   %s
    lower_bounds  %s
    upper_bounds  %s

interface
  fork
    analysis_drivers = 'python3 %s'
    parameters_file = 'params.in'
    results_file = 'results.out'
    file_tag
  failure_capture recover %s
  asynchronous evaluation_concurrency = %d

responses
  objective_functions = %d
    descriptors %s
  no_gradients
  no_hessians
""" % (seed, batch, len(variables), names, lower, upper,
       os.path.join(app_dir, "driver.py"), recovery, batch, len(objectives), obj)
    write_atomic(os.path.join(dak_dir, "dakota.in"), content)


def count_captures(iter_dir):
    return len([d for d in glob.glob(os.path.join(iter_dir, "case_*"))
                if os.path.exists(os.path.join(d, "param.hash"))])


def run_dakota_capture(state_dir, app_dir, problem, batch, seed, iter_dir, software_dir,
                       dakota_env):
    """Resume Dakota and capture the next batch of case dirs it proposes.
    Returns (n_captured, dakota_exited_cleanly)."""
    dak_dir = os.path.join(state_dir, "dakota")
    os.makedirs(dak_dir, exist_ok=True)
    write_dakota_input(dak_dir, app_dir, problem, batch, seed)
    rst = os.path.join(dak_dir, "dakota.rst")
    rst_new = os.path.join(dak_dir, "dakota_new.rst")

    dakota_args = ["-input", "dakota.in", "-write_restart", "dakota_new.rst"]
    if os.path.exists(rst) and os.path.getsize(rst) > 0:
        dakota_args += ["-read_restart", "dakota.rst"]
    env = dict(os.environ,
               DAK_CAPTURE_DIR=iter_dir,
               DAK_RESULTS_DB=os.path.join(state_dir, "results_db"))
    if dakota_env:
        # exec keeps Dakota as the session leader the capture loop kills
        cmd = ["bash", "-c", 'source "$1" && shift && exec dakota "$@"', "dakota-env",
               dakota_env] + dakota_args
    else:
        dakota_bin = os.path.join(software_dir, "dakota", "miniforge", "envs", "dakota",
                                  "bin", "dakota")
        cmd = [dakota_bin] + dakota_args
        env["PATH"] = os.path.dirname(dakota_bin) + os.pathsep + env.get("PATH", "")

    killed = False
    with open(os.path.join(dak_dir, "dakota.log"), "w") as log:
        proc = subprocess.Popen(cmd, cwd=dak_dir, stdout=log, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        try:
            deadline = time.time() + CAPTURE_TIMEOUT_S
            last_n, stable_since = 0, time.time()
            while proc.poll() is None:
                n = count_captures(iter_dir)
                if n >= batch:
                    killed = True
                    break
                if n != last_n:
                    last_n, stable_since = n, time.time()
                elif n >= 1 and time.time() - stable_since > CAPTURE_STABLE_S:
                    killed = True
                    break
                if time.time() > deadline:
                    killed = True
                    break
                time.sleep(0.5)
            if killed:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
            rc = proc.wait()
        finally:
            # reap any fork driver still blocked in its capture sleep
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass

    # killed before any evaluation completed -> the new restart file is empty;
    # keep the old one and let the deterministic replay re-propose
    if os.path.exists(rst_new):
        if os.path.getsize(rst_new) > 0:
            os.replace(rst_new, rst)
        else:
            os.remove(rst_new)
    return count_captures(iter_dir), (not killed and rc == 0)


def write_proposals(iter_dir, problem):
    """The proposed designs as one table, for whoever evaluates them by hand."""
    rows = ["case," + ",".join(v[0] for v in problem["variables"])]
    for case_dir in sorted(glob.glob(os.path.join(iter_dir, "case_*")),
                           key=lambda d: int(d.rsplit("_", 1)[1])):
        try:
            x = [v for _, v in read_pairs(os.path.join(case_dir, "params.in"))]
        except (OSError, ValueError):
            continue
        rows.append(os.path.basename(case_dir) + "," + ",".join("%.8e" % v for v in x))
    write_atomic(os.path.join(iter_dir, "proposals.csv"), "\n".join(rows) + "\n")
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--app-dir", required=True)
    ap.add_argument("--variables-file", required=True)
    ap.add_argument("--objectives", required=True)
    ap.add_argument("--batch-size", type=int, required=True)
    ap.add_argument("--max-generations", type=int, required=True)
    ap.add_argument("--stall-generations", type=int, default=3)
    ap.add_argument("--seed", type=int, default=4242)
    ap.add_argument("--dakota-env", default="")
    ap.add_argument("--software-dir",
                    default=os.environ.get("service_parent_install_dir",
                                           os.path.expanduser("~/pw/software")))
    args = ap.parse_args()
    if args.batch_size < 1:
        sys.exit("::error::optimizer: batch size must be at least 1")

    state_dir = os.path.abspath(args.state_dir)
    app_dir = os.path.abspath(args.app_dir)
    db_dir = os.path.join(state_dir, "results_db")
    os.makedirs(db_dir, exist_ok=True)
    problem = load_problem(state_dir, parse_variables(args.variables_file),
                           parse_objectives(args.objectives))
    state = load_state(state_dir)

    if state["gen"] >= 1:
        gen = state["gen"]
        results, failed, unrun = ingest(state_dir, gen, problem)
        if not results and not failed:
            # nothing ran (a platform hiccup, a canceled attempt): the evaluator was
            # never given a chance, so hand the same generation back once
            state["zero_results"] += 1
            if state["zero_results"] >= 2:
                stop(state_dir, state, problem, "FAILED",
                     "no case of generation %d ran on two attempts" % gen)
                print("::error::optimizer: no case of generation %d ran on two attempts "
                      "(no exit_code and no results.out in its case dirs); check the "
                      "evaluator's logs" % gen)
                return
            save_state(state_dir, state)
            iter_dir = os.path.join(state_dir, "iter_%d" % gen)
            n = count_captures(iter_dir)
            emit(state_dir, "CONTINUE", gen, n, iter_dir)
            notice("no case of generation %d ran; re-proposing its %d cases" % (gen, n))
            return
        state["zero_results"] = 0
        state["evals"] += len(results)
        for r in results:
            write_atomic(os.path.join(db_dir, r["key"]),
                         "\n".join("%.10e" % v for v in r["f"]) + "\n")
        # a case that ran and left no results.out failed in the evaluator (a marginal
        # design diverging, most often) — a result Dakota must see: record FAIL so
        # its failure_capture substitutes the recovery values instead of the point
        # being re-proposed forever. A case that never ran while its siblings did
        # gets the same treatment: the generation is over.
        for case, key, _ in failed:
            write_atomic(os.path.join(db_dir, key), "FAIL")
            notice("%s ran but left no results.out: marked FAIL for Dakota" % case)
        for case, key, _ in unrun:
            write_atomic(os.path.join(db_dir, key), "FAIL")
            notice("%s never ran while its siblings did: marked FAIL for Dakota" % case)
        append_evaluations(state_dir, problem, gen, results, failed, unrun)
        if results:
            state["failed_generations"] = 0
        else:
            state["failed_generations"] = state.get("failed_generations", 0) + 1
            where = os.path.join(state_dir, "iter_%d" % gen, "case_*")
            if state["evals"] == 0:
                stop(state_dir, state, problem, "FAILED",
                     "every case of generation %d ran and failed before any design "
                     "succeeded" % gen)
                print("::error::optimizer: every case of generation %d ran and failed "
                      "and no design has succeeded yet, so the evaluator setup rather than "
                      "a design point is the likely cause; read the evaluator logs under %s"
                      % (gen, where))
                return
            if state["failed_generations"] >= 3:
                stop(state_dir, state, problem, "FAILED",
                     "every case of %d consecutive generations ran and failed"
                     % state["failed_generations"])
                print("::error::optimizer: every case of %d consecutive generations ran "
                      "and failed; read the evaluator logs under %s"
                      % (state["failed_generations"], where))
                return
            print("::warning::optimizer: every case of generation %d ran and failed "
                  "(%d cases, fed back to Dakota as FAIL); the loop continues, see "
                  "the evaluator logs under %s" % (gen, len(failed) + len(unrun), where))
        state["history"] += [[r["f"][0], r["f"][1], gen] for r in results]
        state["front"] = select_front(state["front"] + results)
        if state["norm"] is None and results:
            lo = [min(r["f"][m] for r in results) for m in (0, 1)]
            hi = [max(r["f"][m] for r in results) for m in (0, 1)]
            span = [max(hi[m] - lo[m], 1e-9) for m in (0, 1)]
            state["norm"] = {"lo": [lo[m] - 0.5 * span[m] for m in (0, 1)],
                             "span": [2.0 * span[m] for m in (0, 1)]}
        hv = hypervolume(state) if state["norm"] else 0.0
        gain = hv - state["hv_history"][-1] if state["hv_history"] else hv
        state["hv_history"].append(hv)
        write_front(state_dir, state, problem)
        notice("gen %d: %d/%d results (%d failed, %d never ran), %d evaluations "
               "total, front %d, hypervolume %.4f (%+.4f)"
               % (gen, len(results), args.batch_size, len(failed), len(unrun),
                  state["evals"], len(state["front"]), hv, gain))

    hist = state["hv_history"]
    if state["gen"] >= args.max_generations:
        stop(state_dir, state, problem, "CONVERGED", "generation budget reached")
        return
    if len(hist) > args.stall_generations and \
            hist[-1] - hist[-1 - args.stall_generations] < STALL_TOL:
        stop(state_dir, state, problem, "CONVERGED",
             "front stagnated for %d generations" % args.stall_generations)
        return

    next_gen = state["gen"] + 1
    iter_dir = os.path.join(state_dir, "iter_%d" % next_gen)
    if os.path.exists(iter_dir):
        # a crashed attempt's half-written proposal; state.json never advanced
        subprocess.run(["rm", "-rf", iter_dir], check=True)
    os.makedirs(iter_dir)

    n, dakota_done = run_dakota_capture(
        state_dir, app_dir, problem, args.batch_size, args.seed, iter_dir, args.software_dir,
        os.path.abspath(args.dakota_env) if args.dakota_env else "")
    if n > 0:
        state["gen"] = next_gen
        save_state(state_dir, state)
        table = write_proposals(iter_dir, problem)
        emit(state_dir, "CONTINUE", next_gen, n, iter_dir)
        notice("gen %d: Dakota proposed %d cases under %s" % (next_gen, n, iter_dir))
        print(table)
    elif dakota_done:
        stop(state_dir, state, problem, "CONVERGED", "Dakota's convergence criteria satisfied")
    else:
        stop(state_dir, state, problem, "FAILED",
             "Dakota exited without proposing cases or converging; see %s"
             % os.path.join(state_dir, "dakota", "dakota.log"))
        print("::error::optimizer: Dakota neither proposed new evaluations nor "
              "finished cleanly; read state/dakota/dakota.log")


if __name__ == "__main__":
    sys.exit(main())
