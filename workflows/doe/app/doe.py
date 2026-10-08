#!/usr/bin/env python3
"""Design of experiments: sample the design variables and write one case per sample.

    doe.py --method lhs --n-cases 8 --seed 4242 --variables-file variables.txt --out-dir cases
    doe.py --method csv --cases-csv cases.csv --variables-file variables.txt --out-dir cases

variables.txt has one "<name> <lower> <upper>" line per variable; a variable
whose bounds are equal is fixed and takes no sampling dimension. The output
directory gets:

    case_<j>/params.in   the design, one "<value> <name>" line per variable
                         (the Dakota-style file workflows/openfoam-naca reads)
    doe.csv              the same designs as a table (case, <name>...)
    doe.env              N_CASES=<n> CASES_DIR=<dir> METHOD=<method> lines

and the doe.env lines are printed on stdout, so `doe.py ... | tee -a $OUTPUTS`
publishes them as step outputs. Standard library only.

Methods (points in the unit cube, scaled to the bounds):

    lhs             Latin hypercube: every variable is split into n strata and
                    each stratum is used exactly once, at a random position in it
    sobol           Sobol quasi-random sequence (Joe-Kuo direction numbers, up to
                    7 dimensions) shifted by a seeded random vector: even coverage
                    at any n, the shift makes the seed matter
    random          independent uniform samples (Monte Carlo)
    full_factorial  a regular grid of L levels per variable, the largest L with
                    L^d <= n (at least 2), so L^d cases
    one_at_a_time   the center of the box plus, for each variable in turn, k
                    evenly spaced levels across its range with the others held
                    at the center (k = (n - 1) // d, at least 2): a sensitivity
                    screening, 1 + d*k cases
    csv             the designs of a table the user gives (--cases-csv), one row
                    per case under a header naming the variables. Commas, tabs
                    (a paste from a spreadsheet), semicolons or spaces separate
                    the values. Columns that are not design variables but a study
                    file carries are skipped (case, generation, status, the
                    coefficients, Design Explorer's out: and img: columns; its in:
                    prefix is dropped), so a previous doe.csv, results.csv or
                    data.csv pastes as it is; any other column is an error. A
                    variable the table leaves out is held at the middle of its
                    bounds, and a value outside its bounds is warned about.
"""

import argparse
import csv
import math
import os
import random
import sys

METHODS = ("lhs", "sobol", "random", "full_factorial", "one_at_a_time", "csv")

# columns a study's own tables carry next to the design variables: a pasted
# doe.csv, results.csv or Design Explorer data.csv keeps them, and they say
# nothing about the design
SKIPPED_COLUMNS = ("case", "name", "id", "label", "generation", "status", "exit_code",
                   "images", "drag_coefficient", "lift_coefficient", "lift_to_drag",
                   "neg_lift_coefficient", "pareto_front")


def fail(message):
    print("::error::" + message, flush=True)
    sys.exit(1)

# Sobol direction numbers for dimensions 2-7 (dimension 1 is the van der Corput
# sequence in base 2) from Joe & Kuo's new-joe-kuo-6.21201: (s, a, m_1..m_s)
JOE_KUO = [
    (1, 0, [1]),
    (2, 1, [1, 3]),
    (3, 1, [1, 3, 1]),
    (3, 2, [1, 1, 1]),
    (4, 1, [1, 1, 3, 3]),
    (4, 4, [1, 3, 5, 13]),
]


def read_variables(path):
    variables = []
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if not parts or parts[0].startswith("#"):
                continue
            if len(parts) != 3:
                fail("variables file: expected '<name> <lower> <upper>', got %r" % line.strip())
            name, lo, hi = parts[0], float(parts[1]), float(parts[2])
            if hi < lo:
                fail("variables file: %s has upper bound %g below lower bound %g" % (name, hi, lo))
            variables.append((name, lo, hi))
    if not variables:
        fail("variables file: no variables")
    names = [v[0] for v in variables]
    if len(set(names)) != len(names):
        fail("variables file: a variable is listed twice")
    return variables


def sobol_points(n, d, bits=30):
    """The first n points of the d-dimensional Sobol sequence (Gray code order)."""
    if d > len(JOE_KUO) + 1:
        sys.exit("sobol: direction numbers for up to %d dimensions only" % (len(JOE_KUO) + 1))
    scale = 2.0 ** bits
    # direction numbers v[j][k] for each dimension, as integers scaled by 2^bits
    v = []
    for j in range(d):
        vj = [0] * bits
        if j == 0:
            for k in range(bits):
                vj[k] = 1 << (bits - 1 - k)
        else:
            s, a, m = JOE_KUO[j - 1]
            for k in range(min(s, bits)):
                vj[k] = m[k] << (bits - 1 - k)
            for k in range(s, bits):
                vj[k] = vj[k - s] ^ (vj[k - s] >> s)
                for i in range(1, s):
                    vj[k] ^= ((a >> (s - 1 - i)) & 1) * vj[k - i]
        v.append(vj)
    points = []
    x = [0] * d
    points.append([0.0] * d)
    for i in range(1, n):
        # the index of the rightmost zero bit of i - 1 (Gray code step)
        c = 0
        t = i - 1
        while t & 1:
            t >>= 1
            c += 1
        for j in range(d):
            x[j] ^= v[j][c]
        points.append([xj / scale for xj in x])
    return points


def unit_samples(method, n, d, rng):
    """Samples in [0, 1)^d as a list of lists; may be fewer or more than n for
    the structured designs (full factorial, one at a time)."""
    if d == 0:
        return [[]]
    if method == "random":
        return [[rng.random() for _ in range(d)] for _ in range(n)]
    if method == "lhs":
        columns = []
        for _ in range(d):
            strata = list(range(n))
            rng.shuffle(strata)
            columns.append([(k + rng.random()) / n for k in strata])
        return [[columns[j][i] for j in range(d)] for i in range(n)]
    if method == "sobol":
        shift = [rng.random() for _ in range(d)]
        return [[(x + s) % 1.0 for x, s in zip(p, shift)] for p in sobol_points(n, d)]
    if method == "full_factorial":
        levels = max(2, int(math.floor(n ** (1.0 / d) + 1e-9)))
        grid = [k / (levels - 1.0) for k in range(levels)]
        points = [[]]
        for _ in range(d):
            points = [p + [g] for p in points for g in grid]
        return points
    if method == "one_at_a_time":
        k = max(2, (n - 1) // d)
        center = [0.5] * d
        points = [center]
        for j in range(d):
            for level in (i / (k - 1.0) for i in range(k)):
                if abs(level - 0.5) < 1e-12:
                    continue
                p = list(center)
                p[j] = level
                points.append(p)
        return points
    sys.exit("unknown method %s" % method)


def read_cases_csv(path, variables):
    """The designs of a user's table: one list of values per row, in the order
    of `variables`, filled from the middle of the bounds where the table has no
    column, plus a message for every column skipped or variable filled."""
    with open(path, encoding="utf-8-sig") as fh:
        lines = [l.strip() for l in fh if l.strip() and not l.strip().startswith("#")]
    if not lines:
        fail("cases CSV: it is empty; give a header row naming the variables, then one row per case")
    head = lines[0]
    delimiter = "\t" if "\t" in head else "," if "," in head else ";" if ";" in head else None
    if delimiter is None:
        rows = [l.split() for l in lines]
    else:
        rows = [[c.strip() for c in r] for r in csv.reader(lines, delimiter=delimiter)]
        if delimiter == ";":
            # a spreadsheet in a decimal-comma locale exports 0,02;0,12
            rows = [rows[0]] + [[c.replace(",", ".") for c in r] for r in rows[1:]]
    header, body = rows[0], rows[1:]
    names = [v[0] for v in variables]
    known = dict((n.lower(), n) for n in names)
    try:
        [float(c) for c in header]
        fail("cases CSV: the first row must name the columns (%s), not hold numbers" % ", ".join(names))
    except ValueError:
        pass
    columns, skipped = {}, []
    for i, raw in enumerate(header):
        key = raw.strip().strip('"').lower()
        if key.startswith("in:"):
            key = key[3:]
        if key in known:
            if known[key] in columns:
                fail("cases CSV: the column %s appears twice" % known[key])
            columns[known[key]] = i
        elif key in SKIPPED_COLUMNS or key.startswith(("out:", "img:")) or key == "":
            skipped.append(raw or "(unnamed)")
        else:
            fail("cases CSV: unknown column %r; the design variables are %s (Design variables "
                 "lists them), and case, status and coefficient columns are skipped"
                 % (raw, ", ".join(names)))
    if not columns:
        fail("cases CSV: no column names a design variable (%s)" % ", ".join(names))
    if not body:
        fail("cases CSV: a header but no case; add one row per case")
    messages = []
    if skipped:
        messages.append("cases CSV: skipped the columns %s" % ", ".join(skipped))
    missing = [v for v in variables if v[0] not in columns]
    for name, lo, hi in missing:
        messages.append("cases CSV: no %s column; every case holds it at %g, the middle of its bounds"
                        % (name, (lo + hi) / 2.0))
    designs, outside = [], {}
    for case_no, row in enumerate(body, start=1):
        if len(row) != len(header):
            fail("cases CSV: case %d has %d value%s, the header %d columns"
                 % (case_no, len(row), "" if len(row) == 1 else "s", len(header)))
        design = []
        for name, lo, hi in variables:
            if name not in columns:
                design.append((lo + hi) / 2.0)
                continue
            cell = row[columns[name]].strip().strip('"')
            try:
                value = float(cell)
            except ValueError:
                fail("cases CSV: case %d, column %s: %r is not a number" % (case_no, name, cell))
            if not lo <= value <= hi:
                outside.setdefault(name, []).append(case_no)
            design.append(value)
        designs.append(design)
    for name, lo, hi in variables:
        if name in outside:
            messages.append("::warning::cases CSV: %s outside its bounds [%g, %g] in case %s; the "
                            "bounds are where the mesh generator was validated, so those cases may fail"
                            % (name, lo, hi, ", ".join(str(r) for r in outside[name])))
    return designs, messages


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--method", choices=METHODS, default="lhs")
    ap.add_argument("--n-cases", type=int, help="number of cases wanted (all methods but csv)")
    ap.add_argument("--cases-csv", help="the user's table of cases (method csv)")
    ap.add_argument("--seed", type=int, default=4242)
    ap.add_argument("--variables-file", required=True)
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()
    variables = read_variables(args.variables_file)

    if args.method == "csv":
        if not args.cases_csv:
            fail("method csv needs --cases-csv")
        designs, messages = read_cases_csv(args.cases_csv, variables)
        for m in messages:
            print(m if m.startswith("::") else "::notice::" + m)
        write_cases(args, variables, designs)
        return

    if args.n_cases is None or args.n_cases < 1:
        fail("n-cases must be at least 1")
    free = [i for i, (_, lo, hi) in enumerate(variables) if hi > lo]
    d = len(free)
    rng = random.Random(args.seed)
    unit = unit_samples(args.method, args.n_cases, d, rng)

    designs = []
    for point in unit:
        design = []
        for i, (name, lo, hi) in enumerate(variables):
            if i in free:
                u = point[free.index(i)]
                # the upper bound is reachable (1.0 from a grid); samples in [0, 1)
                design.append(lo + min(max(u, 0.0), 1.0) * (hi - lo))
            else:
                design.append(lo)
        designs.append(design)

    # the structured designs decide their own size; say so when it differs
    if len(designs) != args.n_cases:
        if args.method == "full_factorial":
            levels = max(2, int(math.floor(args.n_cases ** (1.0 / d) + 1e-9))) if d else 1
            print("::notice::full_factorial: %d levels per variable over %d free variables = %d cases (%d requested)"
                  % (levels, d, len(designs), args.n_cases))
        elif args.method == "one_at_a_time":
            k = max(2, (args.n_cases - 1) // d) if d else 0
            print("::notice::one_at_a_time: the center plus %d levels for each of %d free variables = %d cases (%d requested)"
                  % (k, d, len(designs), args.n_cases))
        else:
            print("::notice::%s: %d cases (%d requested)" % (args.method, len(designs), args.n_cases))

    write_cases(args, variables, designs)


def write_cases(args, variables, designs):
    out = os.path.abspath(args.out_dir)
    # the cases of two studies must never mix: an evaluator, the collector and
    # Design Explorer take every case_* they find for one study
    if any(name.startswith("case_") for name in (os.listdir(out) if os.path.isdir(out) else [])):
        fail("%s already holds case directories: give a new or empty directory" % out)
    os.makedirs(out, exist_ok=True)
    names = [v[0] for v in variables]
    for j, design in enumerate(designs, start=1):
        case_dir = os.path.join(out, "case_%d" % j)
        os.makedirs(case_dir, exist_ok=True)
        tmp = os.path.join(case_dir, "params.in.tmp")
        with open(tmp, "w") as fh:
            for name, value in zip(names, design):
                fh.write("%.10g %s\n" % (value, name))
        os.rename(tmp, os.path.join(case_dir, "params.in"))
    with open(os.path.join(out, "doe.csv"), "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["case"] + names)
        for j, design in enumerate(designs, start=1):
            writer.writerow(["case_%d" % j] + ["%.10g" % v for v in design])
    env = "N_CASES=%d\nCASES_DIR=%s\nMETHOD=%s\n" % (len(designs), out, args.method)
    with open(os.path.join(out, "doe.env"), "w") as fh:
        fh.write(env)
    sys.stdout.write(env)


if __name__ == "__main__":
    main()
