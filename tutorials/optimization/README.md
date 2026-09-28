# Iterative Optimization on ACTIVATE — A Workflow Tutorial

This tutorial builds a **simulation-based optimization loop** as an ACTIVATE
workflow: run a batch of simulations in parallel, feed their results to an
optimizer, let it decide *stop or continue*, and repeat with the cases it proposes
— for as many iterations as it takes.

The example minimizes the two objectives of the **ZDT1 benchmark** with a small
evolutionary algorithm, but both compute pieces are deliberate stand-ins wired
through Dakota's file conventions: [`app/optimizer.py`](app/optimizer.py) is a
placeholder for **Dakota** and [`app/simulator.py`](app/simulator.py) a placeholder
for an **OpenFOAM** case driver. [Swapping them in](#swapping-in-dakota-and-openfoam)
changes neither YAML.

| File | What it is |
|---|---|
| [`general.yaml`](general.yaml) | The workflow you run: the form, the checkout, and the loop |
| [`iteration.yaml`](iteration.yaml) | ONE loop cycle, re-invoked fresh by every attempt of the loop |
| [`app/optimizer.py`](app/optimizer.py) | Dakota placeholder: ingest results, propose the next batch of cases or stop |
| [`app/simulator.py`](app/simulator.py) | OpenFOAM placeholder: evaluate one case dir (`params.in` → `results.out`) |
| [`tests/general/zdt1.json`](tests/general/zdt1.json) | The recorded end-to-end test (see `tools/tests/README.md`) |

The lesson is in three stages: run the loop **by hand** with no platform at all,
understand the **three patterns** that turn it into a workflow, then run and scale
it on a cluster.

---

## Stage 0 — the loop by hand

Everything the workflow orchestrates can run in a scratch directory on your laptop,
because the entire optimizer ↔ simulator interface is **files in case directories**.
Try it (any Python ≥ 3.6, standard library only):

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
cat state/status && head -3 state/pareto.csv
```

Each `optimizer.py` call ingests whatever results exist for the generation it
proposed last time, then either writes the next `state/iter_<N>/case_<j>/` set —
each case holding `params.in` (the design variables, one `<value> <name>` line per
variable, Dakota fork-driver style) and a `run.sh` — or stops, leaving
`state/pareto.csv` and a final `state/status` of `CONVERGED` or `FAILED`.
`simulator.py` is the other half of the contract: run inside one case directory, it
reads `params.in` and writes `results.out` (one `<value> <label>` objective per
line), or exits non-zero leaving no `results.out` at all.

That is the whole loop. The rest of the tutorial is making the platform drive it:
the `for j` loop becomes parallel jobs on a cluster, the `for attempt` loop becomes
a retried step, and the files stay exactly where they are.

### The correctness check

ZDT1's analytic Pareto front is `f2 = 1 − √f1` (reached when `g = 1`), which makes
correctness cheap to see: the closer `pareto.csv` hugs that curve — the `g` column
printed in each row falling toward 1 — the better the loop worked end to end. A
realistic budget needs no cluster: with `--batch-size 40 --max-iterations 200` the
loop above runs ~8000 evaluations in a couple of minutes locally (`SIM_SLEEP_S=0`)
and lands the front at `g ≈ 1.04`, mean `|f2 − (1−√f1)| ≈ 0.03`. Platform-scale
smoke runs (4 iterations × 4 cases) exercise every moving part but stop far from
the front — that is expected: it's a budget knob, not a bug.

---

## Stage 1 — three patterns turn the loop into a workflow

A workflow is a DAG: jobs and `needs` edges, no cycles, and every job known at
submission. An optimization loop violates that twice — it iterates an unknown
number of times, and each iteration's case count is decided at runtime. Three
patterns bridge the gap.

### Pattern 1: retry-as-loop

`general.yaml`'s `Iterate` step calls `iteration.yaml` as a subworkflow with a
`retry` block. The subworkflow's exit status is the loop control, decided by its
final `decide` job from `state/status`:

- **exit 1** (status still `CONTINUE`) → the step *fails* → the platform's retry
  fires the next attempt, which invokes `iteration.yaml` **fresh**: the next
  iteration.
- **exit 0** (status `CONVERGED` or `FAILED`) → the step succeeds → the loop ends,
  and the `Report` step turns the status into the run's verdict.

`max-retries` is therefore the **loop budget**. Two things to keep straight:

- **Attempt ≠ iteration.** The true iteration number is the generation counter in
  `state/state.json`, never the attempt counter. A crashed attempt re-runs the
  *same* iteration off the state files (see [self-healing](#failure-semantics))
  while still consuming budget.
- **Only the last attempt's logs surface** on the `Iterate` step, and attempts
  reuse the same directory. Per-iteration history therefore goes to **files under
  `state/`** and to `::notice` lines, not to step output you expect to keep.

### Pattern 2: the guarded static matrix

The natural way to fan out over the optimizer's cases would be a matrix over a
computed list — but **a matrix can never expand over runtime values**; submission
itself fails (`Could not expand matrix jobs`). Matrix lists must be concrete when
the run is submitted.

The workaround, borrowed from production workflows, is in `iteration.yaml`'s
`workers` job: a **literal** matrix list of the *maximum* batch width, with a
job-level guard comparing each slot to a runtime output:

```yaml
strategy:
  fail-fast: false
  matrix:
    job_id: [1, 2, 3, 4, 5, 6, 7, 8]     # written out as a YAML list
if: ${{ matrix.job_id <= needs.optimize.outputs.N_CASES }}
```

Surplus workers are *skipped*, which costs nothing — including all eight of them on
the final call, when the optimizer stops and emits `N_CASES=0`. The width is a
hardcoded ceiling (`preprocessing` validates `batch_size` against it); to raise it,
extend the list and the `batch_size` max. Each live worker hands its case to the
repo's `script_submitter` subworkflow with
`rundir: ${{ needs.optimize.outputs.ITER_DIR }}/case_${{ matrix.job_id }}`, so the
case directory becomes the working directory on the cluster.

### Pattern 3: the results-file protocol

`script_submitter` does **not** forward the submitted script's exit code, so "did
my simulation succeed?" cannot travel as job status. It travels as a file:
`run.sh` either produces `results.out` or it doesn't, and the *optimizer* decides
what a missing result means (here: the individual is dropped from the generation;
a real study might assign a penalty or re-propose the point). The write is atomic
(`results.out.tmp` → rename) so a half-written file can never be ingested.

The same philosophy governs all data flow, in both directions:

- **Small scalars** cross job and layer boundaries as step outputs:
  `preprocessing` publishes `STATE_DIR`/`APP_DIR` with
  `echo KEY=value | tee -a $OUTPUTS`, the optimizer emits `N_CASES`/`ITER_DIR` the
  same way, and consumers read `${{ needs.<job>.outputs.KEY }}`.
- **Everything else** — optimizer state, case definitions, results, the final
  front — lives in files under `state/`, and only the *path* is passed as an
  input. Jobs accept their default working directories; nothing assumes a shared
  environment variable.

### How a run unfolds

```
general.yaml
├─ preprocessing            checkout app/, validate batch_size, create state/
└─ optimization_loop
   ├─ Iterate  (retry: max_iterations, one attempt per loop cycle)
   │    └─ iteration.yaml
   │       ├─ optimize      ingest gen N results → propose gen N+1 (or stop)
   │       ├─ workers ×8    guarded matrix → script_submitter → run.sh per case
   │       └─ decide        status CONTINUE → exit 1 (retry) · else exit 0
   └─ Report (if: always)   CONVERGED → success · FAILED/CONTINUE/missing → error
```

After a run, the state directory in the parent run's job dir tells the whole story:

```
state/
├── state.json         generation counter, survivor pool, front, hypervolume history
├── status             CONTINUE | CONVERGED | FAILED
├── proposal.env       N_CASES=… ITER_DIR=…   (the optimizer's last word)
├── iter_1/case_1..B/  params.in · run.sh · results.out
├── iter_2/…
└── pareto.csv         written when the loop stops: f1, f2, g, x1..x30 per row
```

### Failure semantics

The loop is built so that every failure lands in one of three explicit outcomes,
reported by the `Report` step (`if: ${{ always }}` — it must speak even when
`Iterate` has failed):

| What happened | How it plays out |
|---|---|
| Some cases fail in an iteration | `fail-fast: false` lets the rest finish; the optimizer drops the missing results and continues |
| An attempt crashes (optimize job dies, worker infrastructure fails) | `decide` (`if: ${{ always }}`) still exits 1 → the retry re-runs the **same** iteration: state.json is written atomically *after* the case dirs, so a re-run finds a consistent state and re-proposes the same generation — self-healing, at the price of one budget unit |
| A whole generation returns zero results, twice in a row | something is systematically broken → the optimizer writes `FAILED`, the loop stops, the run errors |
| The optimizer never wants to stop | the retry budget runs out with status `CONTINUE` → the run errors with that explanation |

---

## Stage 2 — run it on a cluster

From the UI, point a form at this file; from a shell (note the **absolute** YAML
path — a relative one is parsed as a git host):

```bash
pw workflows run /abs/path/tutorials/optimization/general.yaml -i '{
  "cluster":   {"resource": "<cluster>", "scheduler": false},
  "optimizer": {"max_iterations": 4, "batch_size": 4, "stall_generations": 3}
}'
```

The run completes with success only after the optimizer wrote `CONVERGED`; the
final front is at `state/pareto.csv` under the run's job dir
(`~/pw/jobs/<run-slug>/` on the cluster). With `"scheduler": true` each case is
submitted through SLURM/PBS with the form's directives instead of running on the
login node — the loop is unchanged, and one walltime knob covers each case.

Everything the run fetches from GitHub (`app/`, `iteration.yaml`, the `uses:`
subworkflows) comes from the branch named in `general.yaml` — push before you run,
or you will test yesterday's code. The recorded end-to-end test runs with:

```bash
python3 tools/tests/run-workflow-test.py tutorials/optimization/tests/general/zdt1.json
```

Cancelling a run mid-flight is clean by construction: `script_submitter` owns each
case's lifecycle (its cleanup cancels the scheduler job or process tree), skipped
workers never start, and the loop keeps no daemons — nothing outlives the run. If
a real case driver ever starts things the submitter cannot see (containers,
license daemons), give each case a `cancel.sh` and set
`define_cleanup_script: true` on the submitter call.

### Scaling and tuning

- **Wider batches** — extend the `job_id` list in `iteration.yaml` and the
  `batch_size` max in both forms. Skipped slots are free, so a generous ceiling
  costs nothing. To cap cluster pressure, add `max-parallel: <n>` under `strategy`.
- **More iterations** — `max_iterations` is both the optimizer's generation budget
  and the loop's retry budget; every platform iteration adds scheduling overhead
  (roughly a minute at small scale), so budget accordingly.
- **Convergence** — the optimizer stops early when the front's hypervolume gains
  less than `0.001` over `stall_generations` consecutive generations; widen the
  window (or raise `max_iterations`) for a deeper search.

### Debugging

- `pw workflows runs errors <slug>` from anywhere; the job dir
  (`~/pw/jobs/<run-slug>/`) on the cluster for everything else.
- The `Iterate` step shows only the **last** attempt. For history, read
  `state/state.json` (`hv_history` is the convergence curve), the `::notice`
  lines each attempt printed, and the per-case `results.out` files.
- A form value that seems ignored: read the rendered step,
  `logs/<job>/step_N/script-unstable.sh`, which shows every `${{ input }}` as its
  literal value.

---

## Swapping in Dakota and OpenFOAM

The per-case interface *is* Dakota's fork-driver convention on purpose:
`params.in` in, `results.out` out, one case per directory.

**Simulator → OpenFOAM.** Replace `simulator.py` with a driver that reads
`params.in`, builds the case (mesh/dict templating), runs the solver, and extracts
the objectives into `results.out` — same two files, same atomic-write-or-die rule.
The optimizer-side `run.sh` template (in `optimizer.py`'s `write_cases`) is the
place to add environment setup, module loads, or `srun` decorations; with
`"scheduler": true` each case already gets its own scheduler job, so parallel
solvers fit without touching the YAMLs.

**Optimizer → Dakota.** The contract to keep is exactly what each `optimizer.py`
call does: *read all results so far, then either emit the next batch of case
directories (+ `status` `CONTINUE`, `proposal.env`) or stop (+ `pareto.csv`,
`CONVERGED`/`FAILED`)*. Dakota fits this shape through its restart file: each call
resumes `dakota -read_restart`, lets the strategy generate its next evaluation
batch (pre/post-run staged execution writes exactly these `params.in` files), and
stops when Dakota's own convergence criteria hold. State — the restart file — stays
under `state/`, like everything else.

Neither swap touches `general.yaml` or `iteration.yaml`: they know only paths,
`N_CASES`, and three status words.
