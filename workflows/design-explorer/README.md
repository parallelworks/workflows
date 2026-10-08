# Design Explorer

[Design Explorer](https://tt-acm.github.io/DesignExplorer/)'s parallel coordinates
over a design study, served as the endpoint `design-explorer-<run slug>`: the
design variables and the outputs as axes, the images of every design as
thumbnails, in a page styled for the platform, light or dark. Any workflow that
evaluates designs in case directories can call it as a subworkflow. For example,
[`doe-openfoam`](../doe-openfoam/README.md) and
[`dakota-openfoam`](../dakota-openfoam/README.md) serve their OpenFOAM airfoil
studies with it; the figure shows a doe-openfoam study.

![The page: axis toggles and input sliders at the left, the selection tools above the parallel coordinates of the four inputs and the three outputs, the thumbnails of the solved designs below, bordered in the color of their drag coefficient](thumbnails/design-explorer.png)

- **Brush** an axis (drag along it) to select a range, and combine brushes
  across axes. Drag a title to reorder the axes, double-click it to flip one.
- The **Cases** sliders narrow the inputs, **Parametric variables** hides axes,
  and **Color by** colors the lines and the thumbnails.
- **Exclude selection** and **Zoom to selection** act on the brushed designs;
  **Save selection to file** downloads them as CSV.
- Thumbnails outside the selection fade. Hover one to trace its line, click it
  for the full image and the design's values. **Image** switches between the
  images each case has, such as openfoam-naca's pressure, velocity and mesh.
- The page follows the study: it refreshes while cases are still running.

## The study directory

**Study directory** is the absolute path of the study on the resource. Design
Explorer only reads it: the workflow that runs the study creates it and passes
the same path to its evaluator and to this workflow. For example,
[`doe-openfoam`](../doe-openfoam/README.md) passes `<job dir>/cases` and
[`dakota-openfoam`](../dakota-openfoam/README.md) passes `<job dir>/state`.

Inside it, a case is a folder in one of exactly two places:

| Layout | Case ID | For example | Extra axes |
|---|---|---|---|
| `case_<j>/` | `case_3` | the cases [`doe`](../doe/README.md) writes | none |
| `iter_<N>/case_<j>/` | `iter_2/case_3` | a [`dakota`](../dakota/README.md) state directory | **generation** (`N`) and **pareto_front**: 1 for the designs no other beats on every `results.out` value, all minimized as Dakota minimizes them |

**Folders anywhere else are ignored without a warning.** `run_1/`,
`gen_1/case_1/` or a case nested deeper never show, and the page waits as if
the study had not started. A study counts as a Dakota one when it has an
`iter_*` folder or Dakota's `status`, `state.json` or `problem.json`.

Each case folder holds:

```
case_<j>/
├── params.in      the design, one <value> <name> line per variable: the in: axes
├── results.out    the outputs, same format: the out: axes; values = solved
├── exit_code      without results.out: the evaluation failed
└── images/*.png   optional: one thumbnail kind per file name
```

A case with neither `results.out` nor `exit_code` is still running. The page
links an image as `<case ID>/images/<name>.png`, the same in both layouts.
[`openfoam-naca`](../openfoam-naca/README.md)'s outputs, `drag_coefficient` and
`neg_lift_coefficient`, show as the drag and lift coefficients and their ratio.

The server reads the directory again on every request, so it can start before
the first case exists and shows each case as it lands. A `case_<j>/` study is
finished when no case is running. A Dakota study is finished only when its
`status` says CONVERGED or FAILED, because between two generations no case runs
but more are coming. A variable that never changes starts hidden. **Links** adds
buttons to the header, one `<label>=<URL>` per line; dakota-openfoam links its
Pareto front page this way.

## Running it

Run it by itself to explore a study that already ran: pick the resource and give
the study's absolute path, for example a doe-openfoam run's `cases/` under its
job directory (`~/pw/jobs/<run>/`). A workflow that runs the study calls it as a
subworkflow before its evaluations start, so the page follows them. This is how
doe-openfoam does it:

```yaml
- name: Design Explorer (Serve the Study)
  if: ${{ inputs.postprocessing.generate_images == true }}
  uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/design-explorer/yamls/general.yaml
    cluster:
      resource: ${{ inputs.cluster.resource }}
    study:
      cases_dir: ${{ needs.preprocessing.outputs.CASES_DIR }}
      title: NACA airfoil DOE
```

The server only runs on the login node, so it is started detached rather than
through the submitter. The run completes once the endpoint is listed and its
`/healthz` answers, and the endpoint keeps serving after the run until
`pw endpoints delete design-explorer-<run slug>`. A server whose endpoint never
answered is removed by the run's `stop_server_if_unhealthy` job. Design
Explorer's libraries are downloaded once, at a pinned commit, under
`~/pw/software/design-explorer/`.

## Platforms

`yamls/general.yaml` is the only form: the server runs on the login node and
uses no scheduler, so nothing differs between platforms. On HSP and NOAA, a
caller passes its top-level resource as `cluster.resource`. On NOAA clusters the
libraries go to the shared software tree when the account can write there, and
an HPCMP login node must reach GitHub for the one-time download.

## Files

| `app/` | Role |
|---|---|
| `design-explorer.html` | the page |
| `design-explorer-server.py` | serves the page, its libraries, the images and the tables |
| `study.py` | reads a study into `results.csv` and Design Explorer's `data.csv`; doe-openfoam's results job uses it too |
| `install-design-explorer.sh` | downloads Design Explorer once, at a pinned commit |

All standard library Python; [software/design-explorer.md](../../.claude/skills/activate-workflows/references/software/design-explorer.md)
has the notes on Design Explorer's libraries and data format.
