# Multi-site client-server deployment pattern

A reusable ACTIVATE workflow for deploying a service on one cluster and
attaching workers on other clusters to it. It is a pattern template, not
an application: the deployment mechanics are the deliverable, and the
server/worker in `app/` are minimal placeholders you replace with your
own service.

The mechanics it demonstrates:

- a service exposed to the browser through an endpoint session
- workers dispatched to other clusters over `pw ssh`
- cross-site connectivity through SSH tunnels, with a WebSocket-upgrade
  probe that detects and recreates a stale tunnel
- workers on scheduled resources (SLURM/PBS), with the tunnel on the
  submit node and a supervised, streamed connect
- cross-namespace resource addressing (`pw://owner/name` URIs), so the
  server and worker clusters can be owned by, or shared from, different
  users

The placeholder server and worker are small stdlib-only Python scripts,
so the workflow runs on any cluster with `python3` and the pw CLI; the
worker sites receive the code from the server host and need no GitHub
access.

## Topology

```
 browser ── https://<subdomain>.<platform-domain>
    │
    ▼
 pw endpoint (apptest)
    │
    ▼
 server host (cluster A)                     worker site (cluster B)
 ┌────────────────────────────┐              ┌───────────────────────────────┐
 │ pw endpoints run: server.py│   SSH tunnel │ login / submit node           │
 │  127.0.0.1:8090 /health    │◄─────────────│  tunnel bound to the node's   │
 │  /workers /register /ws    │  (platform   │  cluster-internal IP          │
 │        ▲                   │   proxy)     │   ├─ worker.py (login-node    │
 │        │ localhost         │              │   │  worker, no scheduler)    │
 │  worker.py (worker on the  │              │   └─ batch job (SLURM / PBS)  │
 │  server host, no tunnel)   │              │      └─ compute node          │
 └────────────────────────────┘              │         worker.py ──► http:// │
                                             │         <submit-node-ip>:8090 │
                                             │         over the cluster      │
                                             │         fabric — no pw CLI,   │
                                             │         no outbound network   │
                                             └───────────────────────────────┘
```

Each worker registers over HTTP, then holds a WebSocket open through
the same path; `/workers` shows `connected: true/false` per worker.
Tunnels prefer plain ssh via the platform proxy command and are probed
for WebSocket upgrades before they are trusted.

## Publishing

The workflow is published as the marketplace item `app-testbed`:

```bash
pw marketplace publish --name "Multi-site App Testbed" --slug app-testbed \
    --repo https://github.com/parallelworks/workflows --branch canary \
    --workflow-yaml workflows/app-testbed/yamls/general.yaml \
    --thumbnail workflows/app-testbed/thumbnails/app-testbed.png \
    --readme workflows/app-testbed/README.md
```

Users add it to their account with `pw marketplace add-to-account
app-testbed`, which creates a workflow reference named after the added
version (e.g. `marketplace.app-testbed.v1.0`).
`scripts/launch-worker.py` targets that reference by default; pass
`--workflow /abs/path/workflows/app-testbed/yamls/general.yaml` to run
the local file without publishing.

## Manual launch from a static inputs file

`scripts/worker-inputs.json` is a template inputs file for running the
testbed with the pw CLI alone. Fill in the `resource` blocks for your
clusters (or regenerate the file with
`scripts/launch-worker.py --server-host <cluster> --site <cluster> --print-inputs`),
then:

```bash
scripts/run-worker.sh                # uses scripts/worker-inputs.json
scripts/run-worker.sh my-inputs.json # or an explicit file
```

The script submits the run, follows it to completion, and prints the
dispatch log; it refuses to launch while the template placeholders are
still present.

## Programmatic launch

`scripts/launch-worker.py` submits a run through the pw CLI and follows it to
completion, so the testbed can be driven from scripts or CI:

```bash
# server plus one worker on another cluster
scripts/launch-worker.py --server-host clusterA --site clusterB

# workers on two sites, submitted as SLURM batch jobs
scripts/launch-worker.py --server-host clusterA --site clusterB --site clusterC \
    --scheduler --partition debug --walltime 00:30:00

# verify a pw CLI release passes websocket upgrades through pw forward:
# exit code 0 means workers connected through the tunnel
scripts/launch-worker.py --server-host clusterA --site clusterB \
    --tunnel-method pw-forward
```

The script resolves cluster names (or `pw://owner/name` URIs) to full
resource objects via `pw cluster ls -o json`, submits with
`pw workflows run`, and streams the run log — including the dispatch
step's live queue states and worker-connect confirmations. Exit code 0
means the run completed. `--no-deploy-server` runs workers-only against
a live server, `--no-wait` finishes the run at submission instead of
blocking until workers connect (keep the default blocking behavior for
tunnel verification runs), `--dry-run` validates inputs without executing,
`--print-inputs` shows the generated JSON, and `--no-watch` returns
immediately after submission. Everything printed is also written to
`launch-worker.log` in the current directory (`--log` changes the path,
`--log ''` disables it). On PBS sites `--partition` maps to the queue
and `--pbs-directives` replaces the generated `#PBS` lines entirely.
Requires an authenticated pw CLI.

## Adapting to your application

The application code lives in `app/` as ordinary Python files —
`app/server.py` and `app/worker.py` — checked out onto the server host
at run time and shipped from there to the worker sites. Replace the app
and nothing else:

1. Edit `app/server.py` so it starts your service on
   `127.0.0.1:<port>` (expose an HTTP health path and, if your workers
   hold a long-lived connection, a WebSocket path), and `app/worker.py`
   with your worker client — keep a `WebSocket Connected` line printed
   on success, or adjust the markers `app/worker-bootstrap.sh` greps for.
2. Push: the run checks out `app/` from this repository's `canary` branch.

The endpoint session, tunnels, dispatch loop, scheduler submission,
queue watch, and supervised restart are the pattern and stay as-is.

The wiring between them is the topology shown above; the
register-then-connect shape mirrors real agent systems, so tunnel or
scheduler problems reproduce here with the same symptoms.

## Inputs

- **Server host** - cluster for the server and its endpoint session.
- **Services** - `Deploy server` (off = workers-only run against a live
  server) and `Restart server if already running`.
- **Settings** - workdir, session subdomain, server port, and
  **Tunnel method** (`auto` | `ssh` | `pw-forward`):
  - `auto`: plain ssh via the platform proxy command when `~/.ssh/pwcli`
    exists, otherwise `pw forward`.
  - `ssh`: always plain ssh.
  - `pw-forward`: always `pw forward`. Use this to verify whether a pw
    CLI release passes WebSocket upgrades: the dispatch probes the
    upgrade path before trusting a tunnel and the run fails if upgrades
    do not traverse, so a green run with this setting is a positive
    verification.
- **Worker sites** - a list; one worker per entry. Each entry has an
  optional name (blank = `worker-<hostname>`), a working directory, and
  a **Submit via scheduler?** toggle with per-scheduler directive
  groups shown based on the resource's scheduler type: partition,
  account and QoS pickers, CPUs per task, walltime, and an additional
  `#SBATCH` directives editor for SLURM; an account string (`-A`)
  and a free-form directives editor for PBS, whose `#PBS` lines are
  embedded verbatim in the batch script (default: debug queue, short
  walltime).

## How workers connect

- On the **server host**: directly via localhost, no tunnel.
- On a **remote site (login node)**: the dispatch opens a persistent SSH
  tunnel from the site to the server host, probes both HTTP and the
  WebSocket upgrade path through it (recreating the tunnel if the
  upgrade probe times out), then starts the worker. The worker is
  restarted up to 3 times until its `WebSocket Connected` line appears.
- On a **scheduled resource**: the tunnel terminates on the submit/login
  node, bound to its cluster-internal IP, and the batch job connects to
  `http://<submit-node-ip>:<port>` over the cluster fabric. Compute
  nodes need no pw CLI and no outbound network access. The job runs the
  worker in the foreground (the allocation lives as long as the worker)
  and restarts it up to 5 times until it connects. The dispatch step
  polls the queue and the job log, streaming state transitions
  (`PENDING` -> `RUNNING` -> connected) into the run log, and fails the
  run if the worker never connects.

Re-runs are idempotent: a running server or worker is detected and left
alone, and a queued or running worker batch job is not resubmitted
(canceled jobs in transient states such as SLURM `CG` do not block).

## Cleaning up

- **Server**: delete the endpoint session (UI, or `pw endpoints delete
  apptest`); `pw endpoints run` takes the server down with it and the
  workers exit on their own within ~30s when the websocket drops.
- **Login-node worker**: `pw ssh <site-uri> 'pkill -f app-testbed-worker'`.
  Plain SIGTERM makes the worker unregister itself, so it disappears from
  the topology page immediately.
- **Scheduled worker**: cancel the batch job — `scancel <jobid>` /
  `qdel <jobid>` on the site (the job id is in the dispatch log). The
  worker runs in the job's foreground, so the allocation ends with it.
- **Registry**: entries whose worker vanished without a clean stop show
  grey (offline) and are pruned automatically after an hour; restarting
  the server (`Restart server if already running`, or `--restart` on the
  launcher) clears the registry immediately.

## Verifying a pw CLI tunnel fix

1. Set **Tunnel method** to `pw-forward`.
2. Add a remote worker site (optionally with the scheduler enabled).
3. Run. The dispatch fails with "tunnel fails the websocket probe" or
   "server unreachable (or WS blocked)" if upgrades do not pass; a run
   that ends with `worker connected` confirms the tunnel carries
   WebSocket traffic end to end.

## Files on the hosts

- Server host workdir: `server.py`, `server.log`, `endpoint.log`.
- Worker site workdir: `worker.py`, `worker.log` (login-node workers),
  `worker-job.sh`, `worker-job.log` and `worker-run.log` (scheduled
  workers), `tunnel.log`.

## Provenance

Moved from `parallelworks/activate-app-testbed` (`main` @ `9100bf7`): the
Python once embedded in `workflow.yaml` is checked out from `app/`, the
server runs behind one `pw endpoints run` instead of a bare process plus
`pw endpoints http` and a watcher, and the repository's `wait_for_endpoint`
probes the URL. End-to-end tests are under `tests/general/`; details and
results in `MIGRATION.md`.
