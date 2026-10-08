#!/usr/bin/env python3
"""The state of a study: every case directory read into one table.

    study.py --cases-dir DIR [--results results.csv] [--data-csv data.csv] [--summary]

Two layouts are read, told apart by what DIR holds:

    doe            DIR/case_<j>/              a design of experiments, such as the
                                              cases/ workflows/doe writes
    optimization   DIR/iter_<N>/case_<j>/     a Dakota study (workflows/dakota's state
                                              directory), N the generation that
                                              proposed the case

A case directory is one evaluation: params.in (the design, one "<value> <name>"
line per variable) goes in; results.out (the outputs, the same format) or
exit_code without it (the evaluation failed) comes out, with images/*.png when
the evaluator renders any. A case with neither results.out nor exit_code has not
run yet (PENDING). Every value of results.out is an output, except the pair
workflows/openfoam-naca writes (drag_coefficient, neg_lift_coefficient), which
reads as the drag and lift coefficients and their ratio; its images come first,
in the order it renders them.

--results writes every case with its status (the record of the run);
--data-csv writes the solved cases in Design Explorer's format
(https://tt-acm.github.io/DesignExplorer/): `in:` columns for the inputs,
`out:` columns for the outputs, `img:` columns with the image paths relative to
DIR. An optimization adds `in:generation` and `out:pareto_front` (1 for the
designs no other solved design beats on every objective, the results.out values,
minimized as Dakota minimizes them). The server imports collect() and writes the
same table on every request. Standard library only.
"""

import argparse
import csv
import glob
import os
import re
import sys

# the images workflows/openfoam-naca renders, offered first and in this order;
# any other images/*.png of a case follows, by name
KNOWN_IMAGES = ("pressure", "velocity", "streamlines", "turbulence", "wake", "mesh")


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


def outputs_of(results):
    """[(name, value)] of one case's outputs from its results.out pairs: every
    value as written, but openfoam-naca's (drag_coefficient,
    neg_lift_coefficient) as the drag and lift coefficients and Cl/Cd."""
    values = dict(results)
    if "drag_coefficient" in values and "neg_lift_coefficient" in values:
        cd, cl = values["drag_coefficient"], -values["neg_lift_coefficient"]
        naca = [("drag_coefficient", cd), ("lift_coefficient", cl),
                ("lift_to_drag", cl / cd if cd else float("nan"))]
        return naca + [(n, v) for n, v in results
                       if n not in ("drag_coefficient", "neg_lift_coefficient")]
    return list(results)


def image_names(case_dir):
    names = [os.path.splitext(os.path.basename(p))[0]
             for p in glob.glob(os.path.join(case_dir, "images", "*.png"))]
    known = [n for n in KNOWN_IMAGES if n in names]
    return known + sorted(n for n in names if n not in known)


def collect(cases_dir):
    """One dict per case directory, in generation and case order."""
    rows = []
    for name, generation, case_dir in case_dirs(cases_dir):
        inputs = read_pairs(os.path.join(case_dir, "params.in"))
        objectives = read_pairs(os.path.join(case_dir, "results.out"))
        outputs = dict(outputs_of(objectives)) if objectives else None
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
        for image in image_names(case_dir):
            images[image] = "%s/images/%s.png" % (name, image)
        rows.append({"case": name, "generation": generation, "inputs": inputs,
                     "outputs": outputs, "objectives": objectives, "status": status,
                     "exit_code": exit_code, "images": images})
    return rows


def input_names(rows):
    names = []
    for row in rows:
        for name, _ in row["inputs"]:
            if name not in names:
                names.append(name)
    return names


def ordered_names(dicts):
    """Keys in order of first appearance."""
    names = []
    for d in dicts:
        for name in d:
            if name not in names:
                names.append(name)
    return names


def output_names(rows, every=False):
    """The output names of the solved cases: all of them, or (every=True) those
    every solved case has, so that no row of the Design Explorer table lacks a
    value on an axis."""
    outs = [r["outputs"] for r in rows if r["status"] == "OK"]
    names = ordered_names(outs)
    return [n for n in names if all(n in o for o in outs)] if every else names


def pareto_front(rows):
    """Case names of the solved designs that no other solved design beats on
    every objective: the results.out values, all minimized, as Dakota states
    them (openfoam-naca's are the drag and the negative lift, so lower drag and
    higher lift)."""
    solved = [r for r in rows if r["status"] == "OK"]
    names = [n for n in ordered_names(dict(r["objectives"]) for r in solved)
             if all(n in dict(r["objectives"]) for r in solved)]
    if not names:
        return set()
    points = {r["case"]: [dict(r["objectives"])[n] for n in names] for r in solved}
    front = set()
    for case, p in points.items():
        dominated = any(
            other != case and all(a <= b for a, b in zip(q, p)) and any(a < b for a, b in zip(q, p))
            for other, q in points.items())
        if not dominated:
            front.add(case)
    return front


def fmt(value):
    return "%.10g" % value


def write_results_csv(rows, path):
    """Every case: case, [generation], status, inputs, outputs, exit code, images."""
    names = input_names(rows)
    outputs = output_names(rows)
    nested = any(r["generation"] is not None for r in rows)
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["case"] + (["generation"] if nested else []) + ["status"]
                        + names + outputs + ["exit_code", "images"])
        for row in rows:
            values = dict(row["inputs"])
            out = row["outputs"] or {}
            writer.writerow([row["case"]] + ([row["generation"]] if nested else []) + [row["status"]]
                            + [fmt(values[n]) if n in values else "" for n in names]
                            + [fmt(out[o]) if o in out else "" for o in outputs]
                            + [row["exit_code"], ",".join(sorted(row["images"]))])
    os.replace(tmp, path)


def design_explorer_rows(rows, missing_image="no-image.png"):
    """Header and rows of the Design Explorer table: the solved cases only (a
    row without numbers would break its axes), image columns only when some
    case has images, a placeholder where one case lacks an image. An
    optimization's cases also carry their generation and the front flag."""
    solved = [r for r in rows if r["status"] == "OK"]
    names = input_names(solved)
    outputs = output_names(rows, every=True)
    nested = any(r["generation"] is not None for r in solved)
    front = pareto_front(rows) if nested else set()
    with_images = ordered_names(r["images"] for r in solved)
    known = [i for i in KNOWN_IMAGES if i in with_images]
    with_images = known + sorted(i for i in with_images if i not in known)
    header = ((["in:generation"] if nested else []) + ["in:" + n for n in names]
              + ["out:" + o for o in outputs] + (["out:pareto_front"] if nested else [])
              + ["img:" + i for i in with_images] + ["case"])
    table = []
    for row in solved:
        values = dict(row["inputs"])
        table.append(([str(row["generation"])] if nested else [])
                     + [fmt(values[n]) if n in values else "" for n in names]
                     + [fmt(row["outputs"][o]) for o in outputs]
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
                    help="a directory of case_<j>/ (a design of experiments) or iter_<N>/case_<j>/ (a Dakota study)")
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
        names, outputs = input_names(rows), output_names(rows)
        print("\t".join(["case", "status"] + names + outputs + ["images"]))
        for row in rows:
            values = dict(row["inputs"])
            out = row["outputs"] or {}
            print("\t".join([row["case"], row["status"]]
                             + ["%.4g" % values[n] if n in values else "" for n in names]
                             + ["%.4g" % out[o] if o in out else "" for o in outputs]
                             + [str(len(row["images"]))]))


if __name__ == "__main__":
    sys.exit(main())
