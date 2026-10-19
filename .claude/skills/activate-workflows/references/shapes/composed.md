# Shapes: a callable step, and a workflow composed of them

Two sides of one pattern. A **callable step** runs on the login node, submits no
scheduler job and keeps one `general.yaml` for every platform: `workflows/doe` (a
sampler), `workflows/dakota` (one optimizer step), `workflows/design-explorer` (a page
over a study), `workflows/wait_for_endpoint`. A **composed** workflow is a YAML with
no code of its own that calls such steps and runners as subworkflows:
`workflows/doe-openfoam` (sampler, then a matrix of `openfoam-naca`, then the page) and
`workflows/dakota-openfoam` (a loop of optimizer step, matrix and decision, with the
page beside it). The READMEs show the wiring; the platform facts are
[../activate-platform.md](../activate-platform.md) §3 (subworkflow calls, matrix,
retries).

## A workflow others can call

- **Its form is its interface.** Every path it reads or writes is an input
  (`cases_dir`, `params_file`, `case_dir`), so a caller passes paths under its own
  `${PW_PARENT_JOB_DIR}` and reads what is left there. Data crosses the call as
  files: no workflow here reads a subworkflow step's outputs (`doe-openfoam` reads the
  sampler's `doe.env` from the `cases_dir` it passed). Nested input groups pass
  through `with:` as nested maps, never dotted keys, so a standalone form is its own
  `with:` block.
- **One `general.yaml`.** Nothing differs between platforms on a login node; a site
  difference a hostname can decide (where software installs on NOAA) is runtime logic
  in the one file (`dakota`).
- **Fail in seconds, with the tool's own message.** Validate inputs and probe the
  software environment (the solver on PATH, `module show`) before any work.
- **It runs on its own from the platform** too, which is how it is tested
  (`tests/general/`, `_test.endpoint: false` unless it serves a page).

### A callable step that serves a page

`design-explorer`, and TensorBoard inside `physicsnemo`, start their server from a
plain step, since there is no submitter for it to outlive:

1. Write a launcher that `exec`s
   `pw endpoints run --name <service>-${PW_RUN_SLUG} -- <server> --port {port}` and
   start it detached: `setsid ./start.sh > server.out 2>&1 < /dev/null &` (`nohup`
   where there is no `setsid`).
2. Check the process is alive a few seconds later and fail loud if it is not.
3. Call the `wait_for_endpoint` subworkflow with the endpoint name, the login node as
   `host`, a health `path` and `budget` for the server, and no `skip_cleanups_file`:
   it probes the URL until the page answers (`design-explorer`: `/healthz`, 120 s).
4. Publish the URL (`$OUTPUTS`, and a `::notice::` that also says how to remove it:
   `pw endpoints delete <name>`).
5. Add a job `stop_server_if_unhealthy` with `needs: [preprocessing]` and
   `if: ${{ !success() }}` that deletes the endpoint and kills the server from fixed
   paths, never from upstream outputs (a canceled job publishes none). A step
   `cleanup:` cannot do this: it runs when its job ends, success included, and would
   kill the server right after launch. The handler also runs when a caller's run is
   canceled, so callers need no handler of their own (pitfalls).

The page outlives the run until `pw endpoints delete`; the test's pass is the endpoint
listed, the runner's default lane.

## Composing them

- **Call, don't copy.** `uses: github/parallelworks/workflows@canary` with
  `$yaml: workflows/<name>/yamls/general.yaml` and the callee's inputs in `with:`;
  `--dry-run` checks the required ones. Calls nest at most five deep and a workflow
  may never call itself; `dakota-openfoam` → its iteration YAML → `openfoam-naca` →
  `script_submitter` is already four.
- **Preprocessing validates first.** Range-check the form, probe the environments the
  callees need, then call the sampler (or initialize the loop's state files) and
  publish the counts the matrix guard reads.
- **A matrix of evaluators**, one `openfoam-naca` call per design, needs a static size:
  a range over a form input (`job_id: ${{ 1 range inputs.doe.n_cases + 1 }}`, slots
  `1..n_cases`; the form's `max: 256` keeps it inside the platform's 1000-reference
  budget per run: pitfalls), a job-level guard against
  the runtime count (`if: ${{ matrix.job_id <= needs.preprocessing.outputs.N_CASES }}`),
  `fail-fast: false` so one failed design does not cancel the others, `max-parallel`
  from the form. Per-slot data reaches the callee as paths built from `matrix.job_id`
  (`case_${{ matrix.job_id }}/params.in`): a matrix instance cannot read its own
  outputs or look an upstream map up by key.
- **A results or decide job** with `needs: [preprocessing, workers]` and
  `if: ${{ always }}` reads the files the cases left (`results.out`, or `exit_code`
  for a case that ran and failed) and writes the table whatever happened to the cases;
  `doe-openfoam` warns about the failed ones and fails the run only when none solved.
- **A loop** is a retried `uses:` step: the iteration YAML exits 1 while the optimizer
  wants another generation and 0 to stop; `max-retries` is the form's iteration cap,
  and `timeout` is sized for a whole iteration (queue, node boot, work: a form input,
  `iteration_timeout`) because it defaults to 30 s per attempt. State lives in files
  under the job dir (attempt ≠ iteration: keep the counter in a file), and a trailing
  `if: ${{ always }}` step maps the state file (CONVERGED / CONTINUE / FAILED) to the
  run's verdict. Feed ran-and-failed points back as failures rather than re-proposing
  them (pitfalls, "A deterministic optimizer").
- **The live page** is a call to `design-explorer` from preprocessing, before the
  work, with the study directory: the page follows the study as cases finish, and its
  own `!success()` handler cleans up.
- **The only coupling is files**: the driver writes `params.in` with the runner's
  design-parameter names, the runner writes `results.out` and `exit_code`
  ([../design-parameters.md](../design-parameters.md)).

- **A loop whose callee must keep failing for its other callers**: a runner that fails
  whenever it leaves no result (openfoam-naca) cannot, as is, tell a retried step "over"
  from "try again". The verdict has to be the status of the first failing step of the
  sub-run (a later `if: always` step cannot undo a failed one), so give the runner a
  hidden input only the loop sets (`restart.attempt`): with it, the results step exits
  0 on a case that failed on its own (final) and 1 on an interrupted one; the loop
  variant retries the runner directly and its `Report` step (`if: always`) reads the
  case's files for the run's verdict (`workflows/openfoam-naca/yamls/general-restart.yaml`).
  Depth: restart → runner → script_submitter, three. For a callee you cannot change,
  a thin attempt YAML with `ignore-errors` on the call does the same one level deeper.

## Tests

The variant is the YAML's basename (`tests/general-naca/` for `general-naca.yaml`).
`_test.endpoint: false` when no page is served, the default lane when one is. A short
study (two or three cases, one iteration) keeps the recorded test minutes long.
