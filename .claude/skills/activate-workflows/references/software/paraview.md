# ParaView (pvpython) for headless rendering on a cluster

> Learned adding the images option to `workflows/openfoam-naca` (2026-10-08): six PNG
> views of a solved OpenFOAM case rendered by `pvpython` on the login node or a
> compute node, with no display and no root. The scripts: `app/install-paraview.sh`,
> `app/render-images.sh`, `app/render-case.py`. `workflows/doe-openfoam` shows the
> images in Design Explorer.

## Which binaries

- **The official Linux tarball from paraview.org, not conda-forge:** one self-contained
  download (`ParaView-<ver>-MPI-Linux-Python3.12-x86_64.tar.gz`, 830 MB, 2.7 GB on
  disk; `https://www.paraview.org/files/v6.1/`), `bin/pvpython` inside, nothing to
  resolve. x86_64 only.
- **Since ParaView 6.0 there is one Linux build and it renders offscreen by itself:**
  with no display it falls back to the bundled OSMesa (`lib/mesa`, "OSMesa not found.
  Fallback to bundled libOSMesa"). The separate 5.13 `-osmesa-` build fails at once on
  a minimal cloud image: `error while loading shared libraries: libglapi.so.0` (a
  system Mesa library that gcpsmall's Rocky 9 image does not have). Verified 6.1.1
  works and 5.13.3-osmesa does not, 2026-10-08.
- Pin the version (`PARAVIEW_VERSION`, default 6.1.1) and let `PARAVIEW_URL` replace
  the whole URL; the Python version in the file name changes between releases, so a
  guessed name for another version 404s with a clear message.
- Idempotence: `bin/pvpython --version`; the install is one directory
  (`<software dir>/openfoam-naca/paraview/ParaView-<ver>`), serialized with `flock`
  because a DOE's cases install concurrently on a cold cluster.

## Making the render actually happen

- **Name the OSMesa window outright:** `VTK_DEFAULT_OPENGL_WINDOW=vtkOSOpenGLRenderWindow`
  with `pvpython --force-offscreen-rendering`. Left to VTK's own choice, a run from a
  detached process on gcpsmall picked EGL (NVIDIA EGL libraries are installed, there is
  no GPU), failed `eglMakeCurrent: 12296` and died with `corrupted double-linked list`,
  while the same command from an interactive shell tried X (`bad X server connection.
  DISPLAY=`) and then fell back to OSMesa fine. The choice depended on something
  outside the command line, so take it away. Fallbacks after that, in order: the
  build's default backend (a site build without OSMesa), then `xvfb-run -a` for a
  build that needs an X server. `--opengl-window-backend OSMesa` is the 6.x command
  line equivalent; the environment variable also works on older builds and is ignored
  where the class does not exist.
- **pvpython can hang on exit after writing every image:** once, the check render of
  the installer wrote its PNG and then sat in `futex_wait` with 16 llvmpipe threads for
  10 minutes; the same script by hand exited in 3 s. The scripts therefore end with
  `os._exit()` after flushing (no interpreter or VTK teardown), the wrapper runs
  `pvpython` under `timeout -k 10 ${RENDER_TIMEOUT:-900}`, and completeness is a file
  written last (`manifest.json`), not the exit status.
- **A render check at install time** (a sphere to a PNG, `env -u DISPLAY`) turns "no
  images in any case" into one failure in preprocessing with pvpython's own output. Keep
  the check behind a marker file so a failed check is retried without re-downloading.
- Prefer `pvpython` over `pvbatch` for a script that needs no MPI: same API, no
  `mpiexec`.

## The paraview.simple API, version to version

- **`Show()` resets the camera on the view's first render unless
  `paraview.simple._DisableFirstRenderCameraReset()` was called first** (every trace
  ParaView records starts with it): a plan-view camera set before the first `Show()`
  was replaced by a reset showing the whole domain. Call it, and set the camera right
  before each `SaveScreenshot`.
- **Color map preset names changed in 6.0:** `Viridis (matplotlib)` → `Viridis`,
  `Inferno (matplotlib)` → `Inferno` (`ApplyPreset` raises `no preset with name`).
  Try the new name then the old one. `Cool to Warm`, `Turbo`, `Jet` are unchanged.
- The OpenFOAM reader (`OpenFOAMReader(FileName=case.foam)`): regions are
  `internalMesh`, `patch/<name>`, `group/<name>`; `CaseType = 'Decomposed Case'`
  reads `processor*` directories when `reconstructPar` left no reconstructed time.
  Extract blocks with `ExtractBlock(Selectors=['/Root/internalMesh'])` /
  `'/Root/boundary/walls'` (5.10+; `BlockIndices` before), `MergeBlocks` for the
  filters. The reader's `TimestepValues` lists the written times; set
  `GetAnimationScene().AnimationTime` and `view.ViewTime` to the last one.
- `ScalarBar.RangeLabelFormat` with a printf format is deprecated in 6.1 ("converted
  to std::format"); leave the default labels.
- 2D case, one cell deep: `view.InteractionMode = '2D'`, parallel projection, camera
  at `z = z_mid + 10`, `CameraParallelScale` = half the height of the box shown, the
  width following the image's aspect ratio. Color ranges from a box `Clip` around the
  airfoil, not the whole domain, or the far field sets the scale. A field spanning
  orders of magnitude (`nut`) wants a log scale over its top decades and an inverted
  map, or the background is one color and the label text invisible.
- Six 1400x875 images of a 5k-200k cell case take 4-10 s all told (2.5 s of it is
  startup).
