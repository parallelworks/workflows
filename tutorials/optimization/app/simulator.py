#!/usr/bin/env python3
"""Simulator placeholder: evaluate one case in the current directory.

Reads ./params.in (one "<value> <name>" line per variable), computes the ZDT1
benchmark, sleeps a few seconds to imitate solver time, and writes ./results.out
(one "<value> <label>" objective per line). The write is atomic so the optimizer
never ingests a half-written file; on any error the process exits non-zero and
leaves no results.out, which is the failure signal.

Swapping in a real solver means replacing this file with a driver that builds the
case from params.in, runs the solver, and extracts the objectives into results.out
— the two-file contract is all the optimizer sees (see the README's last section).
"""

import math
import os
import sys
import time


def main():
    xs = []
    with open("params.in") as fh:
        for line in fh:
            tok = line.split()
            if tok:
                xs.append(float(tok[0]))
    if len(xs) < 2:
        sys.exit("params.in has fewer than 2 variables")

    # ZDT1: minimize both; the analytic Pareto front is f2 = 1 - sqrt(f1) at g = 1
    f1 = xs[0]
    g = 1.0 + 9.0 * sum(xs[1:]) / (len(xs) - 1)
    f2 = g * (1.0 - math.sqrt(f1 / g))

    time.sleep(float(os.environ.get("SIM_SLEEP_S", "3")))

    with open("results.out.tmp", "w") as fh:
        fh.write("%.10f f1\n%.10f f2\n" % (f1, f2))
    os.rename("results.out.tmp", "results.out")


if __name__ == "__main__":
    main()
