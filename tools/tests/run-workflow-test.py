#!/usr/bin/env python3
"""End-to-end test runner for the workflows in this repository.

A test is a JSON file of workflow inputs at

    workflows/<name>/tests/<variant>/<test>.json

and launches workflows/<name>/yamls/<variant>.yaml with `pw workflows run -i`.
One row per launch is appended to the CSV next to it:

    workflows/<name>/tests/<variant>/<test>.csv

The lane is picked from the inputs:

    cluster lane   cluster.resource (or resource) names a compute resource. Pass = the run
                   completes and an endpoint named *-<run-slug> is listed. Teardown =
                   `pw endpoints delete`; leftovers are checked over `pw ssh`.
    k8s lane       resource is an object with type "kubernetes" (hybrid *_k8s.yaml; the
                   runner fills in its id and uri from `pw kube ls`) or the inputs carry
                   k8s.cluster (standalone k8s.yaml). Pass = the run is still running when
                   its wait_for_endpoint job completes and an endpoint named *-<run-slug>
                   is listed. Teardown = `pw workflows runs cancel`; leftovers are the run's
                   Kubernetes objects (name contains the run slug) listed with kubectl in
                   k8s.namespace.

Whether the endpoint's URL answers is the workflow's job, not the runner's: every
wait_for_endpoint job ends with a step that probes the URL and deletes the endpoint
(or fails the run, on Kubernetes) when the service does not answer, so a run that
completes has already proven its service healthy.

The optional "_test" object is stripped before launch:

    timeout_s          seconds to wait for the verdict (default 1800)
    warm_marker        path, or list of paths, on the resource: all present -> phase "warm",
                       none -> "cold", some -> "partial" (cluster lane)
    setup              shell snippet run on the resource before launch (idempotent; cluster lane)
    leftover_patterns  process patterns that must not survive teardown (cluster lane;
                       default: ["pw endpoints"]; processes that predate the launch are ignored)
    leftover_commands  {name: shell snippet printing a count} that must all print 0 after
                       teardown (cluster lane; e.g. {"docker": "docker ps -q | wc -l"})
    leftover_kinds     Kubernetes object kinds that must be gone after teardown (k8s lane;
                       default: deployments, services, pods, persistentvolumeclaims, secrets)
    resource           the resource the runner checks (warm marker, leftovers) when the form
                       has no cluster.resource, e.g. librechat general-all's librechat_resource

Failing runs keep their platform record and get their `pw workflows runs errors`
output (plus the namespace events on the k8s lane) saved under
tests/<variant>/logs/<slug>.txt.

Version columns are tree hashes of the content the run fetched from GitHub (the
branch named in the YAML), plus the local commit; the commit gets a "-dirty"
suffix when the local YAML differs from that branch. The k8s lane fetches
nothing (the YAML is read locally and its manifests are inline), so it stamps
the local HEAD and is "-dirty" when the YAML has uncommitted changes.

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
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
POLL_S = 15
FINAL_STATUSES = {"completed", "error", "canceled", "failed"}
COLUMNS = ["date", "phase", "result", "cleanup", "workflow_tree", "submitter_tree",
           "tools_tree", "commit", "fetched", "branch", "user", "run_slug", "duration_s", "error"]
COMPUTE_RESOURCES_RE = re.compile(r"^\s*type:\s*compute-resources\s*$", re.M)
DEFAULTS = {"timeout_s": 1800, "warm_marker": "", "setup": "", "resource": "",
            "leftover_patterns": ["pw endpoints"], "leftover_commands": {},
            "leftover_kinds": ["deployments", "services", "pods", "persistentvolumeclaims", "secrets"]}


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
        resource = self.meta["resource"] or self.lookup("cluster", "resource") or self.lookup("resource")
        k8s_cluster = self.lookup("k8s", "cluster")
        self.k8s = (isinstance(resource, dict) and resource.get("type") == "kubernetes") or bool(k8s_cluster)
        if self.k8s:
            self.cluster = (resource.get("name") if isinstance(resource, dict) else None) or k8s_cluster
            self.namespace = self.lookup("k8s", "namespace") or ""
            self.resource = f"kubernetes cluster {self.cluster}"
            self.scheduler = False
            self.resource_path = None
            self.hydrate = False
            if not self.cluster:
                raise SystemExit(f"{self.id}: kubernetes resource without a name")
        else:
            if isinstance(resource, dict):
                raise SystemExit(f"{self.id}: a resource object must have type \"kubernetes\"")
            self.resource = resource
            self.scheduler = bool(self.lookup("cluster", "scheduler") or self.lookup("scheduler"))
            if not self.resource:
                raise SystemExit(f"{self.id}: no cluster.resource, resource, k8s.cluster or _test.resource input")
            self.resource_path = (("cluster", "resource") if self.lookup("cluster", "resource")
                                  else ("resource",) if self.lookup("resource") else None)
            # The platform hydrates a pw:// string only for compute-clusters inputs; a
            # compute-resources one reaches the workflow raw, so `.ip` is empty and
            # ssh steps run on the workspace. The UI sends the object, so we do too.
            self.hydrate = bool(self.resource_path) and bool(
                COMPUTE_RESOURCES_RE.search(self.yaml.read_text()))

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
        return False, f"unparseable resource {resource!r}", None
    user, name = m.group(1), m.group(2)
    if not resource.startswith("pw://"):
        user = default_user
    r = pw("cluster", "ls", "-o", "json")
    if r.returncode != 0:
        return False, f"pw cluster ls failed: {(r.stderr or r.stdout).strip()[:200]}", None
    for c in parse_json(r.stdout):
        if c.get("name") == name and (user is None or c.get("user") in (user, None)):
            return c.get("status") == "active", f"status {c.get('status')}", c
    return False, "not found in pw cluster ls", None


def kube_cluster(name):
    r = pw("kube", "ls", "-o", "json")
    if r.returncode != 0:
        return None, f"pw kube ls failed: {(r.stderr or r.stdout).strip()[:200]}"
    for c in parse_json(r.stdout):
        if c.get("name") == name:
            return c, "listed"
    return None, "not found in pw kube ls"


def complete_resource(test, cluster):
    # A kubernetes resource is passed to `pw workflows run` as an object; the test
    # carries only what is stable across platforms (name, type) and the rest is
    # filled in from `pw kube ls` here.
    resource = test.inputs.get("resource")
    if isinstance(resource, dict):
        resource.setdefault("name", test.cluster)
        resource.setdefault("id", cluster.get("id"))
        resource.setdefault("uri", f"pw://{test.cluster}")
        resource["type"] = "kubernetes"


def hydrate_compute_resource(test, cluster, default_user):
    if not test.hydrate:
        return
    owner = cluster.get("user") or default_user
    name = cluster.get("name", "")
    obj = {
        "$type": "computeResource",
        "id": cluster.get("id", ""),
        # `pw cluster ls -o json` calls it ipAddress; the resolved object wants ip
        "ip": cluster.get("ipAddress", ""),
        "name": name,
        "namespace": owner,
        "user": owner,
        "provider": cluster.get("type", ""),
        "type": cluster.get("type", ""),
        "schedulerType": cluster.get("schedulerType", ""),
        "uri": f"pw://{owner}/{name}",
    }
    target = test.inputs
    for key in test.resource_path[:-1]:
        target = target.setdefault(key, {})
    target[test.resource_path[-1]] = obj


_kube_ready = {}


def kubectl(test):
    if test.cluster not in _kube_ready:
        ok = bool(shutil.which("kubectl"))
        if not ok:
            log("  kubectl not found; Kubernetes leftovers cannot be checked")
        else:
            r = pw("kube", "auth", "--no-context-switch", test.cluster)
            ok = r.returncode == 0
            if not ok:
                log(f"  pw kube auth {test.cluster} failed: {(r.stderr or r.stdout).strip()[:200]}")
        _kube_ready[test.cluster] = ok
    if not _kube_ready[test.cluster] or not test.namespace:
        return None
    return ["kubectl", "--context", f"pw#{test.cluster}", "-n", test.namespace]


def k8s_leftovers(test, slug):
    k = kubectl(test)
    if not k:
        return None
    r = sh(*k, "get", ",".join(test.meta["leftover_kinds"]), "-o", "name")
    if r.returncode != 0:
        log(f"  kubectl get failed: {(r.stderr or r.stdout).strip()[:200]}")
        return None
    return [l.strip() for l in r.stdout.splitlines() if slug in l]


def k8s_events(test):
    k = kubectl(test)
    if not k:
        return ""
    r = sh(*k, "get", "events", "--sort-by=.lastTimestamp")
    return "\n".join(r.stdout.splitlines()[-40:])


def stamp(test):
    if test.k8s:
        fetched, ref = True, "HEAD"
    else:
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


def view(slug):
    r = pw("workflows", "runs", "view", slug, "-o", "json", timeout=90)
    if r.returncode != 0:
        log(f"  runs view failed: {(r.stderr or r.stdout).strip()[:200]}")
        return None
    try:
        return parse_json(r.stdout)
    except ValueError:
        return {}


def describe(data):
    status = data.get("status", "?")
    jobs = {k: v.get("status") for k, v in data.get("executedJobs", {}).items() if isinstance(v, dict)}
    return status, jobs


def wait(slug, timeout_s):
    deadline, last, data = time.time() + timeout_s, None, {}
    while time.time() < deadline:
        current = view(slug)
        if current is not None:
            data = current
            status, jobs = describe(data)
            if (status, jobs) != last:
                log(f"  run {slug}: {status} {jobs}")
                last = (status, jobs)
            if status in FINAL_STATUSES:
                return status, data
        time.sleep(POLL_S)
    return "timeout", data


def wait_k8s(slug, timeout_s):
    # The k8s run streams pod logs for as long as the service lives, so the verdict
    # comes while the run is still running: "ready" once its wait_for_endpoint job
    # has completed (the workflow found the endpoint and its URL answered). A final
    # status before that means the deployment or the health check failed.
    deadline, last, data = time.time() + timeout_s, None, {}
    while time.time() < deadline:
        current = view(slug)
        if current is not None:
            data = current
            status, jobs = describe(data)
            if (status, jobs) != last:
                log(f"  run {slug}: {status} {jobs}")
                last = (status, jobs)
            if status in FINAL_STATUSES:
                return status, data
            if any("wait_for_endpoint" in k and v == "completed" for k, v in jobs.items()):
                return "ready", data
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


def endpoints(slug):
    names = []
    for line in pw("endpoints", "list", timeout=90).stdout.splitlines():
        names += [t for t in line.split() if t.endswith(f"-{slug}")]
    return names


def errors(slug):
    text = pw("workflows", "runs", "errors", slug, "-o", "text", timeout=90).stdout
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    try:
        summary = lines[lines.index("Failed jobs/steps:") + 1]
    except (ValueError, IndexError):
        summary = lines[0] if lines else "unknown error"
    return summary, text


def preexisting_pids(test):
    # A process that was already running before the launch cannot be the run's
    # leftover, and the user's process list on the login node often holds
    # look-alikes: an editor's remote server matches "code-server", and when
    # the runner itself executes there its command line names the test files
    # (workflows/jupyter/tests/...). Snapshot them and ignore them at teardown.
    r = pw("ssh", test.resource, "ps -u $USER -o pid=", timeout=120)
    return [t for t in r.stdout.split() if t.isdigit()] if r.returncode == 0 else []


def teardown(test, slug, endpoint_name, preexisting):
    # A multi-service workflow (librechat general-all) registers one endpoint per
    # service, every one ending in the run slug: all of them come down.
    for name in endpoints(slug) or ([endpoint_name] if endpoint_name else []):
        r = pw("endpoints", "delete", name, timeout=90)
        log(f"  endpoints delete {name}: rc={r.returncode} {(r.stdout + r.stderr).strip()[:120]}")
    # The checker's own shell is in the user's process list, so nothing in this
    # command may contain a pattern verbatim: keys are indexes and the grep
    # pattern brackets its first character.
    patterns = list(test.meta["leftover_patterns"])
    ps = ("ps -u $USER -o pid=,args= | awk -v skip='" + ",".join(preexisting) +
          "' 'BEGIN {split(skip, a, \",\"); for (i in a) s[a[i]]} !($1 in s)' | cut -d' ' -f2-")
    checks = [f"echo 'p{i}='$({ps} | grep -c -- '[{p[0]}]{p[1:]}')"
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


def teardown_k8s(test, slug):
    # Cancelling the run is the teardown: its cleanup steps delete the Deployment,
    # Secret and PVC, and the endpoint deregisters when the sidecar dies. Deleting
    # the endpoint instead would only make the Deployment restart the sidecar.
    r = pw("workflows", "runs", "cancel", slug, timeout=90)
    log(f"  runs cancel {slug}: rc={r.returncode} {(r.stdout + r.stderr).strip()[:120]}")
    deadline, leftovers, unknown = time.time() + 180, ["unchecked"], False
    while time.time() < deadline:
        data = view(slug) or {}
        status = data.get("status", "?")
        objects = k8s_leftovers(test, slug)
        unknown = objects is None
        leftovers = ([] if status in FINAL_STATUSES else [f"run:{status}"]) + (objects or [])
        if endpoint(slug, attempts=1)[0]:
            leftovers.append("endpoint")
        if not leftovers:
            break
        log(f"  waiting for teardown: {leftovers}")
        time.sleep(15)
    if leftovers:
        return "leftover:" + "+".join(leftovers)
    return "unknown" if unknown else "ok"


def append(csv_path, row):
    # An existing CSV keeps its own header (older files carry the retired `http`
    # column, left empty), so rows always line up with the file they land in.
    columns, new = COLUMNS, not csv_path.exists()
    if not new:
        with open(csv_path, newline="") as f:
            columns = next(csv.reader(f), None) or COLUMNS
    with open(csv_path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        if new:
            writer.writeheader()
        writer.writerow({c: row.get(c, "") for c in columns})


def run_test(test, args, user):
    if test.k8s:
        lane = "k8s"
        cluster, why = kube_cluster(test.cluster)
        active = cluster is not None
    else:
        lane = "compute" if test.scheduler else "login"
        active, why, cluster = resource_active(test.resource, user)
    log(f"=== {test.id} on {test.resource} ({lane} lane)")
    if not active:
        log(f"  SKIP: resource {test.resource} is not active ({why})")
        return None
    if test.k8s:
        complete_resource(test, cluster)
    else:
        hydrate_compute_resource(test, cluster, user)
    row = {c: "" for c in COLUMNS}
    row.update(stamp(test))
    row["user"] = user
    row["phase"] = "" if test.k8s else phase(test)
    row["date"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log(f"  version {row['workflow_tree']} (submitter {row['submitter_tree']}, tools {row['tools_tree']}) "
        f"commit {row['commit']} phase {row['phase'] or 'n/a'}")
    started, slug, endpoint_name, detail, preexisting = time.time(), "", None, "", []
    try:
        if test.k8s:
            if test.meta["setup"] or test.meta["warm_marker"]:
                log("  note: setup and warm_marker need a login node; ignored on the k8s lane")
        else:
            setup(test)
            preexisting = preexisting_pids(test)
        slug = launch(test, f"{test.id} @{row['workflow_tree']}")
        row["run_slug"] = slug
        log(f"  launched run {slug}")
        if test.k8s:
            status, _ = wait_k8s(slug, test.meta["timeout_s"])
            if status == "ready":
                endpoint_name, url = endpoint(slug)
                if not endpoint_name:
                    row["result"], row["error"] = "fail", "wait_for_endpoint completed but no endpoint listed"
                else:
                    row["result"] = "pass"
                    log(f"  endpoint {endpoint_name} {url} (URL checked by the workflow)")
            elif status == "timeout":
                row["result"], row["error"] = "fail", f"wait_for_endpoint not completed after {test.meta['timeout_s']}s"
            else:
                summary, detail = errors(slug)
                row["result"], row["error"] = "fail", f"run {status} before the endpoint came online: {summary}"
        else:
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
                    row["result"] = "pass"
                    log(f"  endpoint {endpoint_name} {url} (URL checked by the workflow)")
            if endpoint_name is None and slug:
                endpoint_name, _ = endpoint(slug, attempts=1)
    except Exception as e:
        row["result"], row["error"] = "fail", str(e).replace("\n", " | ")[:300]
    row["duration_s"] = int(time.time() - started)
    if args.keep:
        row["cleanup"] = "kept"
    elif slug:
        row["cleanup"] = teardown_k8s(test, slug) if test.k8s else teardown(test, slug, endpoint_name, preexisting)
    if row["result"] != "pass" and slug:
        test.logs.mkdir(exist_ok=True)
        text = detail or errors(slug)[1]
        if test.k8s:
            text += "\n\n=== kubectl get events (last 40) ===\n" + k8s_events(test)
        (test.logs / f"{slug}.txt").write_text(text)
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
            if t.k8s:
                cluster, _ = kube_cluster(t.cluster)
                if cluster:
                    complete_resource(t, cluster)
            elif t.hydrate:
                emit_user, _ = context()
                _, _, cluster = resource_active(t.resource, emit_user)
                if cluster:
                    hydrate_compute_resource(t, cluster, emit_user)
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
