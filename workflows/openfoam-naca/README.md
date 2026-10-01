# OpenFOAM NACA Airfoil Case

One OpenFOAM case of a NACA 4-digit airfoil: the workflow meshes the shape you
give it (camber, camber position, thickness) with a structured C-grid, solves the
turbulent flow at the chosen angle of attack (`potentialFoam` + `simpleFoam`,
Spalart-Allmaras, Re = 10⁶), reports the lift and drag coefficients, and leaves
the case ready to open in ParaView.

It runs on its own from the platform, and it is the evaluator of
[`workflows/dakota-openfoam`](../dakota-openfoam/), which calls this same YAML
once per design the optimizer proposes.

![From the form or from a loop's params file to params.in and case.sh, then blockMesh, potentialFoam and simpleFoam under the submitter, leaving results.out, exit_code and case.foam in the case directory](thumbnails/case-pipeline.svg)

## Inputs

| Group | Input | Meaning |
|---|---|---|
| `cluster` | `resource`, `scheduler`, `cores_per_case`, `slurm`, `pbs` | where the case runs: the login node, or one SLURM/PBS job of `cores_per_case` MPI ranks (`--nodes=1 --ntasks=N`, PBS `select=1:ncpus=N:mpiprocs=N`) |
| `case` | `max_camber` [0, 0.06], `camber_position` [0.3, 0.6], `thickness` [0.08, 0.18] | the NACA digits as chord fractions (0012, 2412, 4412, …); the box where the mesh generator was validated |
| | `angle_of_attack` | incidence in degrees (default 5) |
| | `mesh_scale` 1–6 | multiplies every cell count; cost grows roughly with the cube (table below) |
| | `case_dir` | where to build and solve; empty = `case/` under the run's job directory |
| | `params_file` | a Dakota-style params file (`<value> <name>` per line): **its values override the form fields of the same name**, fields it does not list keep the form's values |
| `software` | `openfoam_load` | commands that put OpenFOAM on PATH (`module load openfoam/2412`, `source .../etc/bashrc`); empty installs v2412 from conda-forge under `${service_parent_install_dir:-$HOME/pw/software}/openfoam-naca` (~5 min once) |

## What a run leaves

In the case directory (`CASE_DIR` in the log):

```
params.in        the design the case was solved with (file values merged over the form's)
results.out      "<Cd> drag_coefficient" and "<-Cl> neg_lift_coefficient"
exit_code        the simulator's exit status, written even when it failed
run.<job>.out    the streamed log: every OpenFOAM step, one solver progress line per 50 iterations
case/            the OpenFOAM case, final time step included; case/case.foam opens it in ParaView
```

The `results` job publishes `DRAG_COEFFICIENT`, `LIFT_COEFFICIENT` and
`PARAVIEW_FILE` as outputs and fails the run when there is no `results.out`
(a diverged solver), printing the log tails. Reference: NACA 2412 at 5°,
`mesh_scale` 1 gives Cd ≈ 0.0222, Cl ≈ 0.722.

### Opening the case in ParaView

ParaView reads OpenFOAM cases through any `*.foam` file in the case directory.

1. Copy `case/` to the machine running ParaView, for example

   ```bash
   scp -r -i ~/.ssh/pwcli -o ProxyCommand="pw ssh --proxy-command %h" \
       <user>@<resource>:~/pw/jobs/<run-slug>/case/case ./naca-case
   ```

   (`pw ssh configure <resource>` writes an SSH config entry instead; the
   `processor*` directories of a decomposed case can stay behind, the workflow
   reconstructs the last time step).
2. **File → Open** `case.foam`, **Apply**, pick the last time step: `p`, `U`,
   `nut`, `nuTilda`. The case is one cell deep in *z*; look at it from +z.

`case/postProcessing/forceCoeffs1/<time>/coefficient.dat` has Cd and Cl per
iteration.

## Cost, accuracy and parallel runs

Measured on gcpsmall for the reference design, one core:

| `mesh_scale` | cells | time | Cd | Cl |
|---:|---:|---:|---:|---:|
| 1 | 5.4k | ~10 s | 0.0222 | 0.722 |
| 2 | 21.6k | ~1 min | 0.0193 | 0.718 |
| 3 | 48.6k | ~3.5 min | 0.0190 | 0.707 |
| 4 | 86.4k | ~10 min | 0.0194 | 0.698 |
| 6 | 194k | ~35 min | 0.0206 | 0.684 |

The mesh is essentially converged by scale 3–4; scale 1 is the demo setting
(~10% high on drag, nearly thickness-blind). The remaining gap to wind-tunnel
data (Cl ≈ 0.74, Cd ≈ 0.010) is the fully turbulent model, not the mesh, so
treat the coefficients comparatively.

`cores_per_case` > 1 decomposes the mesh into N chordwise strips
(`hierarchical`, deterministic; the conda-forge scotch partitions differently
on every call and tips marginal designs into divergence) and runs the solvers
under `mpirun --bind-to none -np N`. It pays from `mesh_scale` 3–4 (4 ranks:
~1.5 min instead of ~3.5 min at scale 3); at scale 1 it is slower than serial.
The sourced environment may `export MPIRUN="srun --mpi=pmix"` to replace the
launcher.

## As a subworkflow

```yaml
- uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/openfoam-naca/yamls/general.yaml
    cluster: { resource: ..., scheduler: ..., cores_per_case: ..., slurm: {...}, pbs: {...} }
    case:
      params_file: <iter dir>/case_<j>/params.in    # the proposed design
      case_dir: <iter dir>/case_<j>                  # solve it there
      angle_of_attack: 5
      mesh_scale: 1
    software: { openfoam_load: ... }
```

The call leaves `results.out` in `case_dir`, or `exit_code` without it when the
solver failed, which is what an optimizer step reads next. Each call checks out
this app and prepares its environment itself; the installer takes a lock, so
concurrent calls on a cold cluster install once. Worked example:
[`dakota-openfoam/yamls/iteration-naca.yaml`](../dakota-openfoam/yamls/iteration-naca.yaml).

## Files

| `app/` | Role |
|---|---|
| `install-openfoam.sh` | idempotent conda-forge install, the `lib/sys-mpich` link that makes `-parallel` runs load the MPI Pstream, the activation file for `tools/utils/prepare-env.sh` |
| `naca_blockmesh.py` | NACA 4-digit parameters → structured C-grid `blockMeshDict` |
| `openfoam-case/` | the case template: boundary conditions, schemes, solver settings |
| `simulator.sh` | `params.in` → case → `blockMesh` (+ `decomposePar`) → `potentialFoam` → `simpleFoam` → `results.out` → `reconstructPar` + `case.foam`; env contract `MESH_SCALE`, `CORES_PER_CASE`, `OPENFOAM_ENV`, `MPIRUN` |

Shared: `tools/utils/miniforge.sh`, `tools/utils/prepare-env.sh`. Tests:
`tests/general/gcpsmall.json` (login node, serial) and
`tests/general/gcpsmall-slurm-mpi2.json` (one SLURM job, 2 ranks).
