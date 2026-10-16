# OpenFOAM NACA Case with Restarts

A long simulation that keeps being killed and is resubmitted until it completes.
The case is [`openfoam-naca`](../openfoam-naca/)'s NACA airfoil, made to outlast
its walltime: SLURM kills the job at the limit, the workflow resubmits it, the
solver picks up from its latest checkpoint, and so on until the case is solved.
Preempted nodes, lost nodes and an attempt that overruns its budget are handled
the same way.

It is written as the example for a simulation tool of your own: every piece a
restartable workflow needs is here, in its own place, and the last section says
what to copy for another solver.

![The Solve step retries attempt.yaml, which calls the whole openfoam-naca workflow on a shared case directory and reads its state; the case directory holds the attempts log, the stage markers and the checkpoints; the Report step ends the run as solved, failed on its own or out of attempts](thumbnails/restart-loop.svg)

| Piece | Where | What it does |
|---|---|---|
| checkpoints | `openfoam-naca`'s **Checkpoints and Resume** form group → `controlDict` | `simpleFoam` writes its fields every `checkpoint_every` iterations and keeps the last `keep_checkpoints` |
| the run script | [`openfoam-naca/app/simulator.sh`](../openfoam-naca/app/simulator.sh) + [`restart.sh`](../openfoam-naca/app/restart.sh) | resumes from the latest complete checkpoint, skips the stages already done, records every attempt, tells a kill from a solver that failed on its own |
| the signal | `case.sh`, written by `openfoam-naca`'s preprocessing | passes the walltime's SIGTERM on to the simulator, which stops the solver and records the interruption |
| the loop | [`yamls/general.yaml`](yamls/general.yaml), the `Solve` step | a `retry` block around one subworkflow call per attempt |
| the attempt | [`yamls/attempt.yaml`](yamls/attempt.yaml) | the whole `openfoam-naca` workflow, then exit 0 (over) or 1 (interrupted: retry) |
| the verdict | `general.yaml`, the `Report` step | solved after N attempts, failed on its own, or out of attempts |

This workflow has no code of its own: the case, its form and its results are
`openfoam-naca`'s, called as a subworkflow.

## A run

With the defaults the case is a `mesh_scale` 3 airfoil (a few minutes on one
core) and, scheduled, the walltime is 2 minutes, so a run takes two or three
attempts. On the login node the attempt budget is the only thing that
interrupts a case; the saved inputs **login_node_demo** (75 seconds against the
same case) show four or five attempts. The run log shows only the last attempt
under the `Solve` step (a retried step surfaces only its last attempt); the
whole history is `attempts.log` in the case directory, which the `Report`
step prints:

```
2026-10-16T08:31:46Z  attempt 1  start  from scratch: no case yet
2026-10-16T08:32:51Z  attempt 1  end    interrupted (SIGTERM) in simpleFoam; solver log at iteration 853; checkpoints: 700 800
2026-10-16T08:33:12Z  attempt 2  start  resume; done: blockMesh, potentialFoam; solver log at iteration 853; checkpoints: 700 800
2026-10-16T08:34:17Z  attempt 2  end    interrupted (SIGTERM) in simpleFoam; solver log at iteration 1643; checkpoints: 700 800 1500 1600
2026-10-16T08:34:38Z  attempt 3  start  resume; done: blockMesh, potentialFoam; solver log at iteration 1643; checkpoints: 700 800 1500 1600
2026-10-16T08:35:41Z  attempt 3  end    solved: Cd 0.018992 Cl 0.706550 at iteration 2400 (2496 solved over all attempts); simpleFoam done on attempt 3
2026-10-16T08:36:04Z  attempt 4  start  resume; done: blockMesh, potentialFoam, simpleFoam; solver log at iteration 2400; checkpoints: 2300 2400
2026-10-16T08:36:04Z  attempt 4  end    solved: Cd 0.018992 Cl 0.706550 at iteration 2400 (2496 solved over all attempts); simpleFoam done on attempt 3
```

(the recorded login-node test, run smashing-guppy). Attempt 1 was killed at
iteration 853 with checkpoints at 700 and 800; attempt 2 kept the mesh and the
initialization, restarted the solver at 800, and was killed at 1643; attempt 3
restarted at 1600 and solved the case at 2400, 96 iterations solved twice in
all. Then the budget cut attempt 3 too, during its post-processing, so attempt
4 found the case solved and only extracted the results again: the "never solve
a finished case again" rule at work. The `Report` step then says:

```
::notice::solved in 4 attempt(s), 2 of them interrupted and resumed from a checkpoint: Cd = 0.0189923490, Cl = 0.7065502600 (mesh_scale 3). The history is .../case/attempts.log; open .../case/case/case.foam in ParaView to see the fields
```

and publishes `DRAG_COEFFICIENT`, `LIFT_COEFFICIENT`, `ATTEMPTS`,
`INTERRUPTIONS`, `CASE_DIR` and `PARAVIEW_FILE` as outputs. The two failures
are told apart in the same place: a solver that **failed on its own** (it
diverged) ends the run in error at once, whatever is left of the budget, and a
case **still interrupted when the attempts ran out** ends it in error too but
leaves a resumable case: run the workflow again with `case.case_dir` pointing
at it and the next attempt continues from the latest checkpoint.

## The pieces

### 1. Checkpoints: what the solver writes

A restart needs something to restart from. `openfoam-naca`'s **Checkpoints and
Resume** group sets `writeInterval` to `checkpoint_every` iterations and
`purgeWrite` to `keep_checkpoints` in the `controlDict` the simulator writes, so
the solver leaves time directories `100/`, `200/`, ... and deletes the oldest as
it goes (every rank writes its own in a decomposed case). Two settings matter:

- **How often.** An interrupted attempt loses at most `checkpoint_every`
  iterations, and every write costs time and disk. The default, 100, is about
  10 seconds of solving at `mesh_scale` 3.
- **How many to keep: at least two.** A kill can land in the middle of a write.
  The simulator only resumes from a **complete** checkpoint, one where every
  field of `0/` is present and ends with OpenFOAM's closing line, in every
  processor directory; an incomplete one is discarded, and the one before it is
  used. With a single checkpoint kept, a kill during its write would send the
  case back to iteration 0.

### 2. The run script: resume instead of starting over

[`simulator.sh`](../openfoam-naca/app/simulator.sh) always did
`rm -rf case` and solved from scratch. With `RESUME=true` it continues the case
it finds, and the logic is in [`restart.sh`](../openfoam-naca/app/restart.sh),
which it sources. The state is plain files under the case directory:

```
attempts.log                 one start and one end line per attempt
case/restart/inputs          the design and settings the case was built from
case/restart/<stage>.done    blockMesh, decomposePar, potentialFoam, simpleFoam, with the attempt that finished each
case/restart/failed          the stage that failed on its own, and why
case/log.simpleFoam.<n>      the solver log of attempt n (the current one is log.simpleFoam)
```

What `restart_begin` decides at the top of every attempt, in order:

1. **Only a matching case is resumed.** The design parameters, `mesh_scale`,
   `cores_per_case` and the other settings that decide the solution are written
   to `case/restart/inputs`; a case built from different ones starts over (the
   log line says which input changed). Checkpoint settings are not in the
   fingerprint: they change the bookkeeping, not the solution.
2. **A case that failed on its own is refused.** `case/restart/failed` means the
   solver stopped with a non-zero status while nobody was killing it, a diverged
   `simpleFoam` for instance. That is a result, not an interruption: no attempt
   solves it again, and the attempt exits 1 at once.
3. **Finished stages are skipped.** `blockMesh`, `decomposePar` and
   `potentialFoam` each leave a marker when they return 0 and are not run
   again; the mesh, the decomposition and the initial field are kept. A
   `simpleFoam.done` marker means the case is solved: the results are
   extracted again (they are cheap) and the solver is not run.
4. **`simpleFoam` restarts from `latestTime`**: after the incomplete
   checkpoints are discarded and all but the last `keep_checkpoints` removed,
   the latest time directory is where the solver continues. The forceCoeffs
   output of every start is merged, later values winning for the iterations
   solved twice, before the coefficients are averaged.

Two details worth copying. The initial field (`0/`) and the decomposition are
rewritten from the template **unless `potentialFoam` has finished on them**: a
kill during `potentialFoam` leaves `0/U` half written, and the next attempt
would otherwise initialize from a broken file. And the attempts hold a `flock`
on `attempt.lock`, inherited by the solver, so an attempt submitted while the
previous one is still dying waits for it instead of writing the same files.

### 3. The signal: how a kill becomes a recorded interruption

What SLURM does at the walltime decides most of the design. It sends SIGTERM
to the **batch script alone**, not to its children (verified on gcptest: a
`sleep` started by the script outlived the signal until the SIGKILL 30 seconds
later, SLURM's `KillWait`). The solver would run on, unrecorded, until the
SIGKILL, mid-write or not. So the signal is passed down two steps:

- `case.sh`, the script `openfoam-naca`'s preprocessing writes and the submitter
  turns into the batch script, runs the simulator in the background with a
  `trap` that forwards SIGTERM, SIGINT and SIGHUP to it, then `wait`s (bash
  runs a trap at once while it waits on a background job, only once the command
  ends while it waits on a foreground one).
- The simulator (`restart.sh`) runs every OpenFOAM tool through
  `run_interruptible`, the same background-and-wait pattern, and its trap
  forwards the signal to the tool's whole process tree (`mpirun`, its proxies
  and the ranks), remembers it, and ends the attempt with
  `attempts.log` saying *interrupted (SIGTERM) in simpleFoam at iteration N*
  and exit status 128 + signal. A signal that arrives between tools ends the
  attempt before the next one starts.

The platform's cancel of an attempt (the budget expired, the run canceled) goes
the same way: the submitter's cleanup `scancel`s the job or kills the process
group, and the trap sees SIGTERM. A node that is preempted or lost sends
nothing: the next attempt finds a start line without an end line and writes
*interrupted without a record (killed outright or node lost)* for it. Either
way, the distinction the loop relies on is simple: **a non-zero status with no
signal remembered is the tool failing on its own**.

### 4. The loop: a retried subworkflow step

[`general.yaml`](yamls/general.yaml) has two jobs. `preprocessing` validates
the form, prepares the case directory (`case/` under the run's job directory,
or the `case.case_dir` given) and prepares the OpenFOAM environment once, so a
cold cluster installs OpenFOAM before the loop and not inside an attempt whose
budget might cancel the install. `solve` is the loop:

```yaml
- name: Solve (One Attempt per Retry)
  retry:
    max-retries: ${{ inputs.restart.max_restarts }}   # restarts after the first attempt
    interval: 10s
    timeout: ${{ inputs.restart.attempt_timeout }}     # bounds ONE attempt; defaults to 30 s
  uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/openfoam-naca-restart/yamls/attempt.yaml
    attempt: ${{ env.PW_WORKFLOW_STEP_CURRENT_RETRY }}
    case_dir: ${{ needs.preprocessing.outputs.CASE_DIR }}
    ...
```

A retried step re-runs while it exits non-zero, so the subworkflow's exit
status is the loop control. **`timeout` is always set**: it defaults to 30
seconds per attempt and cancels the whole attempt, every job of the
subworkflow, the scheduler job included. It must cover queue time, node boot
(minutes on a cloud cluster) and the walltime; on the login node it is the
only interruption there is.

[`attempt.yaml`](yamls/attempt.yaml) is one attempt: the **entire**
`openfoam-naca` workflow (its preprocessing reruns every time, idempotent and
cheap: the checkout, the environment check, `params.in`, `case.sh`), called on
the shared case directory with `restart.resume: true`, and then a step that
reads the case's state:

```yaml
- name: OpenFOAM (Resume the Case)
  ignore-errors: true          # openfoam-naca fails whenever there is no results.out: expected while interrupted
  uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/openfoam-naca/yamls/general.yaml
    ...
- name: Over or Interrupted
  run: |
    # case/restart/failed  → exit 0: over, the case failed on its own (not retried)
    # results.out + simpleFoam.done → exit 0: over, solved
    # otherwise            → exit 1: interrupted, the parent retries
```

Why the extra YAML: `openfoam-naca` ends in error whenever it leaves no
`results.out`, which is right for its other callers but says nothing about
*why*. Retrying it directly would retry a diverged case too, up to
`max_restarts` times, with a scheduler job each time. The intermediate workflow
turns the state files into the one bit the retry understands. (`ignore-errors`
on a `uses:` step lets the job go on after the failed call; verified on the
platform, 2026-10-16.)

### 5. The verdict

The `Report` step runs `if: ${{ always }}`, whether the loop stopped by
decision or by running out of retries, and reads the case directory, never the
step's status: `case/restart/failed` is the solver's own failure (error, with
the reason and the log paths), `results.out` with `simpleFoam.done` is success
(the coefficients, the attempt and interruption counts), anything else is a
case still interrupted after `max_restarts + 1` attempts (error, with the case
directory to resume from). The run's outputs come from the same files.

## Inputs

| Group | Input | Meaning |
|---|---|---|
| `cluster` | `resource`, `scheduler`, `cores_per_case`, `slurm`, `pbs` | as `openfoam-naca`: the login node, or one SLURM/PBS job of `cores_per_case` ranks per attempt. **`slurm.time` defaults to `00:02:00`**, the interruption of the demo; a PBS form sets the walltime in its directives |
| `case` | `max_camber`, `camber_position`, `thickness`, `angle_of_attack` | the design, as `openfoam-naca` |
| | `mesh_scale` | **default 3** (a few minutes), so the case outlasts the walltime |
| | `case_dir` | empty: `case/` under this run's job directory; an earlier run's case directory continues its case |
| `restart` | `max_restarts` | restarts after the first attempt (the step's `max-retries`), default 10 |
| | `attempt_timeout` | the budget of one attempt (`75s`, `30m`, `2h`), default `30m`: queue + node boot + walltime when scheduled, the only interruption on the login node |
| | `checkpoint_every` | iterations between checkpoints, default 100 |
| | `keep_checkpoints` | checkpoints kept on disk, default 2 |
| `software` | `openfoam_load` | commands that put OpenFOAM on PATH; empty installs it from conda-forge in preprocessing |

Images are not offered here; open `case/case/case.foam` in ParaView as the
`openfoam-naca` README describes. There is one variant, `general`:
`attempt.yaml` calls `openfoam-naca/yamls/general.yaml`, so a scheduled run on
an `existing` HPCMP or NOAA resource (SLURM account, QoS, node type) would need
an attempt YAML calling the `hsp` or `noaa` variant, the way `dakota-openfoam`
ships `iteration-naca-hsp.yaml` and `iteration-naca-noaa.yaml`.

## What a run leaves

In the case directory (`CASE_DIR` in the log, `case/` under the job directory
by default):

```
attempts.log           the history: one start and one end line per attempt
attempt.lock           the lock the running attempt holds
params.in, results.out, exit_code, case.sh, run.<job>.out   openfoam-naca's own files, from the last attempt
case/                  the OpenFOAM case: the last keep_checkpoints time directories, the final one reconstructed
case/restart/          inputs, <stage>.done, failed, solver.attempt
case/log.simpleFoam.<n>, case/log.simpleFoam   every attempt's solver log
```

Every attempt is one `openfoam-naca` run inside the retried step; the platform
shows only the last one under `Solve`, so read `attempts.log` (the `Report`
step prints it) and the per-attempt solver logs for the earlier ones.

## Tests

Recorded under [`tests/general/`](tests/general/), on the cloud cluster
`gcptest` (`pw cluster ls`):

| Test | Interruption | What it checks |
|---|---|---|
| `gcptest-login-node` | the attempt budget: `attempt_timeout` 75 s against a `mesh_scale` 3 case on one core | the platform cancels each attempt, the submitter's cleanup kills the process group, the next attempt resumes; the run completes |
| `gcptest-slurm-mpi2-walltime` | the walltime: `00:02:00` against the same case on 2 ranks | SLURM's SIGTERM reaches the batch script, is forwarded to `mpirun`, the decomposed case resumes; the run completes |
| `gcptest-login-node-diverged` | none: a design that diverges (16 ranks on the base mesh with the rank floor disabled through `openfoam_load`) | the first attempt fails on its own, the loop stops at once, the run ends in error with the reason (`_test.expect: error`) |

```bash
python3 tools/tests/run-workflow-test.py workflows/openfoam-naca-restart/tests/general/gcptest-login-node.json
```

The verdict of each attempt, and of the run, is in `attempts.log` and the
`Report` step; `pw workflows runs errors <slug>` shows the failures. A
`pw workflows runs cancel` of a scheduled run mid-solve was checked by hand as
well: the submitter's cleanup `scancel`s the job, the simulator records the
interruption with its checkpoints, nothing is left on either node, and a later
run given the case directory (`case.case_dir`) resumes from the last checkpoint
and solves it.

## Bringing your own simulation tool

What this example does, and what to do for another solver:

1. **Make the solver write checkpoints**, at an interval that balances lost
   work against write cost, and keep at least two. Decide how your tool tells a
   complete checkpoint from a torn one (a closing line, a checksum, a manifest
   written last, an atomic rename) and check it before resuming.
2. **Make the run script resume**: a fingerprint of the inputs so only a
   matching case is continued; a marker per expensive stage so it is not
   redone; a start-from-latest-checkpoint for the solver; a marker for "solved"
   so a finished case is never solved again; a record for "failed on its own"
   so a diverged case is never retried; one line per attempt in a log. Keep the
   state in plain files next to the case: they are what people read when a
   run looks wrong, and what a later run continues from.
3. **Handle the signal**: find out who receives it under your scheduler (SLURM:
   the batch script only), forward it down to the solver, run long commands in
   the background and `wait` so the trap runs at once, and exit with
   128 + signal. Treat "non-zero and no signal seen" as the solver's own failure.
4. **Wrap the case workflow, do not change it**: the case workflow stays usable
   on its own (and by other callers) with resume off; the restart workflow calls
   it whole from a retried step with the state directory as an input, maps the
   state to exit 0 / exit 1 in a thin attempt workflow, and sets the retry
   `timeout` for the whole attempt.
5. **Report from the state files** in an `if: always` step: solved, failed on
   its own, or out of attempts and resumable, and record the tests that
   produced each.

## Files

| File | Role |
|---|---|
| `yamls/general.yaml` | the form, preprocessing (validation, case directory, the OpenFOAM environment once), the retried `Solve` step, the `Report` step |
| `yamls/attempt.yaml` | one attempt: the `openfoam-naca` call with `resume: true` and the exit 0 / exit 1 verdict |
| `tests/general/` | the three recorded tests |
| `thumbnails/restart-loop.svg` | the picture above |

The simulation side lives in `openfoam-naca`: `app/simulator.sh` (the run
script), `app/restart.sh` (the resume logic), and its YAMLs' **Checkpoints and
Resume** group and `case.sh`.
