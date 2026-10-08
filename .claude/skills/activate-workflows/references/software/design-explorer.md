# Design Explorer (parallel coordinates for a design study)

> Learned building `workflows/doe-openfoam` (2026-10-08): the study page is the
> app's own `design-explorer.html` over the libraries of Thornton Tomasetti's
> [Design Explorer](https://github.com/tt-acm/DesignExplorer) (d3 v3.5 and its
> build of `d3.parcoords`), downloaded once per cluster at a pinned commit by
> `app/install-design-explorer.sh` and served by `app/design-explorer-server.py`.
> Since 2026-10-08 the page is its own workflow, `workflows/design-explorer` (the
> `app/` paths below are its own), which `doe-openfoam` and `dakota-openfoam` call
> as a subworkflow with the study directory; it serves any such directory standalone.

## One server, two study layouts

- `app/study.py` reads `DIR/case_<j>/` (a DOE's `cases/`) and `DIR/iter_<N>/case_<j>/`
  (a Dakota `state/`) with one glob; a case id is its path relative to DIR, so
  image paths and the server's `/data/<id>/images/...` route work for both.
- A Dakota study adds `in:generation` (an input, so it gets a slider) and
  `out:pareto_front` (computed from the solved cases, so it is current before
  Dakota ingests them); the page colors and sorts by generation by default.
- **"Final" differs**: a DOE is final when no case is pending; between two Dakota
  generations no case is pending either, so an optimization is final only when
  `state/status` says CONVERGED or FAILED. `status.json` carries `final` and
  `state`, and the page polls until `final`.
- Read cases from the directories, not from Dakota's `evaluations.csv`: the
  optimizer appends to it only at the next generation's ingest, a generation late.
- A variable that never changes (the loop's angle of attack) is a flat axis: the
  page hides it until the user shows it, decided again on every reload.

## Why a shell of our own

- The upstream page (`index.html`, 3000 lines) carries its own chrome (Get Data,
  My Static Link, Tutorial, Services, the copyright strip), loads a Google Drive or
  "server folder" through `?ID=<base64 of the folder URL>` and shows the thumbnails as
  circles under a scatter matrix. It works behind an endpoint (verified through the
  platform, `?ID=ZGF0YS8=` for the relative folder `data/`), but it does not look like
  the platform and every non-`in:`/`out:`/`img:` column becomes an axis (`case`).
- The page in the app keeps the engine and the data format (`in:` columns for the
  inputs, `out:` for the outputs, `img:` for the image paths, so `data.csv` still loads
  in the upstream page) and redoes the shell with the `hpc_status` tokens: axis
  toggles and input sliders at the side, Reset/Exclude/Zoom/Save over the plot,
  a thumbnail grid with a sort and an image selector, a lightbox, a 10 s poll of
  `status.json` that reloads the cases while any is pending.

## d3.parcoords, Design Explorer's build: what bit

- **`createAxes()` calls `string_as_unicode_escape()`, which only Design Explorer's
  own page defines**: define it (hex of each char code) before the library, or every
  axis is missing and the init dies after the lines are drawn.
- **Every field of a row is typed** (`detectDimensionTypes`), and there is no scale
  for a boolean: a `row.__excluded = true` flag broke `autoscale` with
  `defaultScales[__.dimensions[k].type] is not a function`. Keep flags out of the row
  objects (a set keyed by id); strings are fine (`"string"` scale).
- **Setters redraw at once**: `pc.margin(...)`, `.width()`, `.height()` call
  `pc.resize()` → `render()` → `autoscale()` before the dimensions are set. Pass
  the options through the constructor, `d3.parcoords({margin, alpha, composite,
  color})(selector)`, then `.data()`, `.dimensions()`.
- **`pc.dimensions({...})` keeps only the keys**: the side effect rebuilds the table
  from `d3.keys(value)`, so a title or type passed there is lost. Set them afterwards
  on the exposed state, `pc.state.dimensions[k].title = ...`, before `createAxes()`.
- Init order that works: `pc.data(rows).dimensions(dims)`, titles on the state,
  `pc.render().createAxes().brushMode("1D-axes").reorderable()`,
  `pc.alphaOnBrushed(0.08)`, `pc.on("brush", fn).on("brushend", fn)`;
  `pc.brushed()` is `false` without a brush, the brushed rows otherwise;
  `pc.brushExtents()` reads `{axis: [lo, hi]}` and takes the same to restore;
  `pc.highlight([row])` / `pc.unhighlight()`; `pc.on("axesreorder", keys => ...)`.
  Rebuild the chart (clear the container, construct again) for any structural
  change; 32 rows take milliseconds.
- The library's canvas layers are `position: absolute` inside the container: give
  the container `position: relative` and an explicit height.
- d3 3.5's `d3.csv(url, cb)` calls `cb(error, rows)`; older 3.x called `cb(rows)`.
  Take `(a, b) => b === undefined ? a : b`.

## Checking a page without a browser at hand

- Cloud login nodes here have **Firefox** (`/usr/bin/firefox`): `firefox --headless
  --no-remote --profile <fresh dir> --screenshot out.png --window-size=1600,1000
  http://localhost:<port>/` renders the page (OSMesa-free; it warns about X and goes
  on). A fresh profile per shot: a shot killed by `timeout` leaves a lock that makes
  the next one say "Firefox is already running".
- The shot is taken at the `load` event, before an XHR-loaded page is complete. The
  page's `?demo=brush|lightbox|dark` loads its CSV synchronously and applies the
  state at once, so those states are deterministic in a screenshot; never load
  synchronously outside that mode.
- Errors in the page's own code are shown in a banner (`#error`): the platform's
  session frame has no console at hand, and a blank page says nothing.
