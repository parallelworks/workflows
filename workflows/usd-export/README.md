# USD export: simulation results as an OpenUSD stage for Omniverse

Turns the solved cases of a study into an OpenUSD stage that the
[omniverse desktop](../omniverse/README-desktop.md) opens and keeps current. Each case
becomes a design file, and `study.usda` places every design on a grid with a legend
and a `field` variant set that switches every design between velocity, pressure and
eddy viscosity. The first format reads the OpenFOAM airfoil cases that
[openfoam-naca](../openfoam-naca/README.md),
[doe-openfoam](../doe-openfoam/README.md) and
[dakota-openfoam](../dakota-openfoam/README.md) leave on disk.

```
doe-openfoam, dakota-openfoam ──► case directories ──► usd-export ──► stage directory ──► omniverse desktop
(solve the designs)               params.in,           (this one)     study.usda,         Stage to follow
                                  results.out, case/                  designs/
```

The workflows share only files. The export reads the case directories and writes the
stage directory, and the desktop reads the stage directory, so neither driver knows
about the export and the export can run after a study or alongside it.

## Form

| Field | Default | Notes |
|---|---|---|
| Results directory | none | one case, or a directory of cases, searched four levels down |
| Format | OpenFOAM airfoil cases | the only format so far |
| Keep exporting new cases for | 0 minutes | 0 exports what has solved and ends |
| Stage directory | `${HOME}/pw/omniverse/stages/study` | give the same directory to the desktop |
| Designs per row | 4 | |
| Animated flow design | best | the design `flow.usda` animates: best lift to drag, a design name, or none |
| Software | install under `${HOME}/pw/software` | or commands that load a Python with usd-core 25.11, vtk, numpy and pillow |

The batch job runs on the login node or as a SLURM or PBS job. The first run installs
the exporter's Python (OpenUSD 25.11, the release Isaac Sim 6.2 reads, with VTK, NumPy
and Pillow) in about two minutes; an export then takes about two seconds per case at
`mesh_scale` 2.

## Where a study's cases are

| Driver | Results directory | Design names |
|---|---|---|
| openfoam-naca | the case directory | the directory's name |
| doe-openfoam | `~/pw/jobs/<run>/cases` | `case_3` |
| dakota-openfoam | `~/pw/jobs/<run>/state` | `iter_2_case_3` |

Design names are the case paths relative to the results directory. A DOE and an
optimization can therefore fill one stage side by side. Two DOE runs into one stage
share the names `case_1` to `case_N` and replace each other's designs, so give each
its own stage directory. A design keeps its grid slot when it is exported again.

## Following a study while it runs

With **Keep exporting new cases for** above 0, the export keeps scanning the results
directory and exports each case as its `results.out` appears; a case the solver failed
(an `exit_code` without `results.out`) is skipped. It ends when no case has finished
for that many minutes, or, for a doe-openfoam study, once `results.csv` exists and
every case has finished. A dakota-openfoam study ends on the idle time, so set it
longer than one generation takes. Each design file and the study are written to a
temporary file and renamed into place, so a desktop reloading them never reads a
partial file.

Images are named by their content (`velocity-<hash>.png`), and a design exported
again with different images gets new files while the old ones are removed. When the
images were rewritten in place under the same names, an open Isaac Sim showed one
wrong image on every design after the reload; new names avoid that.

## What the stage holds

```
<stage directory>/
├─ study.usda             /World: lights, /World/Designs/<design> references on the grid,
│                         /World/Legend, and the field variant set
├─ designs/<design>.usdc  one per case
├─ textures/<design>/     the three field images and the airfoil's pressure strip, as
│                         <name>-<hash>.png
├─ labels/, legend/       design labels and color bars, named the same way
├─ flow.usda, flow/       the animated flow of one design (below)
└─ designs.json           the designs in arrival order, with their parameters and results
```

A design file's `/Design` prim carries the case parameters and coefficients in its
customData and holds four children. `Field` is the solver's mid plane around the
airfoil, with the raw nodal values as primvars (`U`, `p`, `nut`, and the normalized
`velocity`, `pressure` and `turbulence`) and one material per field. `Airfoil` is the
section extruded across the plane and colored by its pressure coefficient.
`Streamlines` are traced from 16 seeds upstream, and `Label` names the airfoil, its
angle and its lift and drag.

The colors use fixed ranges scaled by the freestream, so designs compare across a
study: speed over freestream from 0 to 1.6; pressure coefficient from -2.5 to 1, with
0 (the freestream) at the neutral middle of the diverging map; eddy viscosity ratio
from 0.1 to 1000 on a log scale. They are resampled onto 2048 pixel wide textures and
shown as emissive color, because Isaac Sim's RTX renderer ignores per-vertex color fed
to emission. Emission renders on front faces only, so the plane's faces are wound
toward +z, the side the desktop's camera looks from.

To switch the field, select `/World` in the Stage panel and pick the `field` variant
in the Property panel.

The stage directory outlives the run, and later exports add to it. The run leaves no
process or endpoint behind. Remove a study with `rm -rf <stage directory>`; the
exporter's Python stays under `<install directory>/usd-export` for later runs.

A run fails when a solved case cannot be exported (its warning names the case and the
error), even though the other cases were exported, and when the results directory
holds no solved case and the stage is still empty.

## The animated flow

`flow.usda` shows one design's flow in 3D: the airfoil as a wing section from a wall to
a free tip, colored by its pressure coefficient; streamtubes colored by speed over
freestream at two span stations; and tracer particles at three stations (about 700 in
view at a time) that ride the solved velocity field along the streamlines in an 8
second loop, colored by their local speed.
The wall behind the wing carries the design's label and the three legends, and a `wall`
variant set on `/World` puts the velocity, pressure or eddy viscosity slice on it
(dark by default). The scene is Y up, lift up and span along z.

The openfoam-naca cases are two-dimensional, one cell across the span, so every span
station sees the same flow; the tubes and particles are the mid-plane solution placed
at several stations, and the wing's span is for viewing. A particle moves at the local
solved speed, scaled so one chord at freestream takes 1.2 seconds, and particles are
released along each streamline at fixed intervals so the loop has no seam.

The stage holds 192 frames at 24 frames a second as time samples of a point instancer:
positions, a color band per particle, and the particles that are past the end of their
line. Isaac Sim's RTX renderer draws a `Points` prim's spheres with texture coordinates
of its own and ignores a per-point color, so each of 16 color bands is a prototype
sphere with its own material. The tubes and particles carry Omniverse's
`doNotCastShadows` primvar.

With **Animated flow design** at best, the export writes `flow.usda` for the design with
the highest lift to drag ratio and rewrites it when a better one is exported, so in
follow mode it tracks an optimization. Building it takes about one second.
`flow.usda` is small (lights, time range, and the desktop's view and autoplay hints)
and sublayers `flow/<design>-<hash>.usdc`, which holds the geometry and the particle
samples (about 5 MB); the textures beside it are named by content like the study's.
A design whose flow cannot be built is a warning, and the run still succeeds on its
study.

## Adding a format

A format is an entry in `FORMATS` in `app/export_usd.py`: a reader from one case
directory to the pieces `write_design` draws (the plane's points, faces, raw fields
and field images, the body outline, the streamlines), plus an option under **Format**
in the form. The OpenFOAM reader is `read_case`. Output that VTK's pip wheel cannot
read needs its reader to run elsewhere; CTH's SpyPlot files, for example, are read by
ParaView's reader, which the wheel does not include.
