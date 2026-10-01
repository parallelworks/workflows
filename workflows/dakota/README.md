# Dakota Optimizer Step

**[Dakota](https://dakota.sandia.gov)'s MOGA as one optimizer step** of an
ACTIVATE workflow: each run ingests the results of the designs it proposed last
time, then either proposes the next batch of designs (`CONTINUE`) or declares the
study over (`CONVERGED` or `FAILED`). The study lives in a **state directory** on
the resource — Dakota's restart file, every evaluated design, the current Pareto
front — so running the workflow again against the same directory continues it.

The step knows nothing about what evaluates the designs. Each proposal is a case
directory holding a Dakota-style `params.in`; whoever solves it leaves
`results.out` there before the next step. [`workflows/dakota-openfoam`](../dakota-openfoam/)
drives this step in a loop with [`workflows/openfoam-naca`](../openfoam-naca/) as
the evaluator; by hand, any script does ([below](#running-a-study-by-hand)).

## The interface

### In: the problem and the knobs

| Form group | Input | Meaning |
|---|---|---|
| `cluster` | `resource` | the compute resource whose filesystem holds the study; Dakota runs on its login node (the step is seconds of work, so there is no scheduler section) |
| `problem` | `variables` | one continuous design variable per line: `<name> <lower> <upper>`; the names label the `params.in` lines |
| | `objectives` | the two objectives, both minimized, in the order the evaluator writes them to `results.out` (negate a quantity to maximize it) |
| `optimizer` | `state_dir` | absolute path of the study; empty starts a fresh study under the run's job directory (`state/`, printed in the log as `STATE_DIR`) |
| | `batch_size` | MOGA population size: at most this many new designs per step |
| | `max_generations` | stop with the front found so far after this many evaluated generations |
| | `stall_generations` | declare convergence when the front's normalized hypervolume improves by less than 0.001 over this many consecutive generations |
| | `seed` | fixed per study: the restart replay requires a deterministic method |
| `software` | `dakota_load` | commands that put `dakota` on PATH (`module load dakota`); empty installs Dakota 6.16 from conda-forge under `${service_parent_install_dir:-$HOME/pw/software}/dakota` |

The problem is frozen in `state_dir/problem.json` on the first step; a later
step with different variables or objectives fails, because Dakota's restart file
can only be replayed for the study that wrote it. Start another state directory
for another problem.

### Out: proposals and status

Step outputs (`${{ needs.<job>.outputs.* }}` in a caller, also in the step log):

| Output | Meaning |
|---|---|
| `STATUS` | `CONTINUE` (designs to evaluate), `CONVERGED` (the study is over, the front is final) or `FAILED` |
| `GENERATION` | the generation just proposed, or the last one evaluated when the study stopped |
| `N_CASES` | designs proposed this step (0 when stopped); may be fewer than `batch_size` |
| `ITER_DIR` | `state_dir/iter_<GENERATION>`, where the proposed case directories are |
| `STATE_DIR` | the study directory |

The same four lines are in `state_dir/proposal.env` for a caller that would
rather read a file (the loop in `dakota-openfoam` does), and `state_dir/status`
holds the status word alone. The run itself succeeds on `CONTINUE` and
`CONVERGED` and fails on `FAILED`.

Files under the state directory:

```
problem.json         the frozen problem (variables with bounds, objectives)
state.json           generation counter, front, hypervolume history, counters
status               CONTINUE | CONVERGED | FAILED
proposal.env         STATUS, GENERATION, N_CASES, ITER_DIR (the step's last word)
iter_<N>/            one directory per generation
  proposals.csv      the proposed designs as a table (case, variables)
  case_<j>/params.in the design: one "<value> <name>" line per variable
  case_<j>/param.hash the replay key Dakota uses to find the result later
  case_<j>/results.out  what the evaluator left (see below)
evaluations.csv      every evaluated design: generation, case, status, variables, objectives
pareto.csv           the current non-dominated front (objectives, then variables)
pareto.svg           the same, plotted with every evaluation (stdlib, no dependencies)
dakota/              Dakota's input, log, tabular data and restart file
results_db/          the per-design results Dakota replays from
```

`evaluations.csv` and `pareto.csv` are rewritten after every ingest, so they are
also the live view of a running study ([Pareto front page](#watching-a-study-live)).

### The evaluator's contract

For every `case_<j>` under `ITER_DIR`, read `params.in` and leave, in the same
directory:

- `results.out`: one `<value> <label>` line per objective, in the order of
  `objectives`, written atomically (write to a temporary name, then rename) — the
  evaluation succeeded;
- or no `results.out` and an `exit_code` file (any content): the evaluation ran
  and failed. The step feeds the design back to Dakota as `FAIL`, which its
  `failure_capture recover` turns into penalty objectives, and the search moves
  on. This is how a diverging solver run is reported, so the point is not
  proposed again and again;
- or nothing: the evaluation never ran (the step hands the same generation back
  once; twice in a row ends the study as `FAILED`, see [failure semantics](#failure-semantics)).

Then run the step again with the same `state_dir`.

## Running a study by hand

The whole loop is a short shell script around the step's script, so a study runs
in a scratch directory on any machine with Dakota and Python 3 — no platform
needed. With the toy problem the tests use (a 2-variable ZDT1):

```bash
APP=/path/to/workflows/workflows/dakota/app
mkdir -p /tmp/toy && cd /tmp/toy
printf 'x1 0 1\nx2 0 1\n' > variables.txt
printf 'source ~/pw/software/dakota/miniforge/etc/profile.d/conda.sh\nconda activate dakota\n' > dakota-env.sh

for attempt in $(seq 1 30); do
  python3 $APP/optimizer.py --state-dir state --app-dir $APP \
      --variables-file variables.txt --objectives "f1 f2" \
      --batch-size 4 --max-generations 10 --stall-generations 3 \
      --dakota-env $PWD/dakota-env.sh
  source state/proposal.env                       # STATUS, GENERATION, N_CASES, ITER_DIR
  [ "$STATUS" != CONTINUE ] && break
  for c in $ITER_DIR/case_*; do                   # the platform parallelizes this
    (cd $c && python3 -c "
import math
v = dict((l.split()[1], float(l.split()[0])) for l in open('params.in') if l.strip())
f1 = v['x1']; g = 1 + 9 * v['x2']; f2 = g * (1 - math.sqrt(f1 / g))
open('results.out', 'w').write('%.10f f1\n%.10f f2\n' % (f1, f2))" && echo 0 > exit_code)
  done
done
cat state/status && cat state/pareto.csv
```

From the platform the same study is two runs of this workflow per generation
boundary: run it (it proposes `iter_1`), evaluate the four `case_*` directories
however you like, run it again with the same **State directory** (it ingests
them and proposes `iter_2`), and so on until `STATUS` is `CONVERGED`. The two
tests under `tests/general/` do exactly that: `gcpsmall-toy-gen1.json` starts a
fresh toy study in `~/pw/dakota-tests/toy`, and `gcpsmall-toy-gen2.json` has the
runner's `setup` snippet evaluate the proposals before the second step ingests
them.

## How Dakota fits a step

Dakota drives evaluations itself and has no "emit a batch and exit" mode for
optimization methods, so `optimizer.py` uses Dakota's documented crash-recovery
semantics as the pause button:

1. Every call resumes the study with `dakota -read_restart state/dakota/dakota.rst`
   and a fixed seed, so the method deterministically replays to where it stopped.
2. Designs evaluated meanwhile are fed back by `driver.py` from
   `state/results_db/` (keyed by a hash of the parameter values); a design that
   failed is marked `FAIL` there and absorbed by Dakota's `failure_capture recover`.
3. The first batch of *new* designs Dakota requests is captured: each fork driver
   writes its `case_<j>/params.in` and blocks. Once the pending set is stable
   (15 s without a new capture), `optimizer.py` kills Dakota's process group,
   keeps the restart file, and hands the cases over (`STATUS=CONTINUE`).
4. Dakota exiting on its own instead means its convergence criteria are satisfied
   → `CONVERGED`. The wrapper also stops on the generation budget or when the
   front's hypervolume stagnates.

Dakota may propose fewer than `batch_size` new designs in a generation (MOGA
offspring that duplicate known designs are served from Dakota's evaluation
cache), so a caller fanning the cases out should size its workers by `N_CASES`.

### Failure semantics

| generation came back with | meaning | what happens |
|---|---|---|
| some results, some cases without `results.out` | a design failed in the evaluator, or a worker was lost | the missing designs go to Dakota as `FAIL`; the search moves on |
| no results, but every case left an `exit_code` | every design of the generation failed | same: all `FAIL`, a `::warning::`, the study continues — unless no design has *ever* succeeded (the evaluator setup is broken, not a design) or this is the third such generation in a row, which end the study as `FAILED` |
| no results and no `exit_code` anywhere | the evaluations never ran | the same generation is handed back once; twice in a row is `FAILED` |

The distinction matters because Dakota's replay is deterministic: re-proposing a
failing design can only fail again, so an all-failed generation is treated as
results, and only a generation with no evidence of running at all is retried.

Every call is idempotent: `state.json` is written atomically after the case
directories, so a step that crashed mid-way is simply run again.

## Watching a study live

`app/pareto-server.py` serves the state directory as one page: every evaluated
design plotted on the two objectives, the current front highlighted, and the
design variables and objectives of any point on hover; it polls the files every
10 s while the study runs and stops polling once the status is final.

```bash
python3 $APP/pareto-server.py --state-dir /tmp/toy/state --port 8080 --title "toy study"
```

Standard library only, so it runs wherever the study is. `dakota-openfoam`
serves it as a `pw` endpoint (`pareto-<run slug>`) for the life of the
optimization and beyond — the endpoint jobs of its
[`general-naca.yaml`](../dakota-openfoam/yamls/general-naca.yaml) are the
pattern to copy for another study.

## What's in `app/`

| File | Role |
|---|---|
| `install-dakota.sh` | Idempotent Dakota install (conda-forge `dakota=6.16.0`, no sudo) into `${service_parent_install_dir:-$HOME/pw/software}/dakota/miniforge`, plus the activation file `tools/utils/prepare-env.sh` asks for; serialized with a lock |
| `optimizer.py` | The step: problem parsing and freezing, ingest, Dakota resume-and-capture, convergence, the front, every file above |
| `driver.py` | Dakota's fork-interface analysis driver: replay a known design from `results_db/`, or capture a new one as `case_<j>/params.in` and block |
| `pareto-server.py` | The live Pareto front page over a state directory |

Shared with the other conda-installing workflows: `tools/utils/miniforge.sh`
and `tools/utils/prepare-env.sh`.

## Limits

Two objectives, continuous variables, MOGA: the front and its hypervolume are
two-dimensional, and the Dakota input is generated for one method with fixed
settings (`mutation_type replace_uniform`, `mutation_rate 0.2`,
`metric_tracker` convergence). A single-objective study (SOGA) or other Dakota
methods would fit the same resume-and-capture mechanism but are not wired up.
