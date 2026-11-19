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

## What the stage holds

```
<stage directory>/
├─ study.usda             /World: lights, /World/Designs/<design> references on the grid,
│                         /World/Legend, and the field variant set
├─ designs/<design>.usdc  one per case
├─ textures/<design>/     the three field images and the airfoil's pressure strip
├─ labels/, legend/       design labels and color bars
└─ designs.json           the designs in arrival order, with their parameters and results
```

A design file's `/Design` prim carries the case parameters and coefficients in its
customData and holds four children. `Field` is the solver's mid plane around the
airfoil, with the raw nodal values as primvars (`U`, `p`, `nut`, and the normalized
`velocity`, `pressure` and `turbulence`) and one material per field. `Airfoil` is the
section extruded across the plane and colored by its pressure coefficient.
`Streamlines` are traced from 16 seeds upstream, and `Label` names the airfoil, its
angle and its lift and drag.

The colors use fixed ranges scaled by the freestream (speed over freestream from 0 to
1.6, pressure coefficient from -2.5 to 1, eddy viscosity ratio from 0.1 to 1000 on a
log scale), so designs compare across a study. They are resampled onto 2048 pixel wide
textures and shown as emissive color, because Isaac Sim's RTX renderer ignores
per-vertex color fed to emission. Emission renders on front faces only, so the plane's
faces are wound toward the camera.

To switch the field, select `/World` in the Stage panel and pick the `field` variant
in the Property panel.

## Adding a format

A format is an entry in `FORMATS` in `app/export_usd.py`: a reader from one case
directory to the pieces `write_design` draws (the plane's points, faces, raw fields
and field images, the body outline, the streamlines), plus an option under **Format**
in the form. The OpenFOAM reader is `read_case`. Output that VTK's pip wheel cannot
read needs its reader to run elsewhere; CTH's SpyPlot files, for example, are read by
ParaView's reader, which the wheel does not include.
