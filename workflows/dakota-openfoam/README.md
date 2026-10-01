# Dakota-OpenFOAM Optimization

**[Dakota](https://dakota.sandia.gov)'s MOGA driving [OpenFOAM](https://www.openfoam.com)
simulations** as an iterative ACTIVATE workflow: each iteration Dakota proposes a
batch of NACA 4-digit airfoil designs, the platform evaluates them as parallel
OpenFOAM cases on the cluster (login node or one scheduler job per case), and
the loop repeats until Dakota converges, the front stagnates, or the budget runs
out — while a `pw` endpoint shows the Pareto front growing live.

This version is **two standalone workflows wired together**:

| Piece | Workflow | Called by |
|---|---|---|
| the optimizer step: propose designs or stop | [`workflows/dakota`](../dakota/) | the `optimize` job of `iteration-naca.yaml` |
| the evaluator: one OpenFOAM case per design | [`workflows/openfoam-naca`](../openfoam-naca/) | the `workers` matrix of `iteration-naca.yaml`, once per proposed design |

Each runs on its own from the platform (their READMEs); this directory holds
only the loop that joins them, the live front, and the tests. The single-app
version it replaces is kept as a reference in
[`backup-no-subworkflow/`](backup-no-subworkflow/) (not runnable: its checkout
paths point at an app that moved). The loop mechanics — retry-as-loop, guarded
static matrix, file contract, failure semantics — are those of
[`tutorials/optimization`](../../tutorials/optimization/); read its README for
the *why* of every piece.

## How the pieces connect

```
general-naca.yaml
 ├─ preprocessing        state/ (the study), the Pareto front server script
 ├─ session_runner       script_submitter: pw endpoints run pareto-<slug> -- pareto-server.py
 ├─ wait_for_endpoint    endpoint listed + /healthz answers → SKIP_CLEANUP → cancel the submitter
 └─ optimization_loop    needs the endpoint: the page is live from generation 1
     ├─ Iterate          retried step; each attempt runs iteration-naca.yaml once:
     │   │
     │   │   optimize ──────────▶ workers-1..8 ─────────────▶ decide
     │   │   workflows/dakota      workflows/openfoam-naca     exit 1: next cycle
     │   │   one step              one call per case_<j>       exit 0: loop over
     │   │
     └─ Report           if: always — the verdict from state/status, the page URL
```

The two subworkflows never talk to each other; they meet in the files of the
state directory, exactly as the tutorial's placeholders did:

1. `optimize` calls the Dakota step with the problem (variables and bounds,
   objectives), the knobs and `state_dir`. The step ingests
   `state/iter_<N-1>/case_*/{results.out,exit_code}`, then writes the next
   `state/iter_<N>/case_<j>/params.in` set and `state/proposal.env`
   (`STATUS`, `GENERATION`, `N_CASES`, `ITER_DIR`), which the next step of the job
   publishes as outputs.
2. `workers` is the guarded static matrix of width 8: slot *j* runs only when
   `j <= N_CASES`, and calls the OpenFOAM workflow with
   `case.params_file = ITER_DIR/case_j/params.in` (the design) and
   `case.case_dir = ITER_DIR/case_j` (where to solve), plus the cluster, mesh and
   environment settings passed straight through. The call leaves `results.out`
   there, or `exit_code` without it when the solver diverged.
3. `decide` reads `state/status`: `CONTINUE` exits 1 so the parent's retry fires
   the next iteration; `CONVERGED`/`FAILED` exit 0 and the loop is over.

Because the evaluator is the standalone workflow itself, every case does what a
user clicking **Execute** on `openfoam-naca` gets: its own checkout of the
OpenFOAM app, its own environment check (the installer is lock-serialized, so a
cold cluster installs once while the sibling cases wait), its own
`script_submitter` job (login node or SLURM/PBS), and a solved case that opens in
ParaView — `state/iter_<N>/case_<j>/case/case.foam`, every design of every
generation.

### What changed from the single-app version

- **Two apps instead of one.** `optimizer.py` + `driver.py` + `install-dakota.sh`
  moved to `workflows/dakota/app` and became problem-agnostic (the variables and
  objectives come from the form, the per-case `case.sh` is no longer written by
  the driver); `simulator.sh` + `naca_blockmesh.py` + `openfoam-case/` +
  `install-openfoam.sh` moved to `workflows/openfoam-naca/app` and gained the
  ParaView post-step. `prepare-env.sh` and the Miniforge bootstrap are shared
  from `tools/utils/`. This directory has no `app/`: preprocessing checks out
  `workflows/dakota/app` only for the Pareto front server.
- **Who writes `exit_code`.** The OpenFOAM workflow's preprocessing now writes
  the `case.sh` that records the simulator's exit status; the Dakota step only
  ever reads it. The failure semantics are unchanged.
- **Per-case overhead.** Each worker is a subworkflow with three jobs
  (preprocessing, submitter, results) instead of one submitter call, so a
  generation costs roughly a minute more of platform time at the demo mesh; the
  ingest, the front and the verdict are unchanged.
- **Separate installs.** OpenFOAM lives under `.../openfoam-naca/miniforge`
  and Dakota under `.../dakota/miniforge` (one Miniforge per workflow, the
  repo's convention) instead of one shared `dakota-openfoam/miniforge`; a cluster
  that had the old prefix installs again, once.
- **The front is recorded every generation** (`state/evaluations.csv`,
  `state/pareto.csv`, `state/pareto.svg`), not only at the end, so the live page
  and a mid-run look at the state directory see the same thing.
- **Live Pareto front endpoint** (next section).

## The live Pareto front

While the loop runs, `pareto-<run slug>` in `pw endpoints list` (and on the run
page) serves one page: every evaluated design plotted as drag against negative
lift, the current non-dominated front highlighted and joined, and a tooltip on
hover (or keyboard focus) with the design's `max_camber`, `camber_position`,
`thickness`, its generation and case, and both objectives. Failed designs sit
along the bottom edge with the same tooltip. The header shows the status and
the generation and evaluation counts; a table of the front and the raw
`evaluations.csv` / `pareto.csv` are one click away.

How it works:

- **Served** by `workflows/dakota/app/pareto-server.py` (Python standard
  library, nothing to install) on the login node, through `script_submitter` and
  `pw endpoints run` like every endpoint workflow here. It reads the state
  directory on every request, so it needs no feed from the loop and cannot fall
  out of sync; a torn line of `evaluations.csv` (an append in progress) is
  skipped.
- **Refreshes** every 10 s: the page polls `/data.json` while the status is
  `CONTINUE` and stops polling once it is final, so a browser tab left open on a
  long run costs one small request per refresh and nothing afterwards. The
  server keeps no state, holds no file open and handles each request in its own
  thread, so a run of days is no different from a run of minutes.
- **Starts before the loop**: `optimization_loop` needs `wait_for_endpoint`, so
  the page is up from the first generation, and a server that cannot start fails
  the run before any case is spent. The health probe is `/healthz`.
- **After the optimization finishes** the endpoint stays up showing the final
  front with its status (`CONVERGED` or `FAILED`), exactly like the services of
  the other endpoint workflows outlive their runs; the `Report` step prints its
  URL. Cancelling the run after the endpoint came up leaves it serving too (the
  `SKIP_CLEANUP` marker). Remove it with `pw endpoints delete pareto-<run slug>`,
  which kills the server; the front stays in `state/pareto.csv` and
  `state/pareto.svg`. A cancel *before* the endpoint is healthy tears the server
  down through the submitter's cleanup (`cancel.sh`).

## Running it

Pick the compute resource, set the optimizer knobs (`max_iterations`,
`batch_size`, `stall_generations`), and leave **Schedule Cases?** off to run the
cases on the login node — or on to give each OpenFOAM case its own SLURM/PBS job,
each sized by **Cores per case**. The **Design Problem** group (collapsed) holds
the angle of attack, the variable bounds (keep the three names; narrow the box
to focus the search) and the Dakota seed. The first run installs OpenFOAM and
Dakota (~5–10 min) unless **Software Environment** points at site installs;
later runs find them.

The form's defaults are the fast demo (login node, 1 core, `mesh_scale` 1,
4 cases × 10 generations, ~10 min; the 4-generation test run took 4.5 min). The converged-mesh study ships as a saved
input set, `mesh3_slurm_4ranks` under **Load saved inputs** on the Execute page:
SLURM, 4 ranks per case, `mesh_scale` 3, 8 cases × 10 generations, ~25 min on
gcpsmall. It pins no resource; pick the cluster in the form.

The run succeeds only after the optimizer wrote `CONVERGED`; the front (CSV and
SVG) is under `state/` in the run's job directory on the cluster, every solved
case under `state/iter_<N>/case_<j>/case/` (open its `case.foam` in ParaView;
the `openfoam-naca` README says how), and the live page keeps serving until you
delete the endpoint.

### One generation must fit `iteration_timeout`

The retried `Iterate` step sets `retry.timeout` (form input `iteration_timeout`,
default 2d) because the platform's default is **30 s per attempt** — without it,
any generation slower than ~25 s is canceled mid-simulation and the loop burns
its budget re-proposing. The generous default only trips on a genuinely stuck
iteration; tighten it for faster failure detection, or raise it beyond two days
along with the case walltime.

### Reading a run

- The `Iterate` step shows only its **last** attempt; the history is the Pareto
  page, `state/evaluations.csv` and `state/state.json` (`hv_history` is the
  convergence curve).
- Each worker's log is three jobs deep: `workers-<k>` → the OpenFOAM
  subworkflow's `preprocessing`, `run_case` (the streamed solver output) and
  `results`. On the cluster, the case directory
  `state/iter_<N>/case_<j>/` has `run.*.out` and `case/log.*`.
- `pw workflows runs errors <slug>` lists the failures; a diverged design shows
  as a failed `workers-<k>` (its `results` job exits 1) and a `FAIL` row in
  `evaluations.csv`, and the loop continues.

## Tests

Under `tests/general-naca/` (the variant is the YAML's basename):
`gcpsmall.json` (login node, 4 cases × 4 generations, the endpoint checked and
deleted by the runner) and `gcpsmall-slurm-mpi2.json` (one SLURM job of 2 ranks
per case). Run them with `python3 tools/tests/run-workflow-test.py <test.json>`.
The original version's tests and their results are in
`backup-no-subworkflow/tests/`.
