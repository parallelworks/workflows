# Shape: a batch job

The jobs after preprocessing for a workflow that runs a script to completion and
fails when it fails: a command list (`workflows/activate-batch`), a benchmark
(`workflows/benchmarks`), one simulation case (`workflows/openfoam-naca`), a fan-out
over SLURM workers (`workflows/3dcs`), a training run (`workflows/physicsnemo`). No
endpoint, so no `wait_for_endpoint` job and no skip file. Copy `activate-batch` (the
smallest) or `benchmarks` (a results job, figures, a cleanup script). The platform
facts are [../activate-platform.md](../activate-platform.md) §5 (`script_submitter`).

## The jobs

1. **preprocessing** assembles the script the submitter runs and publishes its path.
   The script records its own exit status, because `script_submitter` never forwards
   it (reference §5: the submitter polls the pid or the queue and completes whatever
   the script returned):

   ```bash
   trap 'echo $? > ${PWD}/commands.exit' EXIT      # activate-batch
   ```

   Trap the signals too (`trap 'exit 143' TERM`, `130` INT) and run the long command
   in the background with `wait $!`, or a `scancel` records `0` and an MPI job keeps
   writing past the kill (pitfalls, "A batch script killed by `scancel`"). Remove the
   exit file before submitting, so a stale one from a re-run cannot pass.
2. **The submitter job** (`script_submitter`, `benchmark`, `run_case`, `training`):
   the `script_submitter` subworkflow with the variant's `with:` block,
   `submit_and_exit: false`, no `skip_cleanups_file`. `define_cleanup_script: true`
   with a script that kills what the work spawned (MPI ranks, containers) when
   `scancel`/`qdel` alone would not; `false` otherwise, and then `cleanup_script_path`
   is not needed.
3. **The check**: a step after the `uses:` in the same job (`activate-batch`) or a
   `results` job that `needs:` both (`benchmarks`, `openfoam-naca`, `physicsnemo`). No
   exit file means the script never ran to its end (killed, walltime exceeded, node
   failure); a non-zero one means it failed. Either exits 1 with an `::error` that
   says which and tails the output. A `results` job also summarizes: `::notice::`
   lines with the numbers, files left in the job dir (`results.out`, figures), values
   through `$OUTPUTS`.

Inside the submitted script, paths are relative to the submitter's `rundir` (it `cd`s
there; a compute node may not export `PW_PARENT_JOB_DIR`, but `inputs.sh` carries it).
Either pass `rundir: ${{ env.PW_PARENT_JOB_DIR }}` so the script runs in the job dir,
or write the exit file to an absolute path preprocessing published (`activate-batch`);
without `rundir` the submitter runs in `subworkflows/<job>/step_0/` (pitfalls, "The
submitter runs the start script in its own directory").

## A runner other workflows call

A batch workflow that solves one design from a params file (`openfoam-naca`) is also
a building block: it lists its design parameters in `app/design-parameters.txt`,
checks the params file with `tools/utils/check-params.sh` before submitting, writes
`results.out` atomically and always writes `exit_code`. The contract, and how a
driver feeds it: [../design-parameters.md](../design-parameters.md) and
[composed.md](composed.md).

## What "done" and "clean" mean here

- The run completes when the work does. The test sets `_test.endpoint: false`, so pass
  = the run reaches `completed` (`tools/tests/README.md`). A failure-path test sets
  `_test.expect: error`; send an input the form's `min`/`max` forbids rather than
  `""`, which is default-filled (pitfalls).
- Cancel mid-flight: the submitter's cleanup runs `scancel`/`qdel` or kills the
  process group, then the cleanup script. Confirm with `squeue`/`qstat` and `ps -x`
  that the work and anything it spawned are gone.
- `pw workflows runs errors <slug>` exits non-zero when an `::error` annotation
  exists, so the check step's annotation is what a caller or a CI gate sees.
- Cloud-burst nodes take minutes to boot (`idle~ → CF → RUNNING`); the login-node
  mode (`scheduler: false`) is the fast check, the scheduler mode the real one.

## A batch job beside a page

`physicsnemo` (TensorBoard over a training run) and `dakota-openfoam` (Design Explorer
over an optimization loop) add a detached endpoint started from preprocessing, the
callable-step way ([composed.md](composed.md)). The run still ends when the work does;
the page outlives it until `pw endpoints delete`.
