#!/usr/bin/env python3
"""Dakota fork-interface analysis driver: replay-or-capture.

Invoked by Dakota as `driver.py <params_file> <results_file>` for every evaluation
it wants. Two paths:

  replay:  the point was already evaluated by the platform -> its objectives are in
           $DAK_RESULTS_DB/<hash> -> write them to the Dakota results file and exit
           (a "FAIL" entry is passed through for Dakota's failure_capture recovery)
  capture: the point is new -> claim the next case slot under $DAK_CAPTURE_DIR,
           write params.in / param.hash there, then BLOCK forever; the optimizer
           wrapper counts the blocked captures and kills Dakota's process group
           once the batch is stable, so the platform can evaluate the cases

The driver knows nothing about the evaluator: params.in (one "<value> <name>"
line per variable) is the whole hand-off, and the evaluator leaves results.out
(one "<value> <label>" line per objective) next to it. The param hash is the
replay key: it must be computed identically here (from the values Dakota prints)
and formatted from nothing else, so a re-requested point on the next Dakota
resume finds the objectives the evaluator produced.
"""

import hashlib
import os
import sys
import time


def read_params(path):
    """Parse Dakota's standard-format params file: line 1 is '<n> variables',
    followed by one '<value> <descriptor>' line per variable."""
    with open(path) as fh:
        lines = fh.readlines()
    n = int(lines[0].split()[0])
    return [(line.split()[1], float(line.split()[0])) for line in lines[1:1 + n]]


def param_hash(pairs):
    canon = " ".join("%s=%.12e" % (name, val) for name, val in sorted(pairs))
    return hashlib.sha1(canon.encode()).hexdigest()


def write_atomic(path, content):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as fh:
        fh.write(content)
    os.rename(tmp, path)


def claim_case(iter_dir):
    j = 1
    while True:
        case_dir = os.path.join(iter_dir, "case_%d" % j)
        try:
            os.makedirs(case_dir)
            return case_dir
        except FileExistsError:
            j += 1


def main():
    params_file, results_file = sys.argv[1], sys.argv[2]
    capture_dir = os.environ["DAK_CAPTURE_DIR"]
    results_db = os.environ["DAK_RESULTS_DB"]

    pairs = read_params(params_file)
    key = param_hash(pairs)

    db_entry = os.path.join(results_db, key)
    if os.path.exists(db_entry):
        with open(db_entry) as fh:
            content = fh.read().strip()
        if content == "FAIL":
            write_atomic(results_file, "FAIL\n")
        else:
            write_atomic(results_file, content + "\n")
        return

    case_dir = claim_case(capture_dir)
    write_atomic(os.path.join(case_dir, "params.in"),
                 "".join("%.12e %s\n" % (val, name) for name, val in pairs))
    write_atomic(os.path.join(case_dir, "param.hash"), key + "\n")

    # Dakota moves fork drivers into their own process group, so the optimizer's
    # killpg on Dakota's group cannot reach this process: watch the parent instead
    # and exit once Dakota is gone (the capture files above are already on disk).
    parent = os.getppid()
    while os.getppid() == parent:
        time.sleep(2)


if __name__ == "__main__":
    main()
