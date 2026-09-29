#!/usr/bin/env python3
"""Dakota-backed optimizer: propose-or-stop, driven by Dakota's restart file.

Same contract and call signature as tutorials/optimization/app/optimizer.py:

    optimizer.py --state-dir S --app-dir A --batch-size B \
                 --max-iterations G --stall-generations K

Each call ingests the results of the generation it proposed last time, then either
proposes the next generation or stops:

  propose:  S/iter_<N>/case_<j>/{params.in,run.sh}  (j = 1..B)
            S/status = CONTINUE, S/proposal.env with N_CASES and ITER_DIR
  stop:     S/pareto.csv + S/pareto.svg (the non-dominated front found)
            S/status = CONVERGED (budget, stagnation or Dakota's own criteria)
            or FAILED, N_CASES = 0

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
after the case dirs, so a crashed attempt re-runs safely (a generation that comes
back with zero results is re-proposed as-is; twice in a row -> FAILED).
"""

import argparse
import glob
import json
import os
import signal
import subprocess
import sys
import time

VARIABLES = [
    # (dakota descriptor, lower bound, upper bound) — NACA 4-digit parameters;
    # the box is the realistic 4-digit family: the mesh generator was validated
    # at every corner, and higher forward camber breaks the C-grid quality
    ("max_camber", 0.0, 0.06),
    ("camber_position", 0.3, 0.6),
    ("thickness", 0.08, 0.18),
]
OBJECTIVES = ["drag_coefficient", "neg_lift_coefficient"]  # both minimized
DAKOTA_SEED = 4242          # fixed: restart replay requires a deterministic method
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


def load_state(state_dir):
    path = os.path.join(state_dir, "state.json")
    if os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    return {"gen": 0, "front": [], "hv_history": [], "zero_results": 0,
            "evals": 0, "history": [], "norm": None}


def save_state(state_dir, state):
    write_atomic(os.path.join(state_dir, "state.json"), json.dumps(state, indent=1))


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
    """Collect {x, f} for every case of generation `gen` that produced a result,
    and return the (case_dir, hash) of the ones that did not."""
    done, missing = [], []
    for case_dir in sorted(glob.glob(os.path.join(state_dir, "iter_%d" % gen, "case_*"))):
        try:
            with open(os.path.join(case_dir, "param.hash")) as fh:
                key = fh.read().strip()
        except OSError:
            continue
        try:
            f = read_floats(os.path.join(case_dir, "results.out"))
            x = read_floats(os.path.join(case_dir, "params.in"))
        except (OSError, ValueError):
            missing.append((case_dir, key))
            continue
        if len(f) >= len(OBJECTIVES) and len(x) == len(VARIABLES):
            done.append({"x": x, "f": f[:len(OBJECTIVES)], "key": key})
        else:
            missing.append((case_dir, key))
    return done, missing


def dominates(a, b):
    return a[0] <= b[0] and a[1] <= b[1] and (a[0] < b[0] or a[1] < b[1])


def select_front(individuals):
    fs = [ind["f"] for ind in individuals]
    return [ind for i, ind in enumerate(individuals)
            if not any(dominates(fs[j], fs[i]) for j in range(len(fs)) if j != i)]


def hypervolume(state):
    """2D hypervolume of the front, on objectives normalized by the bounds frozen
    at the first ingest (the objective scales here are arbitrary), ref (1.1, 1.1)."""
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


def write_plot(state_dir, state):
    """Render state/pareto.svg: every evaluation and the current front. Pure
    stdlib so it renders anywhere the loop runs."""
    pts = [p[:2] for p in state["history"]]
    if not pts:
        return
    front = sorted(ind["f"] for ind in state["front"])
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
             'text-anchor="middle">%s</text>' % (ml + iw / 2, height - 8, OBJECTIVES[0]))
    s.append('<text x="16" y="%.1f" font-size="13" fill="#0b0b0b" text-anchor="middle" '
             'transform="rotate(-90 16 %.1f)">%s</text>'
             % (mt + ih / 2, mt + ih / 2, OBJECTIVES[1]))
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


def stop(state_dir, state, status, reason):
    front = sorted(state["front"], key=lambda ind: ind["f"][0])
    header = ",".join(OBJECTIVES) + "," + ",".join(name for name, _, _ in VARIABLES)
    rows = [header]
    for ind in front:
        rows.append(",".join(["%.10f" % v for v in ind["f"]] +
                             ["%.8e" % v for v in ind["x"]]))
    write_atomic(os.path.join(state_dir, "pareto.csv"), "\n".join(rows) + "\n")
    write_plot(state_dir, state)
    save_state(state_dir, state)
    emit(state_dir, status, 0, os.path.join(state_dir, "iter_%d" % state["gen"]))
    notice("%s after %d generations, %d evaluations: %s (front of %d written to "
           "pareto.csv, plotted in pareto.svg)"
           % (status, state["gen"], state["evals"], reason, len(front)))


def write_dakota_input(dak_dir, app_dir, batch):
    names = " ".join("'%s'" % name for name, _, _ in VARIABLES)
    lower = " ".join("%g" % lo for _, lo, _ in VARIABLES)
    upper = " ".join("%g" % hi for _, _, hi in VARIABLES)
    obj = " ".join("'%s'" % name for name in OBJECTIVES)
    recovery = " ".join("1.0e3" for _ in OBJECTIVES)
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
""" % (DAKOTA_SEED, batch, len(VARIABLES), names, lower, upper,
       os.path.join(app_dir, "driver.py"), recovery, batch, len(OBJECTIVES), obj)
    write_atomic(os.path.join(dak_dir, "dakota.in"), content)


def count_captures(iter_dir):
    return len([d for d in glob.glob(os.path.join(iter_dir, "case_*"))
                if os.path.exists(os.path.join(d, "run.sh"))])


def run_dakota_capture(state_dir, app_dir, batch, iter_dir, software_dir, mesh_scale):
    """Resume Dakota and capture the next batch of case dirs it proposes.
    Returns (n_captured, dakota_exited_cleanly)."""
    dak_dir = os.path.join(state_dir, "dakota")
    os.makedirs(dak_dir, exist_ok=True)
    write_dakota_input(dak_dir, app_dir, batch)
    rst = os.path.join(dak_dir, "dakota.rst")
    rst_new = os.path.join(dak_dir, "dakota_new.rst")

    dakota_bin = os.path.join(software_dir, "dakota-openfoam", "miniforge",
                              "envs", "dakota", "bin", "dakota")
    cmd = [dakota_bin, "-input", "dakota.in", "-write_restart", "dakota_new.rst"]
    if os.path.exists(rst) and os.path.getsize(rst) > 0:
        cmd += ["-read_restart", "dakota.rst"]

    env = dict(os.environ,
               PATH=os.path.dirname(dakota_bin) + os.pathsep + os.environ.get("PATH", ""),
               DAK_CAPTURE_DIR=iter_dir,
               DAK_RESULTS_DB=os.path.join(state_dir, "results_db"),
               DAK_APP_DIR=app_dir,
               DAK_MESH_SCALE=str(mesh_scale))

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--app-dir", required=True)
    ap.add_argument("--batch-size", type=int, required=True)
    ap.add_argument("--max-iterations", type=int, required=True)
    ap.add_argument("--stall-generations", type=int, default=3)
    ap.add_argument("--mesh-scale", type=int, default=1)
    ap.add_argument("--software-dir",
                    default=os.environ.get("service_parent_install_dir",
                                           os.path.expanduser("~/pw/software")))
    args = ap.parse_args()

    state_dir = os.path.abspath(args.state_dir)
    app_dir = os.path.abspath(args.app_dir)
    db_dir = os.path.join(state_dir, "results_db")
    os.makedirs(db_dir, exist_ok=True)
    state = load_state(state_dir)

    if state["gen"] >= 1:
        results, missing = ingest(state_dir, state["gen"])
        if not results:
            state["zero_results"] += 1
            if state["zero_results"] >= 2:
                stop(state_dir, state, "FAILED",
                     "generation %d returned no results twice in a row" % state["gen"])
                print("::error::optimizer: no case of generation %d produced a "
                      "results.out on two attempts; check the workers' logs"
                      % state["gen"])
                return
            # the case dirs are intact; hand the same generation back to the
            # workers — minus the wave markers, which the next decide must only
            # see from the re-run
            save_state(state_dir, state)
            iter_dir = os.path.join(state_dir, "iter_%d" % state["gen"])
            for marker in glob.glob(os.path.join(iter_dir, "case_*", ".wave_done")):
                os.remove(marker)
            n = len(glob.glob(os.path.join(iter_dir, "case_*")))
            emit(state_dir, "CONTINUE", n, iter_dir)
            notice("generation %d returned no results; re-proposing its %d cases"
                   % (state["gen"], n))
            return
        state["zero_results"] = 0
        state["evals"] += len(results)
        for r in results:
            write_atomic(os.path.join(db_dir, r["key"]),
                         "\n".join("%.10e" % v for v in r["f"]) + "\n")
        # a case that crashed while its siblings succeeded is a genuine failure:
        # record FAIL so Dakota's failure_capture substitutes its recovery values
        # instead of the point being re-proposed forever
        for case_dir, key in missing:
            write_atomic(os.path.join(db_dir, key), "FAIL")
            notice("case %s left no results.out: marked FAIL for Dakota"
                   % os.path.basename(case_dir))
        state["history"] += [[r["f"][0], r["f"][1], state["gen"]] for r in results]
        state["front"] = select_front(state["front"] + results)
        if state["norm"] is None:
            lo = [min(r["f"][m] for r in results) for m in (0, 1)]
            hi = [max(r["f"][m] for r in results) for m in (0, 1)]
            span = [max(hi[m] - lo[m], 1e-9) for m in (0, 1)]
            state["norm"] = {"lo": [lo[m] - 0.5 * span[m] for m in (0, 1)],
                             "span": [2.0 * span[m] for m in (0, 1)]}
        hv = hypervolume(state)
        gain = hv - state["hv_history"][-1] if state["hv_history"] else hv
        state["hv_history"].append(hv)
        write_plot(state_dir, state)
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
    iter_dir = os.path.join(state_dir, "iter_%d" % next_gen)
    if os.path.exists(iter_dir):
        # a crashed attempt's half-written proposal; state.json never advanced
        subprocess.run(["rm", "-rf", iter_dir], check=True)
    os.makedirs(iter_dir)

    n, dakota_done = run_dakota_capture(state_dir, app_dir, args.batch_size,
                                        iter_dir, args.software_dir, args.mesh_scale)
    if n > 0:
        state["gen"] = next_gen
        save_state(state_dir, state)
        emit(state_dir, "CONTINUE", n, iter_dir)
        notice("gen %d: Dakota proposed %d cases under %s" % (next_gen, n, iter_dir))
    elif dakota_done:
        stop(state_dir, state, "CONVERGED", "Dakota's convergence criteria satisfied")
    else:
        stop(state_dir, state, "FAILED",
             "Dakota exited without proposing cases or converging; see %s"
             % os.path.join(state_dir, "dakota", "dakota.log"))
        print("::error::optimizer: Dakota neither proposed new evaluations nor "
              "finished cleanly; read state/dakota/dakota.log")


if __name__ == "__main__":
    sys.exit(main())
