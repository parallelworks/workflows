#!/usr/bin/env python3
"""End-to-end test runner for the workflows in this repository.

A test is a JSON file of workflow inputs at

    workflows/<name>/tests/<variant>/<test>.json

and launches workflows/<name>/yamls/<variant>.yaml with `pw workflows run -i`.
One row per launch is appended to the CSV next to it:

    workflows/<name>/tests/<variant>/<test>.csv

The optional "_test" object is stripped before launch:

    timeout_s          seconds to wait for the run to reach a final status (default 1800)
    http_expect        acceptable HTTP status codes from the endpoint URL (default: 2xx and 3xx)
    warm_marker        path, or list of paths, on the resource: all present -> phase "warm",
                       none -> "cold", some -> "partial"
    setup              shell snippet run on the resource before launch (idempotent; e.g. seed files)
    leftover_patterns  process patterns that must not survive teardown (default: ["pw endpoints"])
    leftover_commands  {name: shell snippet printing a count} that must all print 0 after teardown
                       (e.g. {"docker": "docker ps -q | wc -l"})

Pass = the run completes, an endpoint named *-<run-slug> is listed, and its URL
answers with an accepted status. Cleanup is verified separately after
`pw endpoints delete`: no matching processes for the user, and no queued jobs
when the test schedules. Failing runs keep their platform record and get their
`pw workflows runs errors` output saved under tests/<variant>/logs/<slug>.txt.

Version columns are tree hashes of the content the run fetched from GitHub
(the branch named in the YAML), plus the local commit; the commit gets a
"-dirty" suffix when the local YAML differs from that branch.

Usage:
    python3 tools/tests/run-workflow-test.py workflows/jupyterlab/tests/general/gcp-controller.json [...]
    python3 tools/tests/run-workflow-test.py --emit TEST.json    print the launchable inputs and exit
    python3 tools/tests/run-workflow-test.py --keep TEST.json    leave the endpoint and service running
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
POLL_S = 15
FINAL_STATUSES = {"completed", "error", "canceled", "failed"}
COLUMNS = ["date", "phase", "result", "cleanup", "http", "workflow_tree", "submitter_tree",
           "tools_tree", "commit", "fetched", "branch", "user", "run_slug", "duration_s", "error"]
DEFAULTS = {"timeout_s": 1800, "http_expect": None, "warm_marker": "", "setup": "",
            "leftover_patterns": ["pw endpoints"], "leftover_commands": {}}


def log(msg):
    print(f"{datetime.now(timezone.utc).strftime('%H:%M:%S')} {msg}", flush=True)


def sh(*args, timeout=120):
    return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)


def pw(*args, timeout=120):
    return sh("pw", *args, timeout=timeout)


def git(*args):
    return sh("git", "-C", str(REPO), *args).stdout.strip()


def parse_json(text):
    starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
    end = max(text.rfind("}"), text.rfind("]"))
    if not starts or end < 0:
        raise ValueError(f"no JSON in output: {text[:200]!r}")
    return json.loads(text[min(starts):end + 1])


class Test:
    def __init__(self, path):
        self.path = Path(path).resolve()
        parts = self.path.parts
        if "tests" not in parts:
            raise SystemExit(f"{path}: expected workflows/<name>/tests/<variant>/<test>.json")
        i = len(parts) - 1 - parts[::-1].index("tests")
        if i < 1 or len(parts) != i + 3 or self.path.suffix != ".json":
            raise SystemExit(f"{path}: expected workflows/<name>/tests/<variant>/<test>.json")
        self.workflow, self.variant, self.name = parts[i - 1], parts[i + 1], self.path.stem
        self.id = f"{self.workflow}/{self.variant}/{self.name}"
        self.yaml = REPO / "workflows" / self.workflow / "yamls" / f"{self.variant}.yaml"
        self.csv = self.path.with_suffix(".csv")
        self.logs = self.path.parent / "logs"
        if not self.yaml.exists():
            raise SystemExit(f"{self.id}: no YAML at {self.yaml}")
        data = json.loads(self.path.read_text())
        self.meta = {**DEFAULTS, **data.pop("_test", {})}
        self.inputs = data
        self.resource = self.lookup("cluster", "resource") or self.lookup("resource")
        self.scheduler = bool(self.lookup("cluster", "scheduler") or self.lookup("scheduler"))
        if not self.resource:
            raise SystemExit(f"{self.id}: no cluster.resource or resource input")

    def lookup(self, *keys):
        value = self.inputs
        for key in keys:
            if not isinstance(value, dict) or key not in value:
                return None
            value = value[key]
        return value


def context():
    line = next((l for l in pw("context", "current").stdout.splitlines() if "@" in l), "")
    m = re.match(r"\s*(?:user:)?([^@\s]+)@(\S+)", line)
    return (m.group(1), m.group(2)) if m else ("", "")


def resource_active(resource, default_user):
    m = re.match(r"^(?:pw://)?(?:([^/]+)/)?([^/]+)$", resource)
    if not m:
        return False, f"unparseable resource {resource!r}"
    user, name = m.group(1), m.group(2)
    if not resource.startswith("pw://"):
        user = default_user
    r = pw("cluster", "ls", "-o", "json")
    if r.returncode != 0:
        return False, f"pw cluster ls failed: {(r.stderr or r.stdout).strip()[:200]}"
    for c in parse_json(r.stdout):
        if c.get("name") == name and (user is None or c.get("user") in (user, None)):
            return c.get("status") == "active", f"status {c.get('status')}"
    return False, "not found in pw cluster ls"


def stamp(test):
    m = re.search(r"^\s*branch:\s*['\"]?([\w./-]+)", test.yaml.read_text(), re.M)
    branch = m.group(1) if m else "canary"
    fetched = sh("git", "-C", str(REPO), "fetch", "-q", "origin", branch, timeout=120).returncode == 0
    ref = "FETCH_HEAD" if fetched else "HEAD"
    if not fetched:
        log(f"  warning: git fetch origin {branch} failed; stamping from local HEAD")
    commit = git("rev-parse", "--short", "HEAD")
    if sh("git", "-C", str(REPO), "diff", "--quiet", ref, "--", str(test.yaml)).returncode != 0:
        commit += "-dirty"
    return {
        "workflow_tree": git("rev-parse", "--short", f"{ref}:workflows/{test.workflow}"),
        "submitter_tree": git("rev-parse", "--short", f"{ref}:workflows/script_submitter/v3.6"),
        "tools_tree": git("rev-parse", "--short", f"{ref}:tools"),
        "commit": commit,
        "fetched": git("rev-parse", "--short", ref) + ("" if fetched else "?"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
    }


def phase(test):
    markers = test.meta.get("warm_marker") or []
    if isinstance(markers, str):
        markers = [markers]
    if not markers:
        return ""
    script = "; ".join(f'test -e "{m}" && echo 1 || echo 0' for m in markers)
    found = [w for w in pw("ssh", test.resource, script, timeout=120).stdout.split() if w in ("0", "1")]
    if len(found) != len(markers):
        return "unknown"
    missing = [m for m, f in zip(markers, found) if f == "0"]
    if missing and len(missing) < len(markers):
        log(f"  partial install: missing {missing}")
    return "warm" if not missing else "cold" if len(missing) == len(markers) else "partial"


def setup(test):
    snippet = test.meta.get("setup")
    if not snippet:
        return
    r = pw("ssh", test.resource, snippet, timeout=300)
    if r.returncode != 0:
        raise RuntimeError(f"setup failed: {(r.stderr or r.stdout).strip()[:300]}")
    log("  setup done")


def launch(test, run_name):
    fd, tmp = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(test.inputs, f)
    try:
        r = pw("workflows", "run", str(test.yaml), "-i", tmp, "-o", "json", "--name", run_name, timeout=180)
    finally:
        os.unlink(tmp)
    if r.returncode != 0:
        raise RuntimeError(f"launch failed: {(r.stderr or r.stdout).strip()[:300]}")
    data = parse_json(r.stdout)
    return data.get("run", data)["slug"]


def wait(slug, timeout_s):
    deadline, last, data = time.time() + timeout_s, None, {}
    while time.time() < deadline:
        r = pw("workflows", "runs", "view", slug, "-o", "json", timeout=90)
        if r.returncode == 0:
            try:
                data = parse_json(r.stdout)
            except ValueError:
                data = {}
            status = data.get("status", "?")
            jobs = {k: v.get("status") for k, v in data.get("executedJobs", {}).items() if isinstance(v, dict)}
            if (status, jobs) != last:
                log(f"  run {slug}: {status} {jobs}")
                last = (status, jobs)
            if status in FINAL_STATUSES:
                return status, data
        else:
            log(f"  runs view failed: {(r.stderr or r.stdout).strip()[:200]}")
        time.sleep(POLL_S)
    return "timeout", data


def endpoint(slug, attempts=6):
    for attempt in range(attempts):
        for line in pw("endpoints", "list", timeout=90).stdout.splitlines():
            tokens = line.split()
            name = next((t for t in tokens if t.endswith(f"-{slug}")), None)
            if name:
                return name, next((t for t in tokens if t.startswith("http")), "")
        if attempt + 1 < attempts:
            time.sleep(5)
    return None, ""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http_status(url):
    if not url:
        return 0
    try:
        with urllib.request.build_opener(NoRedirect).open(url, timeout=30) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        log(f"  http error: {e}")
        return 0


def errors(slug):
    text = pw("workflows", "runs", "errors", slug, "-o", "text", timeout=90).stdout
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    try:
        summary = lines[lines.index("Failed jobs/steps:") + 1]
    except (ValueError, IndexError):
        summary = lines[0] if lines else "unknown error"
    return summary, text


def teardown(test, slug, endpoint_name):
    if endpoint_name:
        r = pw("endpoints", "delete", endpoint_name, timeout=90)
        log(f"  endpoints delete {endpoint_name}: rc={r.returncode} {(r.stdout + r.stderr).strip()[:120]}")
    # The checker's own shell is in the user's process list, so nothing in this
    # command may contain a pattern verbatim: keys are indexes and the grep
    # pattern brackets its first character.
    patterns = list(test.meta["leftover_patterns"])
    checks = [f"echo 'p{i}='$(ps -u $USER -o args= | grep -c -- '[{p[0]}]{p[1:]}')"
              for i, p in enumerate(patterns)]
    commands = dict(test.meta["leftover_commands"])
    checks += [f"echo 'c{i}='$({snippet})" for i, snippet in enumerate(commands.values())]
    if test.scheduler:
        checks.append("echo 'squeue='$(squeue -h -u $USER | wc -l)")
    command = "; ".join(checks)
    names = {f"p{i}": f"proc:{p}" for i, p in enumerate(patterns)}
    names.update({f"c{i}": name for i, name in enumerate(commands)})
    deadline, leftovers = time.time() + 180, ["unchecked"]
    while time.time() < deadline:
        r = pw("ssh", test.resource, command, timeout=120)
        if r.returncode != 0:
            log(f"  cleanup check failed: {(r.stderr or r.stdout).strip()[:200]}")
            return "unknown"
        counts = dict(re.findall(r"^(\S+)=(\d+)\s*$", r.stdout, re.M))
        leftovers = [names.get(k, k) for k, c in counts.items() if int(c) > 0] or (["unchecked"] if not counts else [])
        if not leftovers:
            break
        log(f"  waiting for cleanup: {leftovers}")
        time.sleep(15)
    if endpoint(slug, attempts=1)[0]:
        leftovers.append("endpoint")
    return "ok" if not leftovers else "leftover:" + "+".join(leftovers)


def append(csv_path, row):
    new = not csv_path.exists()
    with open(csv_path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        if new:
            writer.writeheader()
        writer.writerow(row)


def run_test(test, args, user):
    lane = "compute" if test.scheduler else "login"
    log(f"=== {test.id} on {test.resource} ({lane} lane)")
    active, why = resource_active(test.resource, user)
    if not active:
        log(f"  SKIP: resource {test.resource} is not active ({why})")
        return None
    row = {c: "" for c in COLUMNS}
    row.update(stamp(test))
    row["user"] = user
    row["phase"] = phase(test)
    row["date"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log(f"  version {row['workflow_tree']} (submitter {row['submitter_tree']}, tools {row['tools_tree']}) "
        f"commit {row['commit']} phase {row['phase'] or 'n/a'}")
    started, slug, endpoint_name, detail = time.time(), "", None, ""
    try:
        setup(test)
        slug = launch(test, f"{test.id} @{row['workflow_tree']}")
        row["run_slug"] = slug
        log(f"  launched run {slug}")
        status, _ = wait(slug, test.meta["timeout_s"])
        if status == "timeout":
            pw("workflows", "runs", "cancel", slug)
            row["result"], row["error"] = "fail", f"timeout after {test.meta['timeout_s']}s; run canceled"
        elif status != "completed":
            summary, detail = errors(slug)
            row["result"], row["error"] = "fail", f"run {status}: {summary}"
        else:
            endpoint_name, url = endpoint(slug)
            if not endpoint_name:
                row["result"], row["error"] = "fail", "run completed but no endpoint listed"
            else:
                code = http_status(url)
                row["http"] = code
                expect = test.meta["http_expect"]
                ok = code in expect if expect else 200 <= code < 400
                row["result"] = "pass" if ok else "fail"
                if not ok:
                    row["error"] = f"http {code} from {url}"
                log(f"  endpoint {endpoint_name} {url} -> http {code}")
        if endpoint_name is None and slug:
            endpoint_name, _ = endpoint(slug, attempts=1)
    except Exception as e:
        row["result"], row["error"] = "fail", str(e).replace("\n", " | ")[:300]
    row["duration_s"] = int(time.time() - started)
    if args.keep:
        row["cleanup"] = "kept"
    elif slug:
        row["cleanup"] = teardown(test, slug, endpoint_name)
    if row["result"] != "pass" and slug:
        test.logs.mkdir(exist_ok=True)
        (test.logs / f"{slug}.txt").write_text(detail or errors(slug)[1])
    append(test.csv, row)
    log(f"  {row['result'].upper()} cleanup={row['cleanup']} {row['error']}")
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="+", help="test JSON file(s); run sequentially")
    ap.add_argument("--emit", action="store_true", help="print the launchable inputs JSON and exit")
    ap.add_argument("--keep", action="store_true", help="leave the endpoint and service running")
    ap.add_argument("--timeout", type=int, help="override _test.timeout_s for every test")
    args = ap.parse_args()
    tests = [Test(p) for p in args.tests]
    if args.emit:
        for t in tests:
            print(f"# pw workflows run {t.yaml} -i <this>", file=sys.stderr)
            print(json.dumps(t.inputs, indent=2))
        return 0
    user, host = context()
    if not user:
        raise SystemExit("pw context current returned no user; run `pw auth` first")
    log(f"platform {host} as {user}; repo {REPO}")
    rows = []
    for t in tests:
        if args.timeout:
            t.meta["timeout_s"] = args.timeout
        rows.append((t, run_test(t, args, user)))
    print("\nSUMMARY", flush=True)
    for t, r in rows:
        if r is None:
            print(f"  skip                    {t.id}", flush=True)
        else:
            print(f"  {r['result']:4s} cleanup={r['cleanup']:<12s} {t.id}  {r['run_slug']}  {r['error']}", flush=True)
    ok = all(r and r["result"] == "pass" and r["cleanup"] in ("ok", "kept") for _, r in rows)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
