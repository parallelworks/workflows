# Iterative Optimization on ACTIVATE — A Workflow Tutorial

This tutorial builds an **optimization loop** as an ACTIVATE workflow: run a batch
of simulations in parallel on a cluster, feed their results to an optimizer, let it
decide *stop or continue*, and repeat with the cases it proposes — for as many
iterations as it takes.

The example minimizes the two objectives of the **ZDT1 benchmark** with a small
evolutionary algorithm. Both compute pieces are simple placeholders behind a
file-based contract, so [swapping in a real optimizer and solver](#swapping-in-dakota-and-openfoam)
changes neither YAML.

Three stages build it up:

| Stage | File(s) | What it shows |
|---|---|---|
| 0 | [`app/`](app/) | The optimizer ↔ simulator contract, run by hand — no platform needed |
| 1 | [`iteration.yaml`](iteration.yaml) | One cycle as a workflow: propose → evaluate in parallel → decide |
| 2 | [`general.yaml`](general.yaml) | The cycle repeated until convergence, and a clear verdict either way |

By the end of this tutorial you will understand how to:

- Run an *iterate-until-converged* loop with a retried subworkflow step whose exit
  code means "go again" or "done"
- Fan a runtime-computed set of cases out over parallel jobs — and why that needs a
  matrix sized at submission plus a guard
- Pass small values between jobs and layers as step outputs (`$OUTPUTS`), and
  everything else as files whose *paths* travel as inputs
- Make a workflow report success and failure explicitly, from state files, with
  `if: ${{ always }}` steps
- Keep a loop self-healing: idempotent state updates, safe re-runs after a crashed
  attempt, and results (CSV + plot) that outlive the run

---

## Stage 0 — the loop by hand

Before writing any YAML, notice that the whole workflow simplifies to a short bash
script. The optimizer and the simulator exchange nothing but files inside case
directories, so the complete loop runs in a scratch directory on your laptop (any
Python ≥ 3.6, standard library only):

```bash
mkdir -p /tmp/opt/state && cd /tmp/opt
APP=/path/to/workflows/tutorials/optimization/app

for attempt in $(seq 1 30); do
  python3 $APP/optimizer.py --state-dir state --app-dir $APP \
          --batch-size 8 --max-iterations 25 --stall-generations 4
  source state/proposal.env                     # N_CASES, ITER_DIR
  [ "$(cat state/status)" != CONTINUE ] && break
  for j in $(seq 1 $N_CASES); do                # the platform will parallelize this
    (cd $ITER_DIR/case_$j && SIM_SLEEP_S=0 bash run.sh)
  done
done
cat state/status && open state/pareto.svg       # xdg-open on Linux
```

The two sides of the contract:

| Script | What it does |
|---|---|
| [`optimizer.py`](app/optimizer.py) | Ingests every `results.out` of the generation it proposed last time, then **either** writes the next `state/iter_<N>/case_<j>/` set — each case holding `params.in` (one `<value> <name>` line per design variable) and a `run.sh` — **or** stops, leaving `state/pareto.csv`, `state/pareto.svg` and a final `state/status` of `CONVERGED` or `FAILED` |
| [`simulator.py`](app/simulator.py) | Runs inside one case directory: reads `params.in`, computes the ZDT1 objectives, sleeps a few seconds to imitate solver time, writes `results.out` (one `<value> <label>` line per objective) — or exits non-zero leaving **no** `results.out`, which is the failure signal |

That is the whole loop. The rest of the tutorial makes the platform drive it: the
`for j` loop becomes parallel jobs on a cluster, the `for attempt` loop becomes a
retried step, and the files stay exactly where they are.

### Watching it converge

Every generation, the optimizer redraws **`state/pareto.svg`**: all evaluations so
far, the current Pareto front, and — because ZDT1's true front is known analytically
(`f2 = 1 − √f1`) — the target curve to compare against. The closer the orange front
hugs the dashed curve, the better the loop worked; `state/pareto.csv` has the same
front as data (`f1, f2, g, x1..x30` per row, with `g → 1` at the true front).

How close the front gets depends only on how many evaluations you give it. ZDT1
with 30 variables needs a few thousand: with batches of 8, 25 iterations
(200 evaluations) reach `g ≈ 4` and 120 iterations still only `g ≈ 2.3`, while the
local loop above with `--batch-size 40 --max-iterations 200` (8000 evaluations,
about two minutes) reaches `g ≈ 1.04` — visually on the curve. So a short platform
run whose front sits well above the dashed line is converging normally; it simply
was not given the budget to arrive.

---

## Stage 1 — one cycle as a workflow (`iteration.yaml`)

`iteration.yaml` is **one** pass through the loop body, as three jobs:

```
optimize  ──▶  workers (matrix ×batch_size)  ──▶  decide
propose or     evaluate the cases        exit 0: loop over
stop           in parallel               exit 1: run me again
```

### The `optimize` job

One step runs `optimizer.py` and publishes its two scalars as step outputs:

```yaml
- name: Propose or Stop
  run: |
    python3 "${{ inputs.app_dir }}/optimizer.py" --state-dir "${{ inputs.state_dir }}" ...
    tee -a $OUTPUTS < "${{ inputs.state_dir }}/proposal.env"    # N_CASES, ITER_DIR
```

This is the tutorial's data-flow rule in one line: **small scalars become outputs;
everything else stays in files, and only paths travel.** The optimizer's state,
the case definitions and the results never pass through the YAML — just `N_CASES`,
`ITER_DIR`, and the `state_dir`/`app_dir` paths handed down as inputs.

A second step guards the contract: if the optimizer ever proposes more cases than
the workers matrix can take, the job **fails loudly** instead of silently
evaluating only the first `batch_size` (see [failure semantics](#failure-semantics)
for how that ends).

### The `workers` job — a matrix sized at submission, with a guard

A matrix cannot expand over runtime values — submission itself fails with
`Could not expand matrix jobs` if the list comes from another job's output. Matrix
lists must be concrete when the run is submitted. A form input *is* concrete
then, so the matrix can be sized by one: a **literal list of the maximum batch
width, sliced to `batch_size`** with the expression language's `get` operator.
The number of cases the optimizer actually proposes is a runtime output, which
no matrix can take, so a job-level `if:` compares each slot against it:

```yaml
workers:
  needs: [optimize]
  strategy:
    fail-fast: false
    matrix:
      job_id: ${{ [1, 2, 3, 4, 5, 6, 7, 8] get 0:(inputs.batch_size) }}
  if: ${{ matrix.job_id <= needs.optimize.outputs.N_CASES }}
```

The run page shows exactly `batch_size` workers. Workers beyond `N_CASES` are
*skipped*, which costs nothing — including all of them on the final pass, when
the optimizer stops and emits `N_CASES=0`. Each live worker hands its case to the
repo's `script_submitter` subworkflow with

```yaml
rundir: ${{ needs.optimize.outputs.ITER_DIR }}/case_${{ matrix.job_id }}
```

so the case directory becomes the working directory, `./run.sh` runs there, and
the form's scheduler settings (run on the login node, or one SLURM/PBS job per
case) pass straight through. `fail-fast: false` lets the other cases finish when
one fails. To allow bigger batches, extend the literal list and the `batch_size`
caps — the literal is a deliberate, validated ceiling, not a magic number.

### The `decide` job — an exit code as the loop signal

`decide` runs `if: ${{ always }}` (even after a crash upstream), reads
`state/status`, and turns it into this run's exit status:

| `state/status` | `decide` | Meaning for the parent |
|---|---|---|
| `CONVERGED` or `FAILED` | exit 0 | the cycle ran to a verdict — stop looping |
| `CONTINUE` (or missing/stale) | exit 1 | run the next cycle |

That inversion — *failure means "again"* — is what makes the retry in Stage 2 a
loop.

---

## Stage 2 — the loop (`general.yaml`)

`general.yaml` is what you run. On the run page the two files appear as one graph
— the whole Stage 1 cycle sits inside a single step of the parent job:

```
preprocessing
     │
     ▼
optimization_loop
 ├─ Iterate           a retried step; each attempt runs iteration.yaml once:
 │   │
 │   │   optimize ──▶ workers-1 ─┐
 │   │                workers-2  ├──▶ decide ─┬─ exit 1 → retry: next cycle
 │   │                    ⋮      │            └─ exit 0 → loop over
 │   │                workers-B ─┘
 │   │
 └─ Report            if: always — reads state/status, sets the run's verdict
```

(B = `batch_size`. The run page numbers the matrix workers from 0, so `job_id: 1`
shows up as `workers-0`.)

The `preprocessing` job checks out `app/` from this repo, validates `batch_size`
against the matrix ceiling, creates `state/` in its own job directory and publishes
the two absolute paths:

```yaml
echo "STATE_DIR=${PWD}/state" | tee -a $OUTPUTS
echo "APP_DIR=${PWD}/tutorials/optimization/app" | tee -a $OUTPUTS
```

### The `Iterate` step — a retry as a loop

The `optimization_loop` job invokes `iteration.yaml` with a `retry` block:

```yaml
- name: Iterate
  retry:
    max-retries: ${{ inputs.optimizer.max_iterations }}
    interval: 10s
  uses: github/parallelworks/workflows@canary
  with:
    $yaml: tutorials/optimization/iteration.yaml
    ...
    state_dir: ${{ needs.preprocessing.outputs.STATE_DIR }}
    app_dir: ${{ needs.preprocessing.outputs.APP_DIR }}
```

Every attempt runs one full cycle. While `decide` exits 1, the step "fails" and
the platform's retry launches the next cycle; when it exits 0, the loop is over.
`max-retries` is the **loop budget** — the same number as the optimizer's
generation budget, taken from the form.

Two things to keep straight when reading a run:

- **Attempt ≠ iteration.** The true iteration number is the generation counter in
  `state/state.json`. A crashed attempt re-runs the *same* iteration (below) while
  still consuming one attempt.
- **A retried step keeps only its last attempt's log.** Everything an attempt
  prints — `::notice` lines included — is replaced when the next attempt runs, so
  once the loop ends you can only read the final iteration's output. That is why
  anything worth keeping goes to files: the generation counter and hypervolume
  history are in `state/state.json`, the per-case outputs under `state/iter_*/`,
  and `pareto.svg` is redrawn every generation.

### The `Report` step — the verdict

`Report` runs `if: ${{ always }}` and maps `state/status` to the run's outcome, so
a finished run always says *why* it finished: `CONVERGED` prints the front and
succeeds; anything else prints a targeted `::error` and fails the run. The loop's
success is defined by the optimizer's verdict, never by "the steps happened to
run".

### What a run leaves behind

On the cluster, the run's job directory holds the whole story:

```
state/
├── state.json         generation counter, survivor pool, front, hypervolume history
├── status             CONTINUE | CONVERGED | FAILED
├── proposal.env       N_CASES=… ITER_DIR=…   (the optimizer's last word)
├── iter_1/case_1..B/  params.in · run.sh · results.out
├── iter_2/…
├── pareto.csv         the front as data: f1, f2, g, x1..x30 per row
└── pareto.svg         the picture: all evaluations, the front, the analytic curve
```

---

## Failure semantics

Failures escalate through three explicit levels — a case, a generation, the loop —
and every possible ending is one of two verdicts: **`CONVERGED` (run succeeds)**
or **an explained error (run fails)**. Nothing ends silently.

| Level | What happened | What the loop does |
|---|---|---|
| Case | one simulation crashes → no `results.out` | `fail-fast: false` lets the rest of the batch finish; the optimizer drops the missing result and continues |
| Generation | *every* case of a generation came back without results | the next attempt re-proposes the same generation once (the case files are intact); a second all-miss means something is systematically broken → the optimizer writes `FAILED` |
| Attempt | the cycle crashed mid-flight (node hiccup, worker infrastructure failure) | `decide` still runs (`if: ${{ always }}`) and exits 1, so the retry re-runs the **same** iteration: `state.json` is written atomically *after* the case directories, so a re-run always finds a consistent state — self-healing, at the price of one attempt from the budget |
| Contract | the optimizer proposed more cases than `batch_size`, the matrix width | the guard step fails the cycle rather than silently evaluating a subset; since re-proposals repeat the violation, the generation-level escalation ends it as `FAILED` two attempts later |
| Budget | the retries ran out while `state/status` still says `CONTINUE` | `Report` fails the run and says so: raise `max_iterations` (crashed attempts also consume budget) or loosen the convergence knobs |

And the two decided endings: `CONVERGED` → `Report` prints the front and the run
**succeeds**; `FAILED` → the loop stops on purpose (`decide` exits 0 — retrying a
systematic breakage would only burn budget) and `Report` turns it into a run
**error** pointing at the last generation's worker logs.

---

## Running it

Open **Workflows** in the ACTIVATE UI, select this workflow, and fill the two form
groups: pick the compute resource, and set the optimizer knobs — `max_iterations`
(the generation *and* loop budget), `batch_size` (parallel cases per iteration,
capped by the matrix width), and `stall_generations` (declare convergence when the
front's hypervolume improves by less than 0.001 over that many consecutive
generations). Leave **Schedule Cases?** off to run every case on the login node,
or turn it on to give each case its own SLURM/PBS job with the walltime and
directives from the form. Then click **Execute**.

The run succeeds only after the optimizer wrote `CONVERGED`; the front — CSV and
plot — is under `state/` in the run's job directory on the cluster
(`~/pw/jobs/<run-slug>/`). Cancelling a run mid-flight is clean by construction:
`script_submitter` owns each case's lifecycle (its cleanup cancels the scheduler
job or process tree), skipped workers never start, and the loop keeps no daemons.

### Scaling and tuning

- **Wider batches** — extend the literal `job_id` list in `iteration.yaml` and
  the `batch_size` caps in both forms; the matrix itself follows `batch_size`.
  To limit how many cases run at the same time, add `max-parallel: <n>` under
  `strategy`.
- **More iterations** — every platform iteration adds scheduling overhead (roughly
  a minute at small scale), so budget accordingly; the loop is restartable state,
  so a deeper search is just a bigger `max_iterations`.
- **Real workloads** — with **Schedule Cases?** on, each case is its own scheduler
  job; multi-node solvers fit without touching the YAMLs (see the
  [swap notes](#swapping-in-dakota-and-openfoam)). One full generation — queue,
  node boot, every case — must fit the **Time budget per iteration** input: an
  attempt that exceeds it is canceled and retried.

### Debugging

- The `Iterate` step's log covers only the **last** attempt (see Stage 2); the
  run's history is in `state/state.json` (`hv_history` is the convergence curve)
  and in the per-case files under `state/iter_*/`.
- `pareto.svg` is redrawn every generation — opening it mid-run shows how far the
  search has come.
- A form value that seems ignored: read the rendered step,
  `logs/<job>/step_N/script-unstable.sh` in the job directory, which shows every
  `${{ input }}` as its literal value.

## Variants

`hsp.yaml` with `iteration-hsp.yaml` is the HSP (`activate.hpc.mil`) loop,
`noaa.yaml` with `iteration-noaa.yaml` the NOAA (`noaa.parallel.works`) one: the
same loop with the platform's form (the resource as the top-level input; SLURM
account, QoS and, on HSP, node type for on-prem `existing` resources; the PBS
account on HSP), passed through an iteration that submits every case with the
matching `script_submitter` variant. Nothing else changes: the optimizer and the
simulator are standard-library Python, so no site module is needed.

`tests/<variant>/` records a run of each on a cloud SLURM cluster: on the login
node (`zdt1.json`) and, for the two variants, with one scheduler job per case
(`zdt1-slurm.json`); run one with `python3 tools/tests/run-workflow-test.py <test.json>`.

---

## Swapping in Dakota and OpenFOAM

The placeholders were inspired by a real pairing — **Dakota** driving **OpenFOAM**
— and deliberately simplified down to the part that matters here: the loop and its
file contract. The per-case interface mirrors Dakota's fork-driver convention
(`params.in` in, `results.out` out, one case per directory) on purpose, so both
pieces swap out without touching either YAML.

**Simulator → OpenFOAM.** Replace `simulator.py` with a driver that reads
`params.in`, builds the case (mesh/dict templating), runs the solver, and extracts
the objectives into `results.out` — same two files, same
atomic-write-or-exit-nonzero rule. The `run.sh` template (in `optimizer.py`'s
`write_cases`) is the place for module loads, environment setup, or `srun`
decorations; with **Schedule Cases?** on, each case already gets its own scheduler
job, so parallel solvers fit as-is.

**Optimizer → Dakota.** The contract to keep is exactly what each `optimizer.py`
call does: *read all results so far, then either emit the next batch of case
directories (+ `CONTINUE`, `proposal.env`) or stop (+ `pareto.csv`,
`CONVERGED`/`FAILED`)*. Dakota fits this shape through its restart file: each call
resumes `dakota -read_restart`, lets the strategy generate its next evaluation
batch (pre/post-run staged execution writes exactly these `params.in` files), and
stops when Dakota's own convergence criteria hold. Its state — the restart file —
lives under `state/` like everything else. The dashed reference curve in
`pareto.svg` exists only because ZDT1's true front is known; remove it from
`write_plot` when the placeholder goes.

Neither swap needs to touch `general.yaml` or `iteration.yaml`: the YAMLs know only
paths, `N_CASES`, and three status words.
