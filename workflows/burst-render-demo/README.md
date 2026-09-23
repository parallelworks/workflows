# Multi-Site Burst Renderer

A demo workflow that renders a Mandelbrot fractal in parallel across one or more
compute sites, with the tiles assembling in real time in a live browser dashboard.
It shows ACTIVATE bursting work to several resources at once and streaming the
results back to one place.

![Thumbnail](thumbnails/burst-render-demo.png)

## What It Does

1. **Serves a dashboard** (FastAPI + WebSocket) on the login node of the dashboard
   host, through a **`pw` endpoint** named `burst-render-<run-slug>`
2. **Splits the tile grid** evenly across the compute sites in the form
3. **Renders the tiles** on every site in parallel, on its login node or on compute
   nodes allocated with `srun`, and POSTs each tile to the dashboard as it finishes
4. **Completes the run** once every site is done; the dashboard keeps serving the
   finished image until its endpoint is deleted

## Architecture

```
              ACTIVATE Workflow
                    │
         ┌──────────┴──────────┐
         ▼                      ▼
  Site 1 (this host)      Site 2 (remote)
  renders tiles 0..N/2    renders tiles N/2..N
    localhost:PORT         reverse SSH tunnel
         │                      │
         └──── POST tiles ──────┘
                    │
              Dashboard Server  ──  pw endpoints run  ──▶  https://<subdomain>.activate.pw/
              (dashboard host)
```

The jobs follow the repository's endpoint pattern:

1. **preprocessing** — on the dashboard host: checks out `workflows/burst-render-demo/app`,
   writes `inputs.sh`, runs `controller.sh` (Python check, `uv`, and the dashboard's
   virtualenv under `${HOME}/pw/software/burst-render-demo/venv`, idempotent) and
   assembles the start script.
2. **session_runner** — submits the start script through
   [`script_submitter/v3.6`](../script_submitter/) on the login node (never scheduled:
   the sites' tunnels terminate on the host that dispatches them). `start-template.sh`
   wraps the dashboard in `pw endpoints run`; the assigned port arrives as `PORT` and a
   small launcher publishes it as `SESSION_PORT` in the run directory.
3. **wait_for_endpoint** — the shared [`wait_for_endpoint`](../wait_for_endpoint/)
   subworkflow waits for the endpoint, probes its URL with the run's key, touches the
   skip file so the dashboard outlives the run, and cancels the submitter.
4. **render** — configures the grid (`POST /api/config`), runs `dispatch_renders.sh`,
   and prints the dashboard URL when every site has finished.

## Sites and how they are reached

`dispatch_renders.sh` runs on the dashboard host and handles each site in parallel:

- **A site on the dashboard host's own resource** renders right there: `render_tiles.sh`
  on the login node, or on compute nodes through `srun`, which reach the dashboard on
  the login node's hostname. No tunnel and no SSH key are involved, so a cloud
  cluster's login node is a valid dashboard host for itself.
- **A site on another resource** is reached with `ssh` over `pw ssh --proxy-command`
  carrying a reverse tunnel back to the dashboard port. The site clones this
  repository (sparse, `workflows/burst-render-demo/app`) into
  `~/pw/jobs/burst_render_remote/<run-slug>/` and runs `render_tiles.sh`; with
  **Schedule Job?** on, a TCP proxy on the site's login node exposes the tunnel to the
  compute nodes and the tiles render under `srun`. This needs the platform SSH key
  (`~/.ssh/pwcli`) on the dashboard host, which the user workspace and on-prem
  resources have and a cloud cluster's login node does not.

Only SLURM sites can schedule; every other site renders on its login node. The
**Additional Directives** editor takes `#SBATCH` lines, which are passed to `srun` as
options (so `#SBATCH --account=...` or `--exclusive` work; commented `##SBATCH` lines
and trailing comments are dropped). Multi-node allocations split the site's tile range
across the tasks by `SLURM_PROCID`.

## Inputs

| Input | Description |
|-------|-------------|
| Dashboard Host | Login node, cloud VM or the user workspace that serves the dashboard and dispatches the sites |
| Compute Sites | One entry per site: resource, **Schedule Job?** (SLURM only) and its partition, node count, walltime and extra directives |
| Grid Size | Tiles per side (total = N x N): 4x4, 8x8, 16x16, 32x32 |
| Tile Resolution | 128, 256 or 512 pixels per tile |
| Color Palette | Electric, Fire, Ocean, Cosmic |
| Worker Threads | Render processes per node: auto (all cores) or 1, 2, 4, 8 |

## Variants

`yamls/general.yaml` targets standard cloud and on-prem SLURM clusters; SLURM
account and QoS go in the **Additional Directives** editor. `yamls/hsp.yaml` is the
HSP (`activate.hpc.mil`) form: it submits the dashboard through the `hsp` script
submitter and adds the SLURM **Account** and **QoS** dropdowns per site (shown for
on-prem `existing` resources) plus the DSRC `--constraint=mla` hint. The scripts are
identical; on a cloud cluster the two variants behave the same.

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/burst-render-demo/yamls/general.yaml" -i '{
  "head": {"resource": "pw://<user>/<cluster>"},
  "targets": [{"resource": "pw://<user>/<cluster>", "scheduler": true,
               "slurm": {"partition": "compute", "nodes": "1", "time": "00:10:00"}}],
  "render_settings": {"grid_size": "8", "image_size": "256", "palette": "electric", "parallelism": "auto"}
}'
pw endpoints list                              # burst-render-<run-slug> and its URL
pw endpoints delete burst-render-<run-slug>    # stops the dashboard
```

Open the endpoint (Sessions page, or the URL the `render` job prints) to watch the
tiles fill in; opening it after the render shows the finished image.

## Dashboard Features

- **Live canvas** — tiles render and appear in real-time
- **Site color-coding** — each site gets its own border color
- **Statistics** — elapsed time, tiles/sec, average render time, total tiles
- **Throughput chart** — tiles/sec over time by site
- **Late-join support** — opening the dashboard after rendering shows all completed tiles

## Files

```
workflows/burst-render-demo/
├── yamls/
│   ├── general.yaml         # Standard cloud/on-prem SLURM clusters
│   └── hsp.yaml             # HSP form (SLURM account/QoS per site, DSRC hint)
├── app/                     # The only subtree a run checks out
│   ├── controller.sh        # Dashboard host: Python, uv, dashboard virtualenv
│   ├── start-template.sh    # Dashboard behind pw endpoints run; publishes SESSION_PORT
│   ├── dispatch_renders.sh  # Splits the grid and drives every site (local or over SSH)
│   ├── render_tiles.sh      # Renders a tile range and POSTs the tiles
│   ├── renderer.py          # Pure Python Mandelbrot renderer (Pillow optional)
│   ├── post_tile.py         # Multipart POST with the standard library
│   ├── dashboard.py         # FastAPI + WebSocket live dashboard
│   └── templates/index.html # Dashboard UI
├── tests/<variant>/         # End-to-end tests (tools/tests/README.md)
├── thumbnails/burst-render-demo.png
└── README.md
```

## Requirements

- **Python 3** on every site (the renderer uses only the standard library; Pillow is
  used when present)
- **Python 3.8+** on the dashboard host for FastAPI, or internet access for `uv` to
  install a newer interpreter; `uv` and the virtualenv are installed once under
  `${HOME}/pw/software`
- `~/.ssh/pwcli` on the dashboard host to dispatch to *other* resources
- No GPU required — pure CPU rendering

## Debugging

Everything is in the run's job directory on the dashboard host
(`~/pw/jobs/<run-slug>/` for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/` for
registered ones): `SESSION_PORT` is the dashboard's local port,
`subworkflows/session_runner/step_0/run.<id>.out` the endpoint wrapper's and the
dashboard's output, `logs/render/step_1/step.out` the dispatcher's log with every site's
output prefixed by `[site-N]`. Remote sites keep their clone and nothing else under
`~/pw/jobs/burst_render_remote/<run-slug>/`. From anywhere:

```bash
pw workflows runs logs <slug> --job render
pw workflows runs logs <slug> --job session_runner
pw workflows runs errors <slug>
```

## Provenance

Moved from the standalone `parallelworks/burst-render-demo` repository (`main` @
`ae9ad9b`). Its `scripts/` became `app/`; `setup.sh` and the install half of
`start_dashboard.sh` became `controller.sh`, the launch half `start-template.sh`; the
`sessions:` block and the `update_session` / `wait_for_dashboard` jobs became the
`script_submitter` + `wait_for_endpoint` jobs. The dispatcher gained the local mode for
sites on the dashboard host's resource, clones this repository on remote sites, passes
`#SBATCH` directives to `srun`, and reports a failed site (its `| sed` pipelines
returned 0 before). Details and test results: `MIGRATION.md`.
