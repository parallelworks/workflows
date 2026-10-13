#!/usr/bin/env python3
"""Usage: summarize.py <benchmark> <out-file> <csv-file> <outputs-file>

Reads the raw output of one benchmark run (results/<benchmark>.out), writes its
result tables as one CSV, prints the headline figures as ::notice annotations
and writes them as KEY=value lines to <outputs-file> for the step's $OUTPUTS.
Standard library only, so it runs on any login node's python3.

  imb-pingpong   every "# Benchmarking" table of IMB-MPI1 with its process
  imb-alltoall   count; headline: latency and peak bandwidth (PingPong), the
                 average time at the smallest and largest message of the largest
                 process count (Alltoall)
  ior            the per-iteration "Results:" table; headline: the mean and
                 peak write and read bandwidth of "Summary of all tests"
  mdtest         the "SUMMARY rate" table; headline: the mean file rates

Exits 1 when the output holds no result table: the benchmark ran to its end
but produced nothing to report, which is a failed run.
"""

import csv
import re
import sys

NUMBER = re.compile(r"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$")


def is_number(token):
    return bool(NUMBER.match(token))


def notice(title, message):
    print(f"::notice title={title}::{message}")


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(rows)


def parse_imb(lines):
    """Every result table as (benchmark name, processes, header, rows)."""
    tables, state = [], {"name": None, "procs": None, "header": None, "rows": []}

    def flush():
        if state["header"] and state["rows"]:
            tables.append((state["name"], state["procs"], state["header"], state["rows"]))
        state["header"], state["rows"] = None, []

    for line in lines:
        s = line.strip()
        m = re.match(r"^# Benchmarking (\S+)", s)
        if m:
            flush()
            state["name"] = m.group(1)
            continue
        m = re.match(r"^# #processes = (\d+)", s)
        if m:
            flush()
            state["procs"] = int(m.group(1))
            continue
        if s.startswith("#bytes"):
            flush()
            state["header"] = s.split()
            continue
        if state["header"] is not None:
            tokens = s.split()
            if tokens and len(tokens) == len(state["header"]) and all(is_number(t) for t in tokens):
                state["rows"].append(tokens)
            else:
                flush()
    flush()
    return tables


def summarize_imb(benchmark, lines, csv_path, outputs):
    tables = parse_imb(lines)
    if not tables:
        return False
    columns = [h.lstrip("#") for h in tables[0][2]]
    rows = []
    for name, procs, header, table in tables:
        for row in table:
            rows.append([name, procs] + row)
    write_csv(csv_path, ["benchmark", "processes"] + columns, rows)

    wanted = "pingpong" if benchmark == "imb-pingpong" else "alltoall"
    selected = [t for t in tables if (t[0] or "").lower() == wanted] or tables
    name, procs, header, table = max(selected, key=lambda t: t[1] or 0)
    columns = [h.lstrip("#") for h in header]
    outputs["processes"] = procs
    if wanted == "pingpong" and "t[usec]" in columns and "Mbytes/sec" in columns:
        t_i, bw_i = columns.index("t[usec]"), columns.index("Mbytes/sec")
        first = table[0]
        best = max(table, key=lambda r: float(r[bw_i]))
        outputs["latency_usec"] = first[t_i]
        outputs["latency_bytes"] = first[0]
        outputs["bandwidth_mbytes_per_sec"] = best[bw_i]
        outputs["bandwidth_bytes"] = best[0]
        notice(f"IMB-MPI1 {name}", f"{first[t_i]} usec at {first[0]} bytes, "
               f"{best[bw_i]} Mbytes/sec at {best[0]} bytes ({procs} processes)")
    else:
        t_col = "t_avg[usec]" if "t_avg[usec]" in columns else columns[-1]
        t_i = columns.index(t_col)
        small, large = table[0], table[-1]
        outputs["smallest_bytes"] = small[0]
        outputs["t_avg_usec_smallest"] = small[t_i]
        outputs["largest_bytes"] = large[0]
        outputs["t_avg_usec_largest"] = large[t_i]
        notice(f"IMB-MPI1 {name}", f"{procs} processes: {t_col} {small[t_i]} at {small[0]} bytes, "
               f"{large[t_i]} at {large[0]} bytes")
    return True


def parse_ior(lines):
    """The per-iteration results (header, rows) and the summary (header, rows)."""
    results_header, results, summary_header, summary, section = None, [], None, [], None
    for line in lines:
        s = line.strip()
        if s.startswith("Results:"):
            section = "results"
            continue
        if s.startswith("Summary of all tests:"):
            section = "summary"
            continue
        if s.startswith("Finished"):
            section = None
            continue
        tokens = s.split()
        if not tokens or tokens[0].startswith("---"):
            continue
        if section == "results":
            if tokens[0] == "access":
                results_header = tokens
            elif results_header and tokens[0] in ("write", "read") and len(tokens) == len(results_header):
                results.append(tokens)
        elif section == "summary":
            if tokens[0] == "Operation":
                summary_header = tokens
            elif summary_header and tokens[0] in ("write", "read") and len(tokens) == len(summary_header):
                summary.append(tokens)
    return results_header, results, summary_header, summary


def summarize_ior(lines, csv_path, outputs):
    results_header, results, summary_header, summary = parse_ior(lines)
    if not results:
        return False
    write_csv(csv_path, results_header, results)
    if summary:
        mean_i, max_i = summary_header.index("Mean(MiB)"), summary_header.index("Max(MiB)")
        tasks_i = summary_header.index("#Tasks") if "#Tasks" in summary_header else None
        reps_i = summary_header.index("reps") if "reps" in summary_header else None
        parts = []
        for row in summary:
            op = row[0]
            outputs[f"{op}_mib_per_sec_mean"] = row[mean_i]
            outputs[f"{op}_mib_per_sec_max"] = row[max_i]
            parts.append(f"{op} {row[mean_i]} MiB/s mean (max {row[max_i]})")
        detail = ""
        if tasks_i is not None:
            detail = f" with {summary[0][tasks_i]} tasks"
            if reps_i is not None:
                detail += f", {summary[0][reps_i]} iteration(s)"
        notice("IOR", ", ".join(parts) + detail)
    else:
        # a run stopped before the summary still has its per-iteration rows
        bw_i = results_header.index("bw(MiB/s)")
        parts = [f"{r[0]} {r[bw_i]} MiB/s (iteration {r[-1]})" for r in results]
        notice("IOR", ", ".join(parts))
    return True


def parse_mdtest(lines):
    """The SUMMARY rate table as (iterations, rows of [operation, max, min, mean, stddev])."""
    rows, iterations, in_table = [], None, False
    for line in lines:
        s = line.strip()
        m = re.match(r"^SUMMARY rate:(?: \(of (\d+) iterations?\))?", s)
        if m:
            in_table, iterations = True, m.group(1)
            continue
        if not in_table:
            continue
        if not s or s.startswith("--") or s.startswith("SUMMARY"):
            if rows:
                break
            continue
        tokens = s.split()
        if tokens[0] == "Operation":
            continue
        if len(tokens) >= 5 and all(is_number(t) for t in tokens[-4:]):
            rows.append([" ".join(tokens[:-4])] + tokens[-4:])
    return iterations, rows


def summarize_mdtest(lines, csv_path, outputs):
    iterations, rows = parse_mdtest(lines)
    if not rows:
        return False
    write_csv(csv_path, ["operation", "max_ops_per_sec", "min_ops_per_sec", "mean_ops_per_sec", "stddev"], rows)
    parts = []
    for op, _max, _min, mean, _std in rows:
        key = re.sub(r"[^a-z0-9]+", "_", op.lower()).strip("_")
        outputs[f"{key}_ops_per_sec_mean"] = mean
        if op.startswith("File "):
            parts.append(f"{op[5:]} {float(mean):.0f}/s")
    detail = f" (mean of {iterations} iteration(s))" if iterations else ""
    notice("mdtest", "files: " + ", ".join(parts) + detail)
    return True


def main(argv):
    if len(argv) != 5:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    benchmark, out_path, csv_path, outputs_path = argv[1:]
    with open(out_path) as f:
        lines = f.read().splitlines()
    outputs = {}
    if benchmark in ("imb-pingpong", "imb-alltoall"):
        ok = summarize_imb(benchmark, lines, csv_path, outputs)
    elif benchmark == "ior":
        ok = summarize_ior(lines, csv_path, outputs)
    elif benchmark == "mdtest":
        ok = summarize_mdtest(lines, csv_path, outputs)
    else:
        print(f"::error::unknown benchmark '{benchmark}'")
        return 2
    if not ok:
        print(f"::error::{out_path} holds no result table of {benchmark}; the benchmark produced nothing to report")
        return 1
    with open(outputs_path, "w") as f:
        for key, value in outputs.items():
            f.write(f"{key}={value}\n")
    print(f"Result table: {csv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
