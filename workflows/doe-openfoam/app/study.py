#!/usr/bin/env python3
"""The state of a design of experiments: every case directory read into one table.

    study.py --cases-dir cases [--results results.csv] [--data-csv data.csv] [--summary]

Each cases/case_<j>/ is one call of workflows/openfoam-naca: params.in (the
design) goes in, results.out (the coefficients) or exit_code without it (the
solver failed) comes out, and images/*.png when images were requested. A case
with neither results.out nor exit_code has not run yet (PENDING).

--results writes every case with its status (the record of the run);
--data-csv writes the solved cases in Design Explorer's format
(https://tt-acm.github.io/DesignExplorer/): `in:` columns for the inputs,
`out:` columns for the outputs, `img:` columns with the image paths relative to
the folder the CSV is served from. The server imports collect() and writes the
same table on every request. Standard library only.
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


def case_number(path):
    m = re.search(r"case_(\d+)$", path)
    return int(m.group(1)) if m else 0


def collect(cases_dir):
    """One dict per case directory, in case order."""
    rows = []
    for case_dir in sorted(glob.glob(os.path.join(cases_dir, "case_*")), key=case_number):
        if not os.path.isdir(case_dir):
            continue
        name = os.path.basename(case_dir)
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
        rows.append({"case": name, "index": case_number(case_dir), "inputs": inputs,
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


def fmt(value):
    return "%.10g" % value


def write_results_csv(rows, path):
    """Every case: case, status, inputs, outputs, exit code, images directory."""
    names = input_names(rows)
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["case", "status"] + names + list(OUTPUTS) + ["exit_code", "images"])
        for row in rows:
            values = dict(row["inputs"])
            out = row["outputs"] or {}
            writer.writerow([row["case"], row["status"]]
                            + [fmt(values[n]) if n in values else "" for n in names]
                            + [fmt(out[o]) if o in out else "" for o in OUTPUTS]
                            + [row["exit_code"], ",".join(sorted(row["images"])) ])
    os.replace(tmp, path)


def design_explorer_rows(rows, missing_image="no-image.png"):
    """Header and rows of the Design Explorer table: the solved cases only (a
    row without numbers would break its axes), image columns only when some
    case has images, a placeholder where one case lacks an image."""
    solved = [r for r in rows if r["status"] == "OK"]
    names = input_names(solved)
    with_images = [i for i in IMAGES if any(i in r["images"] for r in solved)]
    header = (["in:" + n for n in names] + ["out:" + o for o in OUTPUTS]
              + ["img:" + i for i in with_images] + ["case"])
    table = []
    for row in solved:
        values = dict(row["inputs"])
        table.append([fmt(values[n]) if n in values else "" for n in names]
                     + [fmt(row["outputs"][o]) for o in OUTPUTS]
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


def summary(rows):
    counts = {"OK": 0, "FAILED": 0, "PENDING": 0}
    for row in rows:
        counts[row["status"]] += 1
    return {"total": len(rows), "ok": counts["OK"], "failed": counts["FAILED"],
            "pending": counts["PENDING"],
            "images": sum(1 for r in rows if r["images"])}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases-dir", required=True)
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
        s = summary(rows)
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
