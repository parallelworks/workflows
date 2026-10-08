# Design Explorer

[Design Explorer](https://tt-acm.github.io/DesignExplorer/)'s parallel coordinates
over a study of NACA airfoil cases, served as the endpoint
`design-explorer-<run slug>`: the design variables and the coefficients as axes,
the flow images of every design as thumbnails, in a page styled for the
platform, light or dark.

![The page: axis toggles and input sliders at the left, the selection tools above the parallel coordinates of the four inputs and the three outputs, the thumbnails of the solved designs below, bordered in the color of their drag coefficient](thumbnails/design-explorer.png)

- **Brush** an axis (drag along it) to select a range, and combine brushes
  across axes. Drag a title to reorder the axes, double-click it to flip one.
- The **Cases** sliders narrow the inputs, **Parametric variables** hides axes,
  and **Color by** colors the lines and the thumbnails.
- **Exclude selection** and **Zoom to selection** act on the brushed designs;
  **Save selection to file** downloads them as CSV.
- Thumbnails outside the selection fade. Hover one to trace its line, click it
  for the full image and the design's values. **Image** switches between
  pressure, velocity, streamlines, turbulence, wake and mesh.
- The page follows the study: it refreshes while cases are still running.

## What it reads

**Study directory** is a directory of
[`openfoam-naca`](../openfoam-naca/README.md) case directories, each with
`params.in`, `results.out` (or `exit_code` when the solver failed) and `images/`.
The server reads it on every request, so it can be served before the first case
exists.

| Study | Layout | Extra axes |
|---|---|---|
| [`doe-openfoam`](../doe-openfoam/README.md)'s `cases/` | `case_<j>/` | none |
| [`dakota-openfoam`](../dakota-openfoam/README.md)'s `state/` | `iter_<N>/case_<j>/` | **generation**, and **pareto_front** (1 for the designs no other beats on both drag and lift); lines colored by generation |

A variable that never changes, such as a fixed angle of attack, starts hidden.
**Links** adds buttons to the header, one `<label>=<URL>` per line;
dakota-openfoam links its Pareto front page this way.

## Running it

Run it by itself to explore a study that already ran: pick the resource and give
the absolute path of its `cases/` or `state/`, under the run's job directory
(`~/pw/jobs/<run>/`). Both workflows above call it as a subworkflow instead:

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

## Variants

`yamls/hsp.yaml` (HSP, `activate.hpc.mil`) and `yamls/noaa.yaml` (NOAA,
`noaa.parallel.works`) take the resource as the form's top-level input. On NOAA
the libraries go to the cluster's shared software tree when the account can
write there.

## Files

| `app/` | Role |
|---|---|
| `design-explorer.html` | the page |
| `design-explorer-server.py` | serves the page, its libraries, the images and the tables |
| `study.py` | reads a study into `results.csv` and Design Explorer's `data.csv`; doe-openfoam's results job uses it too |
| `install-design-explorer.sh` | downloads Design Explorer once, at a pinned commit |

All standard library Python; [software/design-explorer.md](../../.claude/skills/activate-workflows/references/software/design-explorer.md)
has the notes on Design Explorer's libraries and data format.
