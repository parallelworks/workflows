# Deployment Guide

How the **HPC Status** workflow deploys the dashboard on ACTIVATE: its jobs, inputs and
variants, how to stop and debug it, and how to develop it. What the dashboard shows is in
the [README](../README.md). Paths are relative to `workflows/hpc_status/`.

## How the workflow runs it

The jobs follow the repository's endpoint pattern:

1. **preprocessing** — on the dashboard host: checks out `workflows/hpc_status/app`,
   writes `inputs.sh`, runs `controller.sh` (the `pw` CLI check, the shared `uv` and the
   dashboard's virtualenv under `${HOME}/pw/software/hpc_status/venv`, idempotent: a venv
   that imports the server is reused; then it deletes the previous dashboard with this
   endpoint name) and assembles the start script.
2. **session_runner** — submits the start script through
   [`script_submitter/v3.6`](../../script_submitter/), always on the host itself: the
   dashboard needs the `pw` CLI, its credentials and internet access for as long as it
   serves. `start-template.sh` wraps the server in `pw endpoints run`, which assigns the
   port and dials out, so the host needs no inbound access.
3. **wait_for_endpoint** — the shared [`wait_for_endpoint`](../../wait_for_endpoint/)
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
(`app/configs/`); see [configuration.md](configuration.md).

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

## Publishing a dashboard by hand

From a clone of this repository, with the `pw` CLI authenticated:

```bash
cd workflows/hpc_status
./scripts/serve-endpoint.sh
```

It runs the workflow's own `app/controller.sh` and `app/start-template.sh` on this
machine, so it behaves like a run with Keep Serving off: the same name (`hpc-status`,
or `ENDPOINT_NAME`), the same address (`status-<username>`, or `ENDPOINT_SUBDOMAIN`), the
previous dashboard replaced, the same fallback. It holds the session open until you
press Ctrl-C. `PLATFORM`, `PINNED_PORT` and `DEFAULT_THEME` stand in for the form's
Platform, Local Port and UI Theme.

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
./scripts/run.sh                                          # http://localhost:8080 (or the next free port)
~/.venvs/hpc-status/bin/pip install pytest
(cd dev && ~/.venvs/hpc-status/bin/python -m pytest)     # the unit and integration suite
```

`scripts/run.sh` builds `~/.venvs/hpc-status` from `app/requirements.txt` with `uv` and
runs the server from `app/`; `PORT`, `CONFIG_FILE` (relative to `app/`), `DEFAULT_THEME`
and the other variables in its header set it up. With the `pw` CLI authenticated the
local server collects from every cluster you have access to. After changing the API
catalog (`app/src/server/api_catalog.py`), regenerate the spec with
`python scripts/build_openapi.py` (a test fails while it is stale);
`scripts/build_basemap.py` rebuilds the topology map outline
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
├── scripts/                 # run.sh, serve-endpoint.sh (by hand); build_openapi.py, build_basemap.py
├── schemas/                 # OpenAPI spec and JSON schemas
├── docs/                    # deployment (this guide), API, configuration, glossary, NOAA marketplace copy, examples
├── dev/                     # pytest.ini, tests/
├── tests/<variant>/         # End-to-end tests (tools/tests/README.md)
├── thumbnails/              # hpc-status.png, hpcmp-status.png, rdhpcs-status.png
├── README.md                # the standalone repository's README, verbatim
└── LICENSE
```

## Provenance

Moved from the standalone `parallelworks/hpc_status` repository (`main` @ `30ce200`). Its
`src/`, `web/` and `configs/` are `app/` verbatim but for one log line; in a run,
`scripts/run.sh` became `controller.sh` (install) and the launcher `start-template.sh`
writes, and `scripts/serve-endpoint.sh` the rest of `start-template.sh`. Both scripts are
still here for use by hand: `run.sh` adapted to `app/`, `serve-endpoint.sh` a wrapper
around the workflow's two scripts. The single-job
`workflow.yaml`, `yamls/hsp.yaml` and `yamls/rdhpcs.yaml` became the three variants here.
What changed and why: `MIGRATION.md`.
