# OpenFOAM NACA Airfoil Case

**One OpenFOAM case of a NACA 4-digit airfoil**, as an ACTIVATE workflow: pick the
shape (camber, camber position, thickness) and the incidence, and the workflow
generates a structured C-grid for that design, solves the turbulent flow with
`potentialFoam` + `simpleFoam` (serially, or decomposed under `mpirun`), reports
the lift and drag coefficients, and leaves the solved case ready to open in
ParaView.

It runs by itself from the platform, and it is also the **evaluator** of
[`workflows/dakota-openfoam`](../dakota-openfoam/): that optimization loop calls
this same YAML once per design Dakota proposes, handing it the design as a file
and a case directory to solve in ([below](#as-a-subworkflow-of-an-optimization-loop)).

## The case

Turbulent flow (Re = 10⁶, Spalart-Allmaras) over the airfoil at the chosen angle
of attack on a structured C-grid generated per design, solved with
`potentialFoam` + `simpleFoam` in ~10 s at the default mesh (~5k cells). The
airfoil stays axis-aligned; the incidence lives in the far-field velocity and in
the lift and drag directions of the `forceCoeffs` function object.

| Form input (`case` group) | Meaning |
|---|---|
| `max_camber` ∈ [0, 0.06] | first NACA digit / 100 (0 = symmetric) |
| `camber_position` ∈ [0.3, 0.6] | second digit / 10 |
| `thickness` ∈ [0.08, 0.18] | last two digits / 100 |
| `angle_of_attack` ∈ [-5, 12] degrees | incidence (default 5) |
| `mesh_scale` 1–6 | the cost dial: multiplies every cell count (table below) |
| `case_dir` | where the case is built and solved (empty: `case/` under the run's job directory) |
| `params_file` | a Dakota-style params file to take the design from instead of the fields above |

The box of the three shape variables is the classic 4-digit family (0012, 2412,
4412, …) and the range where the mesh generator was validated at every corner;
higher forward camber breaks the C-grid quality.

### What a run leaves behind

In the case directory (printed in the log as `CASE_DIR`):

```
params.in            the design, one "<value> <name>" line per variable
case.sh              the script the submitter ran (environment + simulator.sh)
run.<job>.out        everything the case printed
results.out          "<Cd> drag_coefficient" and "<-Cl> neg_lift_coefficient"
exit_code            the simulator's exit status (written even when it failed)
case/                the OpenFOAM case: 0/, constant/, system/, the final time
                     directory, postProcessing/forceCoeffs1/, log.<step> files
case/case.foam       empty marker file: open it in ParaView
```

The `results` job publishes `DRAG_COEFFICIENT`, `LIFT_COEFFICIENT`,
`RESULTS_FILE` and `PARAVIEW_FILE` as outputs and fails the run when the solver
left no `results.out` (its log tails are printed). Cd and Cl are the average of
the last 20% of iterations of the `forceCoeffs` output; at the default mesh the
reference design (NACA 2412 at 5°) gives Cd ≈ 0.0222, Cl ≈ 0.722.

### Opening the case in ParaView

ParaView reads OpenFOAM cases natively through any `*.foam` file in the case
directory, which is why the workflow leaves `case/case.foam` there. To look at
the result:

1. Copy the case directory to the machine running ParaView. Through the platform
   this is one `scp` with the `pw` CLI as the proxy (`pw ssh --help` shows the
   variants; `pw ssh configure <resource>` writes an SSH config entry instead):

   ```bash
   scp -r -i ~/.ssh/pwcli -o ProxyCommand="pw ssh --proxy-command %h" \
       <user>@<resource>:~/pw/jobs/<run-slug>/case ./naca-case
   ```

   Only `case/` is needed: `0/`, `constant/`, `system/`, the final time
   directory and `case.foam`. The `processor*` directories of a decomposed case
   can stay behind: the workflow runs `reconstructPar` on the last time step, so
   the reconstructed fields are in the case root.

2. In ParaView: **File → Open**, pick `case.foam`, click **Apply**. Choose the
   last time step in the toolbar; `p`, `U`, `nut` and `nuTilda` are available as
   cell and point fields. The *Case Type* property stays *Reconstructed Case*
   (switch to *Decomposed Case* only if you copied the `processor*` directories
   of a case whose reconstruction failed, which the log reports as a warning).

The 2D case is one cell deep in *z*; slice it or just look at it from the +z
axis. `postProcessing/forceCoeffs1/<time>/coefficient.dat` has Cd and Cl per
iteration for plotting convergence.

### Mesh fidelity: cost and accuracy

Measured on one gcpsmall core for the reference design (NACA 2412 at α = 5°):

| `mesh_scale` | cells | time per case | Cd | Cl |
|---:|---:|---:|---:|---:|
| 1 | 5.4k | ~10 s | 0.0222 | 0.722 |
| 2 | 21.6k | ~1 min | 0.0193 | 0.718 |
| 3 | 48.6k | ~3.5 min | 0.0190 | 0.707 |
| 4 | 86.4k | ~10 min | 0.0194 | 0.698 |
| 6 | 194k | ~35 min | 0.0206 | 0.684 |

Discretization is essentially converged by scale 3–4 (Cl within ~2%, Cd within
~6% of the scale-6 values). Scale 1 is the demo setting: ~10% high on drag and
nearly thickness-blind (friction-dominated), but fast enough to watch a case
end-to-end. The remaining gap to wind-tunnel data for this airfoil (Cl ≈ 0.74,
Cd ≈ 0.010) is model error, not mesh: fully-turbulent Spalart-Allmaras with wall
functions resolves no laminar-turbulent transition, which roughly doubles the
absolute drag at this Reynolds number. Treat the coefficients comparatively,
which is all an optimizer needs.

### Cores per case: when MPI pays off

`cores_per_case` = N > 1 makes `simulator.sh` write a `decomposeParDict` that
cuts the mesh into N strips along the chord (`hierarchical`, `n (N 1 1)`),
`decomposePar` it, run `potentialFoam` and `simpleFoam` as
`mpirun --bind-to none -np N <solver> -parallel`, and `reconstructPar` the last
time step (the `forceCoeffs` output lands in `case/postProcessing` from the
master rank, so the objectives never need the reconstruction; ParaView does).
Measured on gcpsmall's login node, same reference design:

| `mesh_scale` | cells | 1 core | 2 ranks | 4 ranks |
|---:|---:|---:|---:|---:|
| 1 | 5.4k | 6.5 s | 5.9 s | 13 s |
| 2 | 21.6k | ~1 min | — | 24 s |

At the default mesh decomposition buys nothing, so the default stays 1. Two to
four ranks start paying from `mesh_scale` 3–4 (~15k+ cells per rank), and the
ranks' answers agree with the serial ones to within 0.5% on Cd and 0.05% on Cl.
`--bind-to none` matters when several cases share a login node: bound to cores,
their launchers would all pin their ranks to the same first cores.

Why strips and not scotch: the conda-forge scotch partitions this mesh
differently on every `decomposePar` call, and the SIMPLE loop on the C-grid is
marginal enough at the default mesh that a design then converges or diverges by
the draw. Strips are deterministic and converged for every design tried.
`export DECOMP_METHOD=scotch` in the OpenFOAM environment commands restores the
graph partitioner.

Where the ranks run: on the login node (**Schedule the Case?** off) they share
the node; scheduled, the case job asks for `--nodes=1 --ntasks=N` (PBS:
`-l select=1:ncpus=N:mpiprocs=N`), placed *ahead* of the form's directives so a
repeated option typed there wins. One node per case because `mpirun` launches
its ranks locally. The launcher is `mpirun` from whatever OpenFOAM environment is
active; the environment commands may `export MPIRUN="srun --mpi=pmix"` (or any
prefix) to replace it.

### Watching a case run

The run's streamed log (`run.*.out`, the submitter's output) shows every OpenFOAM
step: the short ones (`blockMesh`, `decomposePar`, `potentialFoam`,
`reconstructPar`) in full, and for `simpleFoam` one progress line every 50
iterations — iteration, pressure residual, current Cd and Cl — plus the solver
header, its convergence or crash messages, and the final averaged coefficients.
The complete solver log stays in `case/log.simpleFoam`; `export STREAM_EVERY=0`
in the environment commands streams it whole.

### Using a preinstalled OpenFOAM

By default preprocessing installs OpenFOAM v2412 from conda-forge (no sudo,
~5 min once) under `${service_parent_install_dir:-$HOME/pw/software}/openfoam-naca`.
On a cluster that already provides it, fill in **Software Environment →
OpenFOAM environment commands** with `module load openfoam/2412` or
`source /opt/openfoam2412/etc/bashrc`. `tools/utils/prepare-env.sh` turns the
snippet into one sourceable file (`openfoam-env.sh` in the job directory),
prefixed with an initialization of `module` for non-login shells, sources it in
a fresh shell and checks the tools resolve (`blockMesh`, `potentialFoam`,
`simpleFoam`, plus `decomposePar`, `reconstructPar` and the MPI launcher when
`cores_per_case` > 1), so a snippet that does not deliver fails preprocessing
with the shell's own error rather than the solver. Left empty, the same file
activates the conda env instead. The case sources that file wherever it runs
(shared home).

The conda-forge `openfoam=2412` build needs one repair for `-parallel` runs: it
ships its MPI Pstream under `lib/mpich-3.3` while the binaries' rpath (and
`FOAM_MPI`) name `lib/sys-mpich`, so without help every parallel solver loads the
dummy Pstream and aborts. `install-openfoam.sh` links the expected name to the
real directory on every run.

## As a subworkflow of an optimization loop

An optimizer that proposes designs as Dakota-style case directories (one
`params.in` per design, as [`workflows/dakota`](../dakota/) does) evaluates each
of them with one call of this YAML:

```yaml
- uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/openfoam-naca/yamls/general.yaml
    cluster:
      resource: ${{ inputs.resource }}
      scheduler: ${{ inputs.scheduler }}
      cores_per_case: ${{ inputs.cores_per_case }}
      slurm: { ... }
      pbs: { ... }
    case:
      params_file: <iter dir>/case_<j>/params.in   # the design, instead of the fields
      case_dir: <iter dir>/case_<j>                 # solve it there
      angle_of_attack: 5
      mesh_scale: ${{ inputs.mesh_scale }}
    software:
      openfoam_load: ${{ inputs.openfoam_load }}
```

`params_file` must carry `max_camber`, `camber_position` and `thickness` lines
(the names of the problem's design variables); the workflow copies it into the
case directory as `params.in` when it is not already there, and the three shape
fields of the form are hidden and ignored. The angle of attack is a case
setting, not a design variable, so it still comes from `case.angle_of_attack`;
an `angle_of_attack` line in the params file overrides it, for a study that
treats the incidence as a fourth variable. What the call leaves
in `case_dir` is the evaluator's side of the loop's file contract: `results.out`
with the two objectives (`drag_coefficient`, `neg_lift_coefficient`, both to be
minimized), or no `results.out` and an `exit_code` file when the solver failed —
a marginal design diverging is a result the optimizer must see, not an outage.
The call itself fails in that case (its `results` job exits 1), which the
calling matrix tolerates with `fail-fast: false`.

Each call checks out this app and prepares its environment on its own, so the
first cold call installs OpenFOAM while its siblings wait on the installer's lock
and then find it ready. [`workflows/dakota-openfoam/yamls/iteration-naca.yaml`](../dakota-openfoam/yamls/iteration-naca.yaml)
is the worked example.

## What's in `app/`

| File | Role |
|---|---|
| `install-openfoam.sh` | Idempotent OpenFOAM install (conda-forge `openfoam=2412`, no sudo) into `${service_parent_install_dir:-$HOME/pw/software}/openfoam-naca/miniforge`, the `lib/sys-mpich` link that makes `-parallel` runs load the MPI Pstream, and the activation file `tools/utils/prepare-env.sh` asks for; serialized with a lock so concurrent callers share one install |
| `naca_blockmesh.py` | Parametric structured C-grid: NACA 4-digit parameters → `blockMeshDict` (validated at every corner of the design box) |
| `openfoam-case/` | The versioned case template (BC files, schemes, solution settings — everything that does not depend on the design point), so the numerics are pinned by this repo, not by whatever the installed OpenFOAM ships |
| `simulator.sh` | Per-case OpenFOAM driver: `params.in` → `openfoam-case` copy + generated `blockMeshDict`/`0/U`/`controlDict` (+ `decomposeParDict`) → `blockMesh` (+ `decomposePar`) + `potentialFoam` + `simpleFoam`, serial or under `mpirun` → `results.out` (atomic write, or exit non-zero leaving none) → `reconstructPar` + `case.foam` for ParaView. Its environment contract, set by the `case.sh` preprocessing writes: `ALPHA_DEG`, `MESH_SCALE`, `CORES_PER_CASE`, `OPENFOAM_ENV` (the file to source), and `MPIRUN` (launcher prefix, from the sourced environment) |

Shared with the other conda-installing workflows: `tools/utils/miniforge.sh`
(Miniforge bootstrap, per-prefix lock, activation file) and
`tools/utils/prepare-env.sh` (form snippet or installer → one sourceable file,
verified).

## Running it

Pick the compute resource, type the design (the defaults are NACA 2412 at 5°),
and leave **Schedule the Case?** off to solve on the login node — or on to give
the case its own SLURM/PBS job sized by **Cores per case**. The first run installs
OpenFOAM (~5 min) unless **Software Environment** points at a site install. The
run succeeds once `results.out` exists; the coefficients are in the `results`
job's log and outputs, and the case is under the run's job directory
(`~/pw/jobs/<run-slug>/case/`) on the cluster.

Tests: `tests/general/gcpsmall.json` (login node, serial, the reference design)
and `tests/general/gcpsmall-slurm-mpi2.json` (one SLURM job of 2 ranks, NACA
4412); run them with `python3 tools/tests/run-workflow-test.py <test.json>`.
