# Multi-site client-server deployment pattern (App Testbed)

A reusable ACTIVATE workflow for deploying a service on one cluster and
attaching workers on other clusters to it. It is a pattern template, not
an application: the deployment mechanics are the deliverable, and the
server/worker in `app/` are minimal placeholders you replace with your
own service.

![Thumbnail](thumbnails/app-testbed.png)

The mechanics it demonstrates:

- a service exposed to the browser through a **`pw` endpoint** at a fixed
  address (`https://apptest.<sessions-domain>/` by default)
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
worker sites need no GitHub access (they receive the code from the server
host).

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
 │ pw endpoints run           │              │ login / submit node           │
 │  └─ server.py 127.0.0.1:8090   SSH tunnel │  tunnel bound to the node's   │
 │     /health /workers       │◄─────────────│  cluster-internal IP          │
 │     /register /ws          │  (platform   │   ├─ worker.py (login-node    │
 │        ▲                   │   proxy)     │   │  worker, no scheduler)    │
 │        │ localhost         │              │   └─ batch job (SLURM / PBS)  │
 │  worker.py (worker on the  │              │      └─ compute node          │
 │  server host, no tunnel)   │              │         worker.py ──► http:// │
 └────────────────────────────┘              │         <submit-node-ip>:8090 │
                                             │         over the cluster      │
                                             │         fabric — no pw CLI,   │
                                             │         no outbound network   │
                                             └───────────────────────────────┘
```

Each worker registers over HTTP, then holds a WebSocket open through
the same path; `/workers` shows `connected: true/false` per worker and
`/` draws the live topology. Tunnels prefer plain ssh via the platform
proxy command and are probed for WebSocket upgrades before they are
trusted.

## How a run works

All jobs run on the server host's login node; the worker sites are reached
from it over `pw ssh`.

```
  preprocessing ── start_server ──┬── wait_for_endpoint
                                  └── dispatch_workers
```

1. **preprocessing** checks out `workflows/app-testbed/app` from this
   repository, writes `inputs.sh` and `workers.json` from the form, and runs
   `controller.sh` (prerequisites, the server working directory).
2. **start_server** (`start-server.sh`) starts the server behind
   `pw endpoints run --port <port> --subdomain <subdomain> --name <subdomain>`,
   **detached** from the run, and checks `/health` and the WebSocket upgrade
   locally. The endpoint is named after its subdomain, so the address is the
   same every run. A server that is already running behind its endpoint is left
   alone; **Restart server if already running** replaces it; a half-instance
   (a server without its endpoint, or a listing whose process tree is gone) is
   replaced. With **Deploy server** off nothing is started or checked.
3. **wait_for_endpoint** calls the repository's
   [`wait_for_endpoint`](../wait_for_endpoint/) subworkflow, which waits until
   the endpoint is listed and probes its URL with the run's key until the server
   answers, then publishes the URL as the `URL` output and a notice. Skipped
   when **Deploy server** is off.
4. **dispatch_workers** (`dispatch_workers.sh`) starts one worker per entry in
   **Worker sites**, in parallel with the health check.

The run **completes** once the endpoint answered and every worker was dispatched
(and connected, with **Wait for workers to connect** on). The server keeps
serving: `pw endpoints run` owns its process tree, so **deleting the endpoint**
(the Sessions page, or `pw endpoints delete apptest`) stops the server, and the
workers exit on their own within ~30 s when their websocket drops.

## Inputs

- **Server host** - cluster for the server and its endpoint.
- **Services** - `Deploy server` (off = workers-only run against a live
  server) and `Restart server if already running`.
- **Settings** - workdir, session subdomain (also the endpoint's name),
  server port, **Wait for workers to connect**, and
  **Tunnel method** (`auto` | `ssh` | `pw-forward`):
  - `auto`: plain ssh via the platform proxy command when `~/.ssh/pwcli`
    exists on the site, otherwise `pw forward`.
  - `ssh`: always plain ssh.
  - `pw-forward`: always `pw forward`. Use this to verify whether a pw
    CLI release passes WebSocket upgrades: the dispatch probes the
    upgrade path before trusting a tunnel and the run fails if upgrades
    do not traverse, so a green run with this setting is a positive
    verification.
- **Worker sites** - a list; one worker per entry. Each entry has an
  optional name (blank = `worker-<user>-<hostname>`), a working directory, and
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
  A site without the platform SSH key adopts the server host's over
  `pw ssh`; a cloud cluster's login node has none, so with the server on
  one the site uses `pw forward` under `auto`.
- On a **scheduled resource**: the tunnel terminates on the submit/login
  node, bound to its cluster-internal IP, and the batch job connects to
  `http://<submit-node-ip>:<port>` over the cluster fabric. Compute
  nodes need no pw CLI and no outbound network access. The job runs the
  worker in the foreground (the allocation lives as long as the worker)
  and restarts it up to 5 times until it connects. The dispatch step
  polls the queue and the job log, streaming state transitions
  (`PENDING` -> `RUNNING` -> connected) into the run log, and fails the
  run if the worker never connects. The placeholder server binds loopback
  only, so a scheduled worker on the **server host's own cluster** cannot
  reach it from a compute node and the dispatch reports that; a real server
  that binds every interface can take same-cluster scheduled workers.

Re-runs are idempotent: a running server or worker is detected and left
alone, and a queued or running worker batch job is not resubmitted
(canceled jobs in transient states such as SLURM `CG` do not block).

## Cleaning up

- **Server**: `pw endpoints delete apptest` (or delete the session in the UI)
  stops the endpoint wrapper and the server; connected workers drop within ~30 s.
- **Login-node worker**: `pw ssh <site-uri> 'pkill -f app-testbed-worker'`.
  Plain SIGTERM makes the worker unregister itself, so it disappears from
  the topology page immediately.
- **Scheduled worker**: cancel the batch job — `scancel <jobid>` /
  `qdel <jobid>` on the site (the job id is in the dispatch log). The
  worker runs in the job's foreground, so the allocation ends with it.
- **Tunnels** are persistent by design (a re-run reuses them):
  `pkill -f '<port>:localhost:<port>'` on the site removes one.
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

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/app-testbed/yamls/general.yaml" -i '{
  "server": {"resource": "pw://<user>/<cluster-a>"},
  "services": {"deploy_server": true, "restart_server": false},
  "app": {"workdir": "~/app-testbed", "subdomain": "apptest", "server_port": 8090,
          "tunnel_method": "auto", "wait_for_workers": true},
  "workers": [{"resource": "pw://<user>/<cluster-b>", "worker_name": "", "workdir": "~/app-testbed-worker",
               "scheduler": false, "slurm": {}, "pbs": {}}]
}'
pw endpoints list                # apptest and its URL
pw endpoints delete apptest      # stops the server
```

### Launcher scripts

[`scripts/launch-worker.py`](scripts/launch-worker.py) resolves cluster names
or `pw://owner/name` URIs to full resource objects via `pw cluster ls -o json`,
builds the inputs, submits the run and follows it until the workers connect,
so the testbed can be driven from scripts or CI:

```bash
# server plus one worker on another cluster
scripts/launch-worker.py --server-host clusterA --site clusterB

# workers on two sites, submitted as SLURM batch jobs
scripts/launch-worker.py --server-host clusterA --site clusterB --site clusterC \
    --scheduler --partition debug --walltime 00:30:00

# verify a pw CLI release passes websocket upgrades through pw forward:
# exit code 0 means workers connected through the tunnel
scripts/launch-worker.py --server-host clusterA --site clusterB --tunnel-method pw-forward
```

It targets the marketplace reference `marketplace.app-testbed.v1.0` by default
(add the item to your account once with `pw marketplace add-to-account app-testbed`);
`--workflow /abs/path/workflows/app-testbed/yamls/general.yaml` runs this file
instead. Exit code 0 means the run completed. `--no-deploy-server` runs
workers-only against a live server, `--no-wait` finishes the run at submission
instead of blocking until workers connect (keep the default blocking behavior
for tunnel verification runs), `--dry-run` validates inputs without executing,
`--print-inputs` shows the generated JSON, and `--no-watch` returns immediately
after submission. Everything printed is also written to `launch-worker.log` in
the current directory (`--log` changes the path, `--log ''` disables it). On PBS
sites `--partition` maps to the queue and `--pbs-directives` replaces the
generated `#PBS` lines entirely. Requires an authenticated pw CLI.

[`scripts/run-worker.sh`](scripts/run-worker.sh) is the pw-CLI-only path: it
submits [`scripts/worker-inputs.json`](scripts/worker-inputs.json) (or the file
given as its first argument), follows the run to completion and prints the
dispatch log. Fill in the `resource` blocks for your clusters first, or
regenerate the file:

```bash
scripts/launch-worker.py --server-host <cluster> --site <cluster> --print-inputs > scripts/worker-inputs.json
scripts/run-worker.sh
```

It refuses to launch while the template placeholders are still present.

## Adapting to your application

The application code lives in `app/` as ordinary Python files,
`app/server.py` and `app/worker.py`, checked out onto the server host at run
time and shipped from there to the worker sites. Replace the app and nothing
else:

1. Edit `app/server.py` so it starts your service on `127.0.0.1:<port>`
   (expose an HTTP health path and, if your workers hold a long-lived
   connection, a WebSocket path), and `app/worker.py` with your worker
   client. Keep a `WebSocket Connected` line printed on success, or adjust
   the markers `app/worker-bootstrap.sh` greps for.
2. Push: the run fetches `app/` from this repository's `canary` branch.

The endpoint, tunnels, dispatch loop, scheduler submission, queue watch and
supervised restart are the pattern and stay as-is. The register-then-connect
shape mirrors real agent systems, so tunnel or scheduler problems reproduce
here with the same symptoms.

## Files

```
workflows/app-testbed/
├── yamls/general.yaml         # The form and the four jobs; one YAML for every platform
├── app/                       # The only subtree a run checks out
│   ├── controller.sh          # Server host: prerequisites, working directory
│   ├── start-server.sh        # The server behind pw endpoints run, detached; idempotent, restart
│   ├── dispatch_workers.sh    # One worker per site over pw ssh; queue watch for scheduled ones
│   ├── worker-bootstrap.sh    # Runs on each site: tunnel, probes, worker or batch job
│   ├── server.py              # Placeholder server: /health, /workers, /register, /ws, topology page
│   └── worker.py              # Placeholder worker: register, hold a WebSocket, unregister on SIGTERM
├── scripts/
│   ├── launch-worker.py       # Programmatic launch through the pw CLI
│   ├── run-worker.sh          # pw-CLI-only launch from a static inputs file
│   └── worker-inputs.json     # Template inputs for run-worker.sh
├── tests/general/             # End-to-end tests (tools/tests/README.md)
├── thumbnails/app-testbed.png
└── README.md
```

On the hosts: the server host's workdir holds `server.py`, `server.log` and
`endpoint.log` (the `pw endpoints run` output); a worker site's workdir holds
`worker.py`, `worker.log` (login-node workers), `worker-job.sh`, `worker-job.log`
and `worker-run.log` (scheduled workers), and `tunnel.log`.

## Testing

Tests live under `tests/general/` and run with the repository's runner
(`tools/tests/README.md`). The endpoint has a fixed name, so every test carries
`_test.endpoint_name: apptest`: pass = the run completes (the server answered
through the platform and every worker connected) and `apptest` is listed; the
runner then deletes the endpoint and checks that no wrapper, server or worker
process is left on the resource it checks (`_test.resource`). The tests run
sequentially: they share the endpoint name.

```bash
python3 tools/tests/run-workflow-test.py workflows/app-testbed/tests/general/gcp-server-gcp-login-worker.json
```

## Debugging

Everything the run did is in its job directory on the server host
(`~/pw/jobs/<run-slug>/` for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/`
for registered ones): `inputs.sh` and `workers.json` are what the form sent,
`logs/<job>/step_N/step.out` the step traces. The server's files are in its
workdir (above). From anywhere:

```bash
pw workflows runs logs <slug> --job dispatch_workers   # per-site dispatch, queue states, connect lines
pw workflows runs logs <slug> --job wait_for_endpoint  # the statuses the health probe saw
pw workflows runs errors <slug>
```

## Provenance

Moved from the standalone `parallelworks/activate-app-testbed` repository
(`main` @ `9100bf7`). Its `workflow.yaml` became `yamls/general.yaml`, the
Python embedded in its heredocs the files in `app/` (checked out at run time, so
`scripts/sync-app.py` is gone), the inline dispatch step and site bootstrap
`app/dispatch_workers.sh` and `app/worker-bootstrap.sh`, and the separate
server, `pw endpoints http` and session-watch processes one `pw endpoints run`
wrapper. The marketplace item `app-testbed` still points at the old repository
until it is re-pointed here. Details and test results: `MIGRATION.md`.
