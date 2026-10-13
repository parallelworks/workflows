"""Training metrics from a PhysicsNeMo run's console output (standard library only).

PhysicsNeMo's LaunchLogger prints one line per epoch and namespace,

    [2026-10-09 14:00:00,123][train][INFO] - Epoch 3 Metrics: Learning Rate =  1.000e-03, loss =  7.813e-01
    [2026-10-09 14:00:00,124][train][INFO] - Epoch Execution Time:  1.234e+01s, Time/Iter:  4.567e+01ms

and run-example.sh makes the LDC PINN example print `Iteration <i> Metrics: ...`
lines of the same shape. parse_line() turns either into (namespace, step, {name: value},
wall time); the execution time line belongs to the namespace's last epoch.
"""

import re
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STEP = re.compile(r"\b(?:Epoch|Iteration|Step)\s+(\d+)\s+Metrics:(.*)$")
EXEC_TIME = re.compile(
    r"Epoch Execution Time:\s*([-+0-9.eE]+|nan|inf)s,\s*Time/Iter:\s*([-+0-9.eE]+|nan|inf)ms"
)
# hydra's console format [time][logger][LEVEL] and PythonLogger's file format [time - logger - LEVEL]
NAMESPACE = re.compile(r"\]\[([^\]\[]+)\]\[[A-Z]+\]|\[[\d:,. -]+ - (\S+) - [A-Z]+\]")
STAMP = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
PAIR = re.compile(r"\s*([^=,]+?)\s*=\s*([-+]?(?:[0-9.]+(?:[eE][-+]?\d+)?|nan|inf))\s*(?:,|$)")


class Parser:
    def __init__(self):
        self.last_step = {}

    def parse_line(self, line):
        """Returns (namespace, step, metrics, wall_time) or None."""
        line = ANSI.sub("", line).rstrip("\n")
        m = STEP.search(line)
        timing = None if m else EXEC_TIME.search(line)
        if not m and not timing:
            return None
        ns_match = NAMESPACE.search(line)
        namespace = "train"
        if ns_match:
            namespace = (ns_match.group(1) or ns_match.group(2)).strip()
        wall = time.time()
        stamp = STAMP.search(line)
        if stamp:
            try:
                wall = time.mktime(time.strptime(stamp.group(1), "%Y-%m-%d %H:%M:%S"))
            except ValueError:
                pass
        if m:
            step = int(m.group(1))
            values = {}
            for name, value in PAIR.findall(m.group(2)):
                try:
                    values[name.strip()] = float(value)
                except ValueError:
                    continue
            if not values:
                return None
            self.last_step[namespace] = step
            return namespace, step, values, wall
        if namespace not in self.last_step:
            return None
        values = {
            "Epoch Time (s)": float(timing.group(1)),
            "Time per iter (ms)": float(timing.group(2)),
        }
        return namespace, self.last_step[namespace], values, wall


def parse_file(path):
    """Every metric record in a log file, in order."""
    parser = Parser()
    records = []
    with open(path, errors="replace") as f:
        for line in f:
            record = parser.parse_line(line)
            if record:
                records.append(record)
    return records
