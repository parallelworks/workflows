# HPC Status Monitor

A single pane of glass for your HPC fleet. At a glance: what's up, what's
slow, where your jobs will wait, and how much allocation you have left.

## What it's for

You have work to run on HPC systems, but the systems are scattered across
sites, schedulers, and login nodes. Before submitting a job you want to
know:

- Is the system even up right now?
- Which queue will get me running fastest?
- Am I close to burning through my allocation?
- Is `$SCRATCH` about to purge my files?

The Status Monitor answers those questions in one place, refreshed
continuously, so you don't have to `ssh` around and run five different
commands to decide where to submit.

## What you'll see

**Fleet status.** Every HPC system this deployment knows about, as cards
grouped by site: what each machine is for, whether it is up, and how busy
it is. Switch to the dense table for login nodes, schedulers and
timestamps.

"Knows about" means three sources merged, because none of them knows
everything: the centre's status page publishes some systems, the monitor
holds live sessions to others, and the marketplace lists what exists and
describes it. A machine that is reachable but unpublished used to be
missing here entirely. Systems nothing is watching still appear, marked
as such, and are left out of the uptime figure — the percentage is over
monitored systems, not over everything that has a name.

**Topology.** An interactive map of what the monitor is connected to —
sites, systems, and the live sessions between them. It opens on live
connections only, since a graph of machines nobody here has a session to
is mostly noise; untick **Live connections only** for the whole fleet. Group by site
(a DSRC on an HPCMP deployment), scheduler, status, or connection; switch between hierarchy, radial,
force, lane, load, and geographic layouts — the geographic one is a real map,
with each site pinned at its actual coordinates and framed insets for
anything off the mainland. Cloud clusters are placed too — an AWS GovCloud
machine pins to its region. Zoom in (or set **Map detail**) and each site
opens up into the individual systems behind it. A **Timeline** button reveals a transport that replays the last 6 hours to 3 days from the monitor's own
records — scrub or press play to watch status and load move — and systems
that change on a live refresh pulse so you can see it happen. The **Load**
layout plots each system by how busy it is, so replaying a day shows the
fleet rising and falling; systems the monitor could not measure sit in a
band below the axis rather than pretending to be idle. Node color is status, size is core
count, and the outer ring is how busy it is. Nodes with an open insight
carry a warning badge, links animate at the speed of their measured round
trip, and each system shows its status timeline for the last 24 hours.
Click a system to inspect it — click again to jump straight to its queue
health, or shift-click several to compare them side by side.

**Queue health.** For each system, live queue depth, node availability,
and core demand — so you can pick the queue that isn't backed up.

**Quota usage.** Your allocations in core-hours, how fast you're burning
them, and warnings before you hit the limit. Broken down by subproject
where relevant.

**Storage.** Capacity and usage for `$HOME`, `$WORK`, and `$SCRATCH` on
every system, with purge-window reminders for scratch.

**Insights.** Automatic recommendations — "this queue is draining, try
that one", "you're at 92% of your allocation", "scratch is filling up".

**Where should I run this?** Describe a job — cores, walltime, GPUs — and
the Insights page ranks every queue that can actually run it, using idle
cores, measured backlog, estimated time-to-start, and how much allocation
you have left. Queues that *can't* run it say why instead of ranking last.

**Wait estimates.** Queue depth is recorded over time, so the queue page
can turn a backlog into an estimated start time — derived from observed
core turnover, and labelled with the confidence behind it. A queue with no
observed turnover says so rather than inventing a number.

**API.** Everything on every page is available as JSON. The **API** tab
lists every endpoint with its parameters, runs any of them against the
running deployment, and hands you the equivalent `curl` command. The list
is served by the API itself, so it describes the version you are running.

**Alerts.** Point `alerts.webhook_url` at Slack, Teams, or your own
receiver and the monitor notifies you when a system goes down or comes
back, with a per-system cooldown so a flapping machine doesn't spam you.

## Launching it

Launch **HPC Status** from your workflows list. It publishes the dashboard as an endpoint
session and gives you a URL you can hand to someone else:
`https://status-<your-username>.<sessions domain>/`, the same address every time. The
platform assigns a free port and tunnels to it without needing any inbound access to the
machine it runs on. The dashboard keeps serving after the run completes; stop it by
deleting its session, `hpc-status`, from the Sessions page.

The dashboard picks up every cluster you have access to on the platform. It works with
PBS/Slurm HPC clusters, GPU servers (via `nvidia-smi`), and plain compute nodes.

## Help while you're using it

Every page has a **Help** button in the top-right with a quick reference
for the HPC terms you'll see (core-hours, walltime, draining queues, the
difference between `$HOME` / `$WORK` / `$SCRATCH`, and so on). Each
metric also has a `ⓘ` tooltip that explains what it means.

## Deployments

The monitor supports branded deployments. The HPCMP build, for example,
uses the HPCMP purple palette and logo mark — it is what the HSP variant
(`yamls/hsp.yaml`) loads; elsewhere, set **Platform** to HPCMP.

## For operators and developers

- **How the workflow runs it, its inputs and variants:** the sections below
- **Configuration options:** [docs/configuration.md](docs/configuration.md)
- **REST API:** the **API** tab in a running deployment, or
  [docs/api.md](docs/api.md) / [dev/schemas/openapi.yaml](dev/schemas/openapi.yaml)
  (generated by `python dev/scripts/build_openapi.py`)
- **HPC glossary:** [docs/glossary.md](docs/glossary.md)

## How the workflow runs it

The jobs follow the repository's endpoint pattern:

1. **preprocessing** — on the dashboard host: checks out `workflows/hpc_status/app`,
   writes `inputs.sh`, runs `controller.sh` (the `pw` CLI check, the shared `uv` and the
   dashboard's virtualenv under `${HOME}/pw/software/hpc_status/venv`, idempotent: a venv
   that imports the server is reused; then it deletes the previous dashboard with this
   endpoint name) and assembles the start script.
2. **session_runner** — submits the start script through
   [`script_submitter/v3.6`](../script_submitter/), always on the host itself: the
   dashboard needs the `pw` CLI, its credentials and internet access for as long as it
   serves. `start-template.sh` wraps the server in `pw endpoints run`, which assigns the
   port and dials out, so the host needs no inbound access.
3. **wait_for_endpoint** — the shared [`wait_for_endpoint`](../wait_for_endpoint/)
   subworkflow waits for the endpoint, probes `/` with the run's key until the dashboard
   answers (up to 15 minutes: a first start has no cached fleet and answers only after one
   full sweep). With **Keep Serving After The Run Ends** on (the default) it then touches
   the skip file so the dashboard outlives the run, and cancels the submitter.
4. **summary** — prints the dashboard URL and how to stop it.

By default the run completes within a minute or so and the dashboard keeps serving until
its endpoint is deleted. With **Keep Serving After The Run Ends** off the run stays open
for as long as the dashboard serves: cancelling the run stops it (the submitter's cleanup
takes its process group down), and a dashboard stopped by deleting its session ends the
run as completed.

### Where it runs, and on which credential

**Where To Run** defaults to the user workspace, which is the right choice unless you
have a reason to move it; pick a long-lived cluster to keep the dashboard serving when the
workspace recycles.

A run's own `PW_API_KEY` is revoked when the run completes, but the dashboard calls `pw`
for as long as it serves (`pw clusters ls`, `pw ssh` to every cluster). So the start
script hands it a credential that outlives the run, and says in the run log which one:

- **saved credentials** on the host (`pw auth` there), when they authenticate against
  this platform — they outlive everything;
- otherwise, on the user workspace, **the workspace key** from
  `/etc/profile.d/parallelworks-env.sh` (only that variable is taken from the file, and
  only when it works);
- otherwise a warning: the dashboard serves, but stops collecting when the run
  completes. Run `pw auth` on that host, or use the workspace. (With Keep Serving off the
  run's key lasts as long as the dashboard does, so there is nothing to warn about.)

The collector also recovers on its own if the key it holds dies mid-life
(`src/collectors/pw_cluster.py`).

### A stable address, and starting again

Without a subdomain the platform assigns a random one per session. The dashboard asks for
**`status-<username>`** instead (lowercased and hyphenated, so `Matthew.Shaxted` becomes
`status-matthew-shaxted`), or the **Public Subdomain** you set — the same URL every run.
That is a request, not a claim: `pw subdomains reserve status-<username>` keeps it yours.
When the platform refuses the subdomain, or another endpoint already serves there, the
run falls back to an assigned address and says so.

The endpoint is named **`hpc-status`** (`rdhpcs-status` on NOAA), or the **Endpoint
Name** you set — the same name every run, in the Sessions page and `pw endpoints list`. A
name is folded like a subdomain: lowercase, anything outside `a-z 0-9 -` becomes a dash.

**Starting again restarts.** Two endpoints cannot share a name, so the controller deletes
the endpoint with this name before the new dashboard starts, wherever it runs: its
`pw endpoints run` notices the session is gone and takes its process tree down. That also
clears a session a recycled workspace left listed but dead. It happens in preprocessing,
before `wait_for_endpoint` starts looking for the name, so the health check can only ever
see the new dashboard. The start script then deletes any endpoint at the address named
`<name>-…` — a dashboard launched while the name carried the run slug — and leaves
everything else alone. A second dashboard with its own Endpoint Name and Public Subdomain
runs alongside the first.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| Platform | `auto` | `general.yaml` only (hidden elsewhere): `generic`, `hpcmp` or `noaa` configuration; `auto` picks it from the platform host (`*.hpc.mil` → HPCMP, NOAA hosts → NOAA) |
| Endpoint Name | `hpc-status` (`rdhpcs-status` on NOAA) | Name of the endpoint session; a launch replaces the dashboard running under it |
| Keep Serving After The Run Ends | on | On: the run completes once the dashboard answers and the dashboard outlives it. Off: the run stays open while it serves; cancel the run to stop it |
| Public Subdomain | *(blank)* | Hostname label; blank derives `status-<username>` |
| Clusters Swept At Once | `6` | Clusters collected from simultaneously |
| Local Port | `0` | Port the dashboard binds on the host; `0` lets `pw endpoints run` pick a free one |
| UI Theme | `light` | Default color theme |
| Enable Cluster Pages | on | Queue and quota pages |
| Enable Cluster Monitor | on | Background cluster collection |
| Refresh Interval | `120` (`180` on NOAA) | Seconds between collections (at least 60) |
| Where To Run | user workspace | Where the dashboard runs (see above), in its own collapsed group |

Everything but Platform lives in the collapsed **Settings** and **Where To Run** groups, so
a launch with the defaults is one click. Everything else is in the deployment's YAML config
(`app/configs/`); see [docs/configuration.md](docs/configuration.md).

## Variants

| YAML | Platform | Configuration | Endpoint name |
|---|---|---|---|
| `yamls/general.yaml` | anything but the two below | `auto` (dropdown) | `hpc-status` |
| `yamls/hsp.yaml` | `activate.hpc.mil` | `configs/config.hpcmp.yaml` — HPCMP fleet from centers.hpc.mil, DSRC names, purple branding | `hpc-status` |
| `yamls/noaa.yaml` | `noaa.parallel.works` | `configs/config.noaa.yaml` — RDHPCS systems, pins every `pw` call to the `noaa` identity | `rdhpcs-status` |

Each passes its platform's script submitter. `noaa.yaml` also picks the install directory
at run time, as the other NOAA variants here do: the cluster's shared software tree
(`/contrib/pw` on Hera, Mercury and Ursa, `/usw/rdhpcs/software/pw` on Gaea) when the
account can write there, `${HOME}/pw/software` otherwise (the workspace included).

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/hpc_status/yamls/general.yaml" -i '{"cluster":{"resource":"workspace"}}'
pw endpoints list                              # hpc-status and its URL
pw endpoints delete hpc-status                 # stops the dashboard
```

## Stopping it

Delete its session from the Sessions page, or `pw endpoints delete hpc-status`.
`pw endpoints run` shuts down when its session goes (`Endpoint "..." was deleted; shutting
down.`), taking the dashboard and its collectors with it. Launching again replaces it. With
Keep Serving off, cancelling the run stops it too.

## Debugging

Everything is in the run's job directory on the dashboard host
(`~/pw/jobs/<run-slug>/` for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/` for
registered ones): `subworkflows/session_runner/step_0/run.<id>.out` is the endpoint
wrapper's and the dashboard's output (which configuration and credential it chose, every
sweep), `subworkflows/session_runner/step_0/launch-dashboard.sh` the exact server command.
The dashboard keeps its cache, history database and briefings in `~/.hpc_status/` on that
host, so history survives relaunches. From anywhere:

```bash
pw workflows runs logs <slug> --job session_runner
pw workflows runs logs <slug> --job wait_for_endpoint
pw workflows runs errors <slug>
```

## Developing the dashboard

The server is standard-library HTTP plus `requests`, `beautifulsoup4`, `pyyaml`
(`app/requirements.txt`); the pages are plain HTML/JS with no build step.

```bash
cd workflows/hpc_status
python3 -m venv ~/.venvs/hpc-status && ~/.venvs/hpc-status/bin/pip install -r app/requirements.txt pytest
(cd dev && ~/.venvs/hpc-status/bin/python -m pytest)     # the unit and integration suite
(cd app && ~/.venvs/hpc-status/bin/python -m src.server.main --port 8080 --config configs/config.yaml)
```

With the `pw` CLI authenticated the local server collects from every cluster you have
access to. After changing the API catalog (`app/src/server/api_catalog.py`), regenerate
the spec with `python dev/scripts/build_openapi.py` (a test fails while it is stale);
`dev/scripts/build_basemap.py` rebuilds the topology map outline
(`app/web/assets/data/README.md`).

## Files

```
workflows/hpc_status/
├── yamls/{general,hsp,noaa}.yaml
├── app/                     # The only subtree a run checks out
│   ├── controller.sh        # pw check, uv, the dashboard's virtualenv, stop the previous one
│   ├── start-template.sh    # configuration, durable credential, address, pw endpoints run
│   ├── requirements.txt
│   ├── configs/             # config.yaml (generic), config.hpcmp.yaml, config.noaa.yaml
│   ├── src/                 # collectors, data layer, insights, HTTP server
│   └── web/                 # pages, assets, bundled basemap
├── docs/                    # API, configuration, glossary, NOAA marketplace copy, examples
├── dev/                     # pytest.ini, tests/, scripts/ (OpenAPI, basemap), schemas/
├── tests/<variant>/         # End-to-end tests (tools/tests/README.md)
└── thumbnails/              # hpc-status.png, hpcmp-status.png, rdhpcs-status.png
```

## Provenance

Moved from the standalone `parallelworks/hpc_status` repository (`main` @ `30ce200`). Its
`src/`, `web/` and `configs/` are `app/` verbatim but for one log line; `scripts/run.sh`
became `controller.sh` (install) and the launcher `start-template.sh` writes, and
`scripts/serve-endpoint.sh` the rest of `start-template.sh`; the single-job
`workflow.yaml`, `yamls/hsp.yaml` and `yamls/rdhpcs.yaml` became the three variants here.
What changed and why: `MIGRATION.md`.

## License

See [LICENSE](../../LICENSE).
