#!/usr/bin/env python3
"""The state of a study of NACA airfoil cases: every case directory read into one table.

    study.py --cases-dir DIR [--results results.csv] [--data-csv data.csv] [--summary]

Two layouts are read, told apart by what DIR holds:

    doe            DIR/case_<j>/              a design of experiments (doe-openfoam)
    optimization   DIR/iter_<N>/case_<j>/     a Dakota study (dakota-openfoam's state/),
                                              N the generation that proposed the case

Each case directory is one call of workflows/openfoam-naca: params.in (the
design) goes in, results.out (the coefficients) or exit_code without it (the
solver failed) comes out, and images/*.png when images were requested. A case
with neither results.out nor exit_code has not run yet (PENDING).

--results writes every case with its status (the record of the run);
--data-csv writes the solved cases in Design Explorer's format
(https://tt-acm.github.io/DesignExplorer/): `in:` columns for the inputs,
`out:` columns for the outputs, `img:` columns with the image paths relative to
DIR. An optimization adds `in:generation` and `out:pareto_front` (1 for the
designs no other solved design beats on both drag and lift). The server imports
collect() and writes the same table on every request. Standard library only.
"""

import argparse
import csv
import glob
import os
import re
import sys

IMAGES = ("pressure", "velocity", "streamlines", "turbulence", "wake", "mesh")
OUTPUTS = ("drag_coefficient", "lift_coefficient", "lift_to_drag")


def read_pairs(path):
    """[(name, value)] from a '<value> <name>' per line file, in file order."""
    pairs = []
    try:
        with open(path) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        pairs.append((parts[1], float(parts[0])))
                    except ValueError:
                        continue
    except OSError:
        return []
    return pairs


def number_after(prefix, path):
    m = re.search(prefix + r"_(\d+)$", path)
    return int(m.group(1)) if m else 0


def layout(cases_dir):
    """'optimization' for a Dakota study directory, 'doe' otherwise. A study
    whose first generation is not proposed yet has only problem.json (or
    nothing at all), so the optimizer's own files count too."""
    if glob.glob(os.path.join(cases_dir, "iter_*")):
        return "optimization"
    for name in ("problem.json", "state.json", "status"):
        if os.path.exists(os.path.join(cases_dir, name)):
            return "optimization"
    return "doe"


def case_dirs(cases_dir):
    """(case id relative to cases_dir, generation or None, path), in order."""
    found = []
    for path in glob.glob(os.path.join(cases_dir, "case_*")):
        if os.path.isdir(path):
            found.append((None, number_after("case", path), path))
    for path in glob.glob(os.path.join(cases_dir, "iter_*", "case_*")):
        if os.path.isdir(path):
            found.append((number_after("iter", os.path.dirname(path)), number_after("case", path), path))
    found.sort(key=lambda t: (t[0] or 0, t[1]))
    return [(os.path.relpath(p, cases_dir), g, p) for g, _, p in found]


def collect(cases_dir):
    """One dict per case directory, in generation and case order."""
    rows = []
    for name, generation, case_dir in case_dirs(cases_dir):
        inputs = read_pairs(os.path.join(case_dir, "params.in"))
        results = dict(read_pairs(os.path.join(case_dir, "results.out")))
        outputs = None
        if "drag_coefficient" in results and "neg_lift_coefficient" in results:
            cd, cl = results["drag_coefficient"], -results["neg_lift_coefficient"]
            outputs = {"drag_coefficient": cd, "lift_coefficient": cl,
                       "lift_to_drag": cl / cd if cd else float("nan")}
        exit_code = ""
        try:
            with open(os.path.join(case_dir, "exit_code")) as fh:
                exit_code = fh.read().strip()
        except OSError:
            pass
        if outputs is not None:
            status = "OK"
        elif exit_code != "":
            status = "FAILED"
        else:
            status = "PENDING"
        images = {}
        for image in IMAGES:
            if os.path.isfile(os.path.join(case_dir, "images", image + ".png")):
                images[image] = "%s/images/%s.png" % (name, image)
        rows.append({"case": name, "generation": generation, "inputs": inputs,
                     "outputs": outputs, "status": status, "exit_code": exit_code,
                     "images": images})
    return rows


def input_names(rows):
    names = []
    for row in rows:
        for name, _ in row["inputs"]:
            if name not in names:
                names.append(name)
    return names


def pareto_front(rows):
    """Case names of the solved designs that no other solved design beats on
    both objectives: lower drag and higher lift (the optimizer's two)."""
    solved = [r for r in rows if r["status"] == "OK"]
    front = set()
    for r in solved:
        cd, cl = r["outputs"]["drag_coefficient"], r["outputs"]["lift_coefficient"]
        dominated = any(
            o is not r
            and o["outputs"]["drag_coefficient"] <= cd and o["outputs"]["lift_coefficient"] >= cl
            and (o["outputs"]["drag_coefficient"] < cd or o["outputs"]["lift_coefficient"] > cl)
            for o in solved)
        if not dominated:
            front.add(r["case"])
    return front


def fmt(value):
    return "%.10g" % value


def write_results_csv(rows, path):
    """Every case: case, [generation], status, inputs, outputs, exit code, images."""
    names = input_names(rows)
    nested = any(r["generation"] is not None for r in rows)
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["case"] + (["generation"] if nested else []) + ["status"]
                        + names + list(OUTPUTS) + ["exit_code", "images"])
        for row in rows:
            values = dict(row["inputs"])
            out = row["outputs"] or {}
            writer.writerow([row["case"]] + ([row["generation"]] if nested else []) + [row["status"]]
                            + [fmt(values[n]) if n in values else "" for n in names]
                            + [fmt(out[o]) if o in out else "" for o in OUTPUTS]
                            + [row["exit_code"], ",".join(sorted(row["images"]))])
    os.replace(tmp, path)


def design_explorer_rows(rows, missing_image="no-image.png"):
    """Header and rows of the Design Explorer table: the solved cases only (a
    row without numbers would break its axes), image columns only when some
    case has images, a placeholder where one case lacks an image. An
    optimization's cases also carry their generation and the front flag."""
    solved = [r for r in rows if r["status"] == "OK"]
    names = input_names(solved)
    nested = any(r["generation"] is not None for r in solved)
    front = pareto_front(rows) if nested else set()
    with_images = [i for i in IMAGES if any(i in r["images"] for r in solved)]
    header = ((["in:generation"] if nested else []) + ["in:" + n for n in names]
              + ["out:" + o for o in OUTPUTS] + (["out:pareto_front"] if nested else [])
              + ["img:" + i for i in with_images] + ["case"])
    table = []
    for row in solved:
        values = dict(row["inputs"])
        table.append(([str(row["generation"])] if nested else [])
                     + [fmt(values[n]) if n in values else "" for n in names]
                     + [fmt(row["outputs"][o]) for o in OUTPUTS]
                     + (["1" if row["case"] in front else "0"] if nested else [])
                     + [row["images"].get(i, missing_image) for i in with_images]
                     + [row["case"]])
    return header, table


def write_design_explorer_csv(rows, path):
    header, table = design_explorer_rows(rows)
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(header)
        writer.writerows(table)
    os.replace(tmp, path)


def summary(rows, cases_dir=None):
    """The counts, and whether the study has finished: a design of experiments
    when no case is pending, an optimization when the optimizer's status is
    final (between generations no case is pending, but more will come)."""
    counts = {"OK": 0, "FAILED": 0, "PENDING": 0}
    for row in rows:
        counts[row["status"]] += 1
    s = {"total": len(rows), "ok": counts["OK"], "failed": counts["FAILED"],
         "pending": counts["PENDING"], "images": sum(1 for r in rows if r["images"]),
         "layout": "doe", "generation": 0, "study_status": ""}
    if cases_dir is not None and layout(cases_dir) == "optimization":
        s["layout"] = "optimization"
        s["generation"] = max([r["generation"] or 0 for r in rows] + [0])
        try:
            with open(os.path.join(cases_dir, "status")) as fh:
                s["study_status"] = fh.read().strip()
        except OSError:
            s["study_status"] = ""
        s["final"] = s["study_status"] in ("CONVERGED", "FAILED")
        s["state"] = ("complete" if s["study_status"] == "CONVERGED" else
                      "failed" if s["study_status"] == "FAILED" else "running")
    else:
        s["final"] = s["total"] > 0 and s["pending"] == 0
        s["state"] = ("running" if not s["final"] else "complete" if s["ok"] else "failed")
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases-dir", required=True,
                    help="a design of experiments' cases/ or a Dakota study's state/")
    ap.add_argument("--results", help="write every case with its status to this CSV")
    ap.add_argument("--data-csv", help="write the solved cases in Design Explorer's format to this CSV")
    ap.add_argument("--summary", action="store_true", help="print the counts as KEY=value lines")
    args = ap.parse_args()
    rows = collect(args.cases_dir)
    if args.results:
        write_results_csv(rows, args.results)
    if args.data_csv:
        write_design_explorer_csv(rows, args.data_csv)
    if args.summary:
        s = summary(rows, args.cases_dir)
        for key in ("total", "ok", "failed", "pending", "images"):
            print("CASES_%s=%d" % (key.upper(), s[key]))
    if not (args.results or args.data_csv or args.summary):
        names = input_names(rows)
        print("case\tstatus\t" + "\t".join(names) + "\tCd\tCl\timages")
        for row in rows:
            values = dict(row["inputs"])
            out = row["outputs"] or {}
            print("\t".join([row["case"], row["status"]]
                            + ["%.4g" % values[n] if n in values else "" for n in names]
                            + ["%.4f" % out["drag_coefficient"] if out else "",
                               "%.3f" % out["lift_coefficient"] if out else "",
                               str(len(row["images"]))]))


if __name__ == "__main__":
    sys.exit(main())
