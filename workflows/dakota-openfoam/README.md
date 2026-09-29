# Dakota-OpenFOAM Optimization

**[Dakota](https://dakota.sandia.gov)'s MOGA driving [OpenFOAM](https://www.openfoam.com)
simulations** as an iterative ACTIVATE workflow: each iteration Dakota proposes a
batch of designs, the platform evaluates them as parallel OpenFOAM cases on the
cluster (login node or one scheduler job per case), and the loop repeats until
Dakota converges, the front stagnates, or the budget runs out.

This is the swap that [`tutorials/optimization`](../../tutorials/optimization/)
describes in its last section, made real. The loop mechanics (retry-as-loop,
guarded static matrix, file contract, failure semantics) are the tutorial's —
read its README for the *why* of every piece. This README covers only what changed.

## The example problem

**NACA 4-digit airfoil shape optimization** — the textbook aerodynamic design
problem. Each case is turbulent flow (Re = 10⁶, Spalart-Allmaras) over an airfoil
at 5° incidence on a structured C-grid generated per design, solved with
`potentialFoam` + `simpleFoam` in ~7 s at the default mesh (~5k cells).

| | |
|---|---|
| Design variables | `max_camber` ∈ [0, 0.06] · `camber_position` ∈ [0.3, 0.6] · `thickness` ∈ [0.08, 0.18] (chord fractions; the box covers the classic 4-digit family — 0012, 2412, 4412, …) |
| Objectives (both minimized) | `drag_coefficient` · `neg_lift_coefficient`, from OpenFOAM's `forceCoeffs` function object |
| Cost dial | `mesh_scale` multiplies every cell count (cost grows ~quadratically); the same knob takes the study from seconds-cheap to genuinely expensive |

More camber buys lift but costs drag, thickness costs drag at similar lift: the
loop maps that tradeoff as a Pareto front of airfoil shapes (`state/pareto.csv` +
`state/pareto.svg` in the run's job directory).

## What's in `app/`

| File | Role |
|---|---|
| `install-openfoam.sh` | Idempotent OpenFOAM install (conda-forge `openfoam=2412`, no sudo) into `${service_parent_install_dir:-$HOME/pw/software}/dakota-openfoam/miniforge` |
| `install-dakota.sh` | Idempotent Dakota install (conda-forge `dakota=6.16.0`) into the same prefix |
| `install-common.sh` | Shared Miniforge bootstrap, sourced by both |
| `optimizer.py` | The tutorial's propose-or-stop contract, backed by Dakota (below) |
| `driver.py` | Dakota's fork-interface analysis driver: replay-or-capture |
| `naca_blockmesh.py` | Parametric structured C-grid: NACA 4-digit parameters → `blockMeshDict` (validated at every corner of the design box) |
| `openfoam-case/` | The versioned case template (BC files, schemes, solution settings — everything that does not depend on the design point), so the numerics are pinned by this repo, not by whatever the installed OpenFOAM ships |
| `simulator.sh` | Per-case OpenFOAM driver: `params.in` → `openfoam-case` copy + generated `blockMeshDict`/`0/U`/`controlDict` → `blockMesh` + `potentialFoam` + `simpleFoam` → `results.out` (the `potentialFoam` initialization is required: an impulsive uniform start diverges) |

## How Dakota fits the iteration contract

Dakota drives evaluations itself and has no "emit a batch and exit" mode for
optimization methods, so `optimizer.py` uses Dakota's documented crash-recovery
semantics as the pause button:

1. Every call resumes the study with `dakota -read_restart state/dakota/dakota.rst`
   and a fixed seed, so the method deterministically replays to where it stopped.
2. Points the platform evaluated meanwhile are fed back by `driver.py` from
   `state/results_db/` (keyed by a hash of the parameter values); a case that
   crashed is marked `FAIL` there and absorbed by Dakota's `failure_capture recover`.
3. The first batch of *new* points Dakota requests is captured: each fork driver
   writes its `case_<j>/{params.in,run.sh}` and blocks. Once the pending set is
   stable, `optimizer.py` kills Dakota's process group, keeps the restart file,
   and hands the cases to the platform (`status=CONTINUE`).
4. Dakota exiting on its own instead means its convergence criteria are satisfied
   → `CONVERGED`. The wrapper also stops on the generation budget or when the
   front's hypervolume stagnates (`stall_generations`), like the tutorial.

Dakota may propose fewer than `batch_size` new points in a generation (MOGA
offspring that duplicate known points are served from Dakota's evaluation cache);
the surplus worker slots are skipped for free.

## One generation must fit `iteration_timeout`

The retried `Iterate` step sets `retry.timeout` (form input `iteration_timeout`,
default 12h) because the platform's default is **30 s per attempt** — without it,
any generation slower than ~25 s (every scheduled wave, or `mesh_scale` ≥ 2 on
the login node) is canceled mid-simulation and the loop burns its budget
re-proposing. If your cases can queue or run longer than 12 h in total, raise
`iteration_timeout` along with the walltime.

## Running it

Pick the compute resource, set the optimizer knobs (`max_iterations`,
`batch_size`, `stall_generations`), and leave **Schedule Cases?** off to run the
cases on the login node — or on to give each OpenFOAM case its own SLURM/PBS job.
The first run installs OpenFOAM and Dakota (~5-10 min); later runs find them.

The run succeeds only after the optimizer wrote `CONVERGED`; the front (CSV and
SVG) is under `state/` in the run's job directory on the cluster.

## Swapping in your own case

`simulator.sh` (+ its mesh generator) is the only OpenFOAM-specific code: it
reads `params.in`, builds the case, runs the solver, extracts objectives into
`results.out` (atomic write, or exit non-zero leaving none — the failure
signal). Change the case construction and extraction there, and the
variable/objective declarations at the top of `optimizer.py` (`VARIABLES`,
`OBJECTIVES` and the MOGA block in `write_dakota_input`). Neither YAML needs to
change.
