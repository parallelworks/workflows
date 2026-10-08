# DOE-OpenFOAM: Design of Experiments with Design Explorer

A design of experiments over the NACA 4-digit airfoil problem, as a fan-out of
one standalone workflow:

| Piece | Workflow | Called by |
|---|---|---|
| sample the designs | `app/doe.py` (this workflow) | the `preprocessing` job of `general.yaml` |
| solve one design | [`workflows/openfoam-naca`](../openfoam-naca/README.md) | the `workers` matrix of `general.yaml`, once per design, in parallel |
| explore the results | `app/design-explorer.html`, [Design Explorer](https://tt-acm.github.io/DesignExplorer/)'s engine in a platform-styled shell, served by `app/design-explorer-server.py` | a `pw` endpoint started by `preprocessing` |

The OpenFOAM README describes the case, its inputs and the images it renders;
this one covers the sampling, the fan-out, the page and the tests. The
guarded matrix comes from [`tutorials/optimization`](../../tutorials/optimization/README.md)
and the detached login-node server from
[`workflows/dakota-openfoam`](../dakota-openfoam/README.md).

## How the pieces connect

![general.yaml: preprocessing samples the designs into cases/ and starts the Design Explorer server; the workers matrix calls openfoam-naca once per case; results collects every case into results.csv; the server rebuilds data.csv from cases/ on every request and serves the page](thumbnails/doe-wiring.svg)

```
general.yaml
 ├─ preprocessing       checks the OpenFOAM (and ParaView) environments; doe.py samples
 │                      n_cases designs into cases/case_<j>/params.in; with images on,
 │                      downloads Design Explorer once, starts the server detached under
 │                      pw endpoints run, waits until the endpoint is listed and /healthz answers
 ├─ stop_server_if_unhealthy   if: !completed — kills a server whose endpoint never came up
 ├─ workers-1..n        matrix, if: job_id <= N_CASES, max-parallel = cases at a time:
 │                      openfoam-naca with params_file + case_dir = cases/case_<j>,
 │                      generate_images as the form says
 └─ results             if: always — study.py reads every case into results.csv;
                        the run fails only when no case solved
```

The pieces share only the files under `cases/`: the sampler writes
`case_<j>/params.in`, each OpenFOAM call leaves `results.out` (or `exit_code`
without it when the solver failed) and `images/*.png` next to it, and the
collector and the server read them. Every case is exactly a standalone
`openfoam-naca` run: its own checkout and environment check (lock-serialized
install), its own submitter job, its own `case/case.foam`.

## Sampling methods

The **Sampling method** dropdown picks how `n_cases` designs are spread over
the bounds of the **Design variables** editor (`<name> <lower> <upper>` per
line; equal bounds fix a variable). All five are standard-library Python in
`app/doe.py`:

| Method | What it does | Cases |
|---|---|---|
| Latin hypercube (default) | every variable split into `n` strata, each used once at a random position; even one-dimensional coverage at any `n` | `n` |
| Sobol sequence | the Sobol quasi-random sequence (Joe-Kuo direction numbers), shifted by a seeded random vector so the seed matters; even multi-dimensional coverage, extendable | `n` |
| Random | independent uniform samples (Monte Carlo) | `n` |
| Full factorial | a regular grid of `L` levels per free variable, the largest `L` with `L^d <= n` (at least 2) | `L^d` |
| One at a time | the center of the box, then each variable alone at `k = (n-1)/d` evenly spaced levels with the others at the center: a sensitivity screening | `1 + d*k` |

The structured designs decide their own size; the surplus matrix slots are
skipped for free and the log says how many designs were sampled. Every design
goes to `openfoam-naca` as a params file, so the four names (`max_camber`,
`camber_position`, `thickness`, `angle_of_attack`) must stay.

## The Design Explorer page

`design-explorer-<run slug>` (in `pw endpoints list` and on the run page) is
`app/design-explorer.html`: the parallel-coordinates engine of
[Design Explorer](https://github.com/tt-acm/DesignExplorer) (Thornton
Tomasetti's CORE studio; d3 and `d3.parcoords` from its tree, downloaded once
per cluster by `app/install-design-explorer.sh`) in a shell laid out for a
design study and styled with the platform's dashboard tokens (the same as
`hpc_status`): a light and a dark theme.

![The page: axis toggles and input sliders at the left, the selection tools above the parallel coordinates of the four inputs and the three outputs, the thumbnails of the solved designs below, bordered in the color of their drag coefficient](thumbnails/design-explorer.png)

- **Parallel coordinates**: one axis per input and per output (`Cd`, `Cl`,
  `Cl/Cd`), one line per solved design, colored by the **Color by** variable.
  Drag along an axis to **brush** a range, combine brushes across axes, drag a
  title to reorder, double-click one to flip. **Parametric variables** shows
  or hides axes; the **Cases** sliders narrow the inputs before brushing.
- **Reset selection**, **Exclude selection** and **Zoom to selection** work on
  the brushed designs; **Save selection to file** downloads them as a CSV.
- **Thumbnails**: one per design in view, sorted by any variable (**Sort by**),
  showing the image picked under **Image** (pressure, velocity, streamlines,
  turbulence, wake, mesh) in three sizes; designs outside the brush fade.
  Hover one to trace its line; click it for the full image with the design's
  values, arrow keys for the next or previous design.
- The page polls the server every 10 s while cases are pending and reloads
  the table when new cases have solved (brushes and exclusions kept), so a
  tab left open fills in as the study runs; a case appears as soon as its
  coefficients are on disk and its images a few seconds later.

The server (`app/design-explorer-server.py`, standard library) rebuilds
`data/data.csv` from the case directories on every request (only solved
cases: a row without numbers would break the axes), serves the images, and
answers `status.json` (the counts), `results.csv` (every case with its
status) and `healthz`. `data.csv` is in Design Explorer's own format (`in:`,
`out:` and `img:` columns), so it also loads in the upstream page.

Like the Pareto front of `dakota-openfoam`, the server only ever runs on the
login node and **outlives the run**: after the study finishes, or after a
cancel, it keeps serving until `pw endpoints delete design-explorer-<run
slug>`, which kills `pw endpoints run` and the server under it. The
`wait_for_endpoint` call only checks the endpoint; it tears nothing down, and
with no submitter behind this server nothing else would. That is what
`stop_server_if_unhealthy` is for: when preprocessing does not complete (the
health check failed, a step before it, or a cancel before the check passed),
it kills a server whose endpoint never registered, which `pw endpoints
delete` cannot reach, or deletes one that registered but never answered. A
healthy server is never touched again. With **Generate images** off there is
no server and no page; the results table is still written.

## Running it

Pick the resource, the sampling method, the number of cases and `mesh_scale`,
and choose login node or scheduled cases with **Cores per case** (the solver
caps the ranks at one per 1,000 cells; preprocessing warns when a request
exceeds that). **Cases at a time** caps how many cases run at once: on a
login node keep it times the cores per case within the node. The form's
defaults are the demo: 8 Latin hypercube designs at `mesh_scale` 2 on the
login node, images on, about 3 min on gcpsmall. **Load saved inputs →
`mesh3_slurm_4ranks`** is the converged-mesh study: 16 Sobol designs as SLURM
jobs of 4 ranks at `mesh_scale` 3.

The run succeeds when at least one case solved; cases whose solver diverged
are `FAILED` rows of the table (a result of the study, not an infrastructure
failure) and are listed in a warning, as are cases that never ran. Each
worker's log is three jobs deep (`workers-<k>` → `preprocessing`, `run_case`,
`results`).

## What a run leaves

In the run's job directory on the cluster:

```
cases/
├── doe.csv                the designs as a table (case, max_camber, ...)
├── doe.env                N_CASES, CASES_DIR, METHOD
├── case_1/ ... case_n/    one openfoam-naca case each:
│   ├── params.in            the design
│   ├── results.out          "<Cd> drag_coefficient", "<-Cl> neg_lift_coefficient" (or exit_code without it)
│   ├── case/case.foam       the solved case, for ParaView
│   └── images/              pressure, velocity, streamlines, turbulence, wake, mesh (PNG) + render.log
├── results.csv            every case: status, inputs, Cd, Cl, Cl/Cd, exit code, images
└── data.csv               the solved cases in Design Explorer's format
design-explorer.out        the server's output; design-explorer.pid its pid
```

## Tests

`tests/general/`: `gcpsmall.json` (login node, 6 Latin hypercube designs,
images and the page), `gcpsmall-slurm-mpi2.json` (4 Sobol designs as SLURM
jobs of 2 ranks) and `gcpsmall-no-images.json` (a 16-case full factorial
with one variable fixed, images off, no endpoint). The runner checks the
endpoint and deletes it. Run with
`python3 tools/tests/run-workflow-test.py <test.json>`.

## Files

| `app/` | Role |
|---|---|
| `doe.py` | the sampler: variables and bounds → `cases/case_<j>/params.in`, `doe.csv`, `doe.env` |
| `study.py` | the collector: every case directory → `results.csv`, `data.csv` (Design Explorer format), the counts; imported by the server |
| `design-explorer.html` | the page: Design Explorer's parallel coordinates in a shell styled for the platform (sliders, axis toggles, selection tools, thumbnails, lightbox, live reload) |
| `design-explorer-server.py` | serves the page, its libraries and the study (`/data/data.csv`, the images, `/results.csv`, `/status.json`, `/healthz`) |
| `install-design-explorer.sh` | idempotent download of Design Explorer at a pinned commit (the page's libraries) |

Checked out with it: `workflows/openfoam-naca/app` (the OpenFOAM and ParaView
installers, for the environment checks) and `tools/utils`.
