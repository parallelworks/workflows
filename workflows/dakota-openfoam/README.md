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

Turbulent flow over a backward-facing step (the pitzDaily case shipped with
OpenFOAM), `simpleFoam` + k-epsilon, ~10 s per case on one core.

| | |
|---|---|
| Design variables | `inlet_velocity` ∈ [5, 15] m/s · `viscosity` ∈ [5e-6, 5e-5] m²/s |
| Objectives (both minimized) | `pressure_drop` — kinematic total pressure drop inlet→outlet · `neg_outlet_speed` — negative average outlet speed |

Faster flow costs more total pressure: the two objectives conflict and the loop
maps the tradeoff as a Pareto front (`state/pareto.csv` + `state/pareto.svg` in
the run's job directory).

## What's in `app/`

| File | Role |
|---|---|
| `install-openfoam.sh` | Idempotent OpenFOAM install (conda-forge `openfoam=2412`, no sudo) into `${service_parent_install_dir:-$HOME/pw/software}/dakota-openfoam/miniforge` |
| `install-dakota.sh` | Idempotent Dakota install (conda-forge `dakota=6.16.0`) into the same prefix |
| `install-common.sh` | Shared Miniforge bootstrap, sourced by both |
| `optimizer.py` | The tutorial's propose-or-stop contract, backed by Dakota (below) |
| `driver.py` | Dakota's fork-interface analysis driver: replay-or-capture |
| `simulator.sh` | Per-case OpenFOAM driver: `params.in` → templated pitzDaily case → `blockMesh` + `simpleFoam` → `results.out` |

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

## Running it

Pick the compute resource, set the optimizer knobs (`max_iterations`,
`batch_size`, `stall_generations`), and leave **Schedule Cases?** off to run the
cases on the login node — or on to give each OpenFOAM case its own SLURM/PBS job.
The first run installs OpenFOAM and Dakota (~5-10 min); later runs find them.

The run succeeds only after the optimizer wrote `CONVERGED`; the front (CSV and
SVG) is under `state/` in the run's job directory on the cluster.

## Swapping in your own case

`simulator.sh` is the only OpenFOAM-specific file: it reads `params.in`, builds
the case, runs the solver, extracts objectives into `results.out` (atomic write,
or exit non-zero leaving none — the failure signal). Change the case template and
extraction there, and the variable/objective declarations at the top of
`optimizer.py` (`VARIABLES`, `OBJECTIVES` and the MOGA block in
`write_dakota_input`). Neither YAML needs to change.
