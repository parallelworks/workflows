# OpenFOAM Planar Expansion Case

One OpenFOAM case of the laminar planar-expansion problem: the workflow meshes
the lower-wall transition you give it (length, top and bottom rounding — or the
sharp backward-facing step), solves the steady laminar flow at the chosen
Reynolds number with `simpleFoam`, reports the total-pressure loss coefficient
K between two fixed planes plus the separation and reattachment diagnostics,
and leaves the case ready to open in ParaView.

It runs on its own from the platform, and it is the per-design evaluator of
the expansion design study: a driver workflow (doe-openfoam-expansion,
dakota-openfoam-expansion) calls this same YAML once per design it proposes.
The study context, the validation history and the audit trail live in the
study notes; the case definition (geometry, objective, validation) is the
study's spec.

## The problem

A 2D channel of height h expands to 2h through a lower-wall transition of
length l: either the cubic Bezier of the spec (control points at `a·l` and
`(1-b)·l`, level tangents at both ends, `a = b = 0` the straight ramp) or the
sharp vertical step. The inflow is the exact parabolic profile (bulk velocity
U_b = 1, peak 1.5 U_b), Re = U_b·2h/ν, and the objective is

    K = (p0_in - p0_out) / (0.5 U_b²)

flux-weighted total pressure p0 = p + ½|U|² on the fixed planes x = -2h
(`plane_in`) and x = 40h (`plane_out`). Every design is charged the same
channel length, so K is comparable across designs — but only at these planes:
the outlet plane position moves K by ~0.02 per h of extra channel (measured;
see the sensitivity table below), never compare K between runs with different
planes. All lengths are in units of h; the mesh is structured blockMesh, one
cell deep, with the loss planes as exact face zones (topoSet).

Diagnostics (interpretation only, from the sign of the streamwise wall shear,
sampled on both walls): separation and reattachment points of the lower-wall
bubble, the minimum streamwise wall shear (negated as `neg_min_wall_shear`,
the margin above reversed flow — the stage-2 constrained objective), the
upper-wall eddy extent and the recirculation area (cells with U_x < 0).

## Inputs

| Group | Input | Meaning |
|---|---|---|
| `cluster` | `resource`, `scheduler`, `slurm`, `pbs` | where the case runs: the login node, or one SLURM/PBS job (the case solves serially, `--ntasks=1`) |
| `case` | `transition_length` [0.5, 10], `top_rounding` [0, 0.9], `bottom_rounding` [0, 0.9] | the wall design (see the problem, above) |
| | `sharp_step` | the vertical step instead of the contoured wall: the baseline and the Gartling validation geometry |
| | `reynolds` (default 300) | Re = U_b·2h/ν; 2D below ~400, 800 is the Gartling benchmark |
| | `inlet_length` (5), `outlet_length` (60) | channel lengths in h; `inlet_length` 0 puts the inflow on the step lip (Gartling) |
| | `plane_in` (-2), `plane_out` (40) | the fixed loss planes; K is defined only at these |
| | `mesh_scale` 1–6 | multiplies every cell count (~13k cells at 1 for the default ramp); the cost dial |
| | `case_dir` | where to build and solve; empty = `case/` under the run's job directory |
| | `params_file` | a Dakota-style params file (`<value> <name>` per line): **its values override the form fields of the same name**, fields it does not list keep the form's values ([Design names](#design-names)) |
| `software` | `openfoam_load` | commands that put OpenFOAM on PATH (`module load openfoam/2412`, `source .../etc/bashrc`); empty installs v2412 from conda-forge under `${service_parent_install_dir:-$HOME/pw/software}/openfoam-expansion` (~5 min once) |

The case template is laminar (`simulationType laminar`, `transportModel
Newtonian`, ν = 2/Re written per run) with the `p` 0.3 field relaxation the
Re 800 validation needs. The v2412 traps the template and simulator already
carry: the surfaces function objects need `patches (name);` sub-dicts, the
loss planes are selected with topoSet `boxToFace` (blockMesh cannot take
faceZones), and `simpleFoam` is the solver entry (no `foamRun`).

## Design names

The case reads its design by name. `app/design-parameters.txt` lists the three
names. They are also `case` fields of the form and the design lines of a
`params.in`:

| Name | Form field | Default | Meaning |
|---|---|---|---|
| `transition_length` | Transition length l/h | 2 | length of the wall transition in h |
| `top_rounding` | Top rounding a | 0 | level run before the drop (corner rounding) |
| `bottom_rounding` | Bottom rounding b | 0 | gentleness of the landing on the outlet floor |

The other `case` fields are run settings, not design names. They come from the
form only: a params file with a `reynolds` or `mesh_scale` line fails the case,
like any other name not in the list — so every design of a study is solved
with the same planes, mesh scale and Reynolds number.

The **Create the Case** step writes the case's `params.in`. With **Design from
a params file**, it builds it from the file and the form:

- A name the file lists overrides the form field of that name.
- A name the file leaves out keeps the form's value.
- Any other name, or a value that is not a number, fails the case before
  anything runs.

## What a run leaves

In the case directory (`CASE_DIR` in the log):

```
params.in        the design and run settings the case was solved with (file values merged over the form's)
results.out      "<K> loss_coefficient" first, then the diagnostics by label
exit_code        the simulator's exit status, written even when it failed
run.<job>.out    the streamed log
case/            the OpenFOAM case, final time step included; case/case.foam opens it in ParaView
```

The `results` job publishes `LOSS_COEFFICIENT` (absent for the Gartling
placement, which has no inlet loss plane), `REATTACHMENT_POINT`,
`RECIRCULATION_AREA`, `RESULTS_FILE` and `PARAVIEW_FILE`, and fails the run
when there is no `results.out` (a diverged solver), printing the log tails.

## Validation and cost

Sharp step, inflow on the step lip (Gartling 1990, Re 800, expansion ratio 2;
Gartling: lower-wall reattachment 6.10 H = 12.2 h, upper-wall eddy 4.85–10.48
H = 9.7–20.96 h, H = 2h):

| mesh | cells | reattach | upper eddy | vs Gartling |
|---|---:|---:|---|---|
| scale 1 | 9.2k | 5.92 H | 4.75–10.25 H | -3.0% / -2% |
| scale 3 | 83k | 5.92 H | 4.69–10.47 H | -3.0% / eddy nearly exact |

The identical reattachment number at both scales is quantization, not mesh
invariance: the reported point is the last wall face centre with reversed
shear, both meshes have a face centre exactly at 71/6 h, and the sign change
falls after it on both. Audit values for every row (flux in/out balanced
against U_b·h = 1, peak |U| = 1.5 U_b on the inlet centreline) are in the
study notes.

Measured on one core (study notes, gcpsmall): ~1–2 min per case at
`mesh_scale` 1, >10 min at 3.

Plane sensitivity (sharp step, Re 300, scale 1, K at the default planes
1.5363): inlet length 5→10 moves K +0.65%; the outlet plane at 60/75 gives
K = 1.9378 / 2.2394 (+26% / +46%) — the extra channel is charged real
friction (~0.020 K per h), which is why the planes stay fixed for all designs.

## As a subworkflow

```yaml
- uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/openfoam-expansion/yamls/general.yaml
    cluster: { resource: ..., scheduler: ..., slurm: {...}, pbs: {...} }
    case:
      params_file: <case dir>/params.in    # the proposed design (3 names)
      case_dir: <case dir>                 # solve it there
      reynolds: 300
      mesh_scale: 1
    software: { openfoam_load: ... }
```

The call leaves `results.out` in `case_dir`, or `exit_code` without it when
the solver failed, which is what a driver reads next. Each call checks out
this app and prepares its environment itself; the installer takes a lock, so
concurrent calls on a cold cluster install once.

## Files

| `app/` | Role |
|---|---|
| `design-parameters.txt` | the three design names this runner reads from `params.in`; Create the Case checks a params file against it |
| `install-openfoam.sh` | idempotent conda-forge install and the activation file for `tools/utils/prepare-env.sh` |
| `expansion_blockmesh.py` | the wall design → structured `blockMeshDict` (Bezier ramp or sharp step), plus the topoSetDict of the loss planes and the inlet face centres for the exact parabolic profile |
| `openfoam-case/` | the case template: boundary conditions, schemes, solver settings (laminar, `p` 0.3) |
| `simulator.sh` | `params.in` → case → `blockMesh` → `topoSet` → `simpleFoam` → `results.out` + `case.foam`; env contract `PARAMS`, `CASE_DIR`, `MESH_SCALE`, `OPENFOAM_ENV` |

Shared: `tools/utils/miniforge.sh`, `tools/utils/prepare-env.sh`,
`tools/utils/check-params.sh` (checks a params file against
`design-parameters.txt`).
