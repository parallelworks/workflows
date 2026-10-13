# Design Explorer (parallel coordinates for a design study)

> Learned building `workflows/doe-openfoam` (2026-10-08): the study page is the
> app's own `design-explorer.html` over the libraries of Thornton Tomasetti's
> [Design Explorer](https://github.com/tt-acm/DesignExplorer) (d3 v3.5 and its
> build of `d3.parcoords`), downloaded once per cluster at a pinned commit by
> `app/install-design-explorer.sh` and served by `app/design-explorer-server.py`.
> Since 2026-10-08 the page is its own workflow, `workflows/design-explorer` (the
> `app/` paths below are its own), which `doe-openfoam` and `dakota-openfoam` call
> as a subworkflow with the study directory; it serves any such directory standalone.
> Since 2026-10-11 the page draws everything itself: the libraries, their
> download and `install-design-explorer.sh` are gone (below).

## One server, two study layouts

- Nothing in the reader is specific to the airfoil: every `results.out` value is
  an `out:` axis, every file of `images/` (a picture, or a gif/mp4/webm animation) an image kind, and the Pareto flag uses the
  `results.out` values as minimized objectives (Dakota's convention).
  openfoam-naca's `drag_coefficient` and `neg_lift_coefficient` are the one special
  case, shown as Cd, Cl and Cl/Cd; its six images come first in its order.

- `app/study.py` reads `DIR/case_<j>/` (a DOE's `cases/`) and `DIR/iter_<N>/case_<j>/`
  (a Dakota `state/`) with one glob; a case id is its path relative to DIR, so
  image paths and the server's `/data/<id>/images/...` route work for both.
- A Dakota study adds `in:generation` (an input, so it gets a slider) and
  `out:pareto_front` (computed from the solved cases, so it is current before
  Dakota ingests them); the page colors and sorts by generation by default.
- **"Final" differs**: a DOE is final when no case is pending; between two Dakota
  generations no case is pending either, so an optimization is final only when
  `state/status` says CONVERGED or FAILED. `status.json` carries `final` and
  `state`, and the page polls until `final`, then for as long as `quiet`
  (seconds since any case last wrote a file) is under 180: openfoam-naca
  writes results.out, then exit_code, then renders, so a DOE is final while
  its last case still renders. `media` (images listed) is part of the poll's
  reload key with `ok`; a solved count alone misses images landing later.
- Images are listed only once unwritten for `SETTLE` (3 s) and served with
  `no-cache` + ETag, never `max-age`: a card that fetched a half-written PNG
  under max-age kept it for the hour. Cards are reused by case id, so the
  reuse checks the image path too (a reused card kept the placeholder).
- Read cases from the directories, not from Dakota's `evaluations.csv`: the
  optimizer appends to it only at the next generation's ingest, a generation late.
- A variable that never changes (the loop's angle of attack) is a flat axis: the
  page hides it until the user shows it, decided again on every reload.

## Why a page of our own (and, since 2026-10-11, no Design Explorer code)

- The upstream page (`index.html`, 3000 lines) carries its own chrome (Get Data,
  My Static Link, Tutorial, Services, the copyright strip), loads a Google Drive or
  "server folder" through `?ID=<base64 of the folder URL>` and shows the thumbnails as
  circles under a scatter matrix. It works behind an endpoint (verified through the
  platform, `?ID=ZGF0YS8=` for the relative folder `data/`), but it does not look like
  the platform and every non-`in:`/`out:`/`img:` column becomes an axis (`case`).
- The app's page keeps the data format (`in:` inputs, `out:` outputs, `img:` media
  paths, so `data.csv` still loads in the upstream page) and, since 2026-10-11, draws
  the parallel coordinates itself (canvas lines, SVG axes and brushes, no library):
  d3.parcoords could not keep the axes still while filtering, hide the unselected
  lines, or pick a line under the pointer. Nothing is downloaded any more, so the
  login node needs no internet; the server keeps an optional `--design-explorer`
  (serve files from a tree) for a page that still loads them.
- Filtering runs in stages: excluded cases are gone (the axes rescale: Keep only,
  Exclude), chart brushes select, sidebar sliders act inside the brushed set. Axis
  domains and the color scale span the non-excluded / all cases, so brushing never
  rescales an axis or repaints a kept line.
- Sliders follow Design Explorer's own behavior (and the fixes of
  github.com/mattshax/design_tools' patched index.html), as "Pick case": one thumb
  per input at the selected case, its steps the values the brushed cases take (40
  bins for a continuous variable), a drag selects the brushed case at that step
  nearest the current one in the other inputs, the dragged thumb stays under the
  pointer while the others follow. "Filter" turns them into ranges.

## The Pareto view and the retired pareto-server.py (2026-10-11)

- `study.summary()` adds `optimization` to `status.json` for a Dakota state
  directory: the `problem.json` objectives mapped to `data.csv` columns with a
  sense (`neg_X` with an `out:X` column is X maximized: openfoam-naca's lift), the
  variable bounds, and `state.json`'s `hv_history`. The page computes the front as
  of every generation itself (one sort and sweep per generation, two objectives).
- The generation scrubber is a brush on `in:generation` ([gMin, g], or [g, g] for
  one generation), so the chart, the sliders and the lists follow it for free.
- This replaced `workflows/dakota/app/pareto-server.py` and the second endpoint of
  dakota-openfoam: it calls design-explorer unconditionally and serves one page.

## Canvas performance: the hairline cliff

- Chrome/Skia strokes a path **wider than one device pixel** through the general
  stroker; a batched path of thousands of translucent lines then costs seconds per
  frame (measured: 3000 rows x 11 axes, 50 ms at width 1, 2400 ms at 1.15, on CPU or
  emulated GPU). Draw dense line sets at `lineWidth = 1 / devicePixelRatio` (one
  device pixel, crisp on HiDPI) and give width only to a few hundred lines, each its
  own stroke. Round joins cost several times more as well; use bevel.
- The cost hides from JavaScript timing: canvas draws are recorded and rasterized at
  commit, so a trace shows `Commit` / `CanvasResourceProviderSharedImage::
  ProduceCanvasResource` growing with the number of lines while JS stays at a few ms.
  A benchmark that calls `getImageData` forces a CPU canvas and hides the problem.
- In a headless trace, compare against a frame with no change: profile with
  `page.tracing` (categories `toplevel,cc,blink,devtools.timeline`) and aggregate
  `X` events by name.

## Checking a page without a browser at hand

- Cloud login nodes here have **Firefox** (`/usr/bin/firefox`): `firefox --headless
  --no-remote --profile <fresh dir> --screenshot out.png --window-size=1600,1000
  http://localhost:<port>/` renders the page (OSMesa-free; it warns about X and goes
  on). A fresh profile per shot: a shot killed by `timeout` leaves a lock that makes
  the next one say "Firefox is already running".
- The shot is taken at the `load` event, before an XHR-loaded page is complete. The
  page's `?demo=` mode loads its CSV synchronously and applies states joined by `+`
  (`brush`, `front`, `drill`, `case`, `lightbox`, `fade`, `table`, `sens`, `filter`,
  `dark`), so those states are deterministic in a screenshot; never load
  synchronously outside that mode. For interactions, puppeteer-core driving
  `/usr/bin/google-chrome` works where Chrome is installed.
- Errors in the page's own code are shown in a banner (`#error`): the platform's
  session frame has no console at hand, and a blank page says nothing.
