# AGENTS.md — Parallel Works Workflows Repository

## Project Overview

This repository is the home of the **ACTIVATE platform workflows** for
[Parallel Works](https://parallelworks.com): **one workflow = one self-contained
directory** under `workflows/`. A workflow is a YAML form plus job graph that runs code
on a resource and leaves something behind: a web service served as a **`pw` endpoint**,
a batch job's results, a study, or a step other workflows call. Which of those it leaves
behind is its **shape** (below); the shapes share one preprocessing job, one set of
rules and one test runner. Provenance and anything predating this layout: MIGRATION.md.

A workflow directory holds:
- **Variant YAMLs** (`workflows/<name>/yamls/<variant>.yaml`) — the UI form + job
  orchestration, one file per platform variant (`general`, `emed`, `hsp`, `noaa`,
  `*k8s*`); a single `general.yaml` where nothing differs between platforms
- **Runtime files** (`app/`, or one implementation subdir per runtime) — the scripts
  preprocessing assembles and the support files they need (conda env YAMLs, container
  defs, helpers); the only subtree a run checks out
- `README.md`, build tooling (defs, `build-container.sh`), marketplace thumbnails in
  `thumbnails/`, and the recorded end-to-end tests in `tests/<variant>/`

The process for building one (develop on the target machine first, wrap, test, debug)
is the `activate-workflows` skill (`.claude/skills/activate-workflows/SKILL.md`); its
`references/` hold the platform facts, the pitfalls real runs taught, and one file per
shape. The human how-to is `DeveloperGuide.md`.

## Official platform documentation (authoritative — consult when in doubt)

- Building workflows: <https://parallelworks.com/docs/run/workflows/building-workflows>
  — with the [YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields),
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions),
  and [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions) subpages
- Endpoint sessions: <https://parallelworks.com/docs/run/sessions/endpoints>
- `pw endpoints` CLI: <https://parallelworks.com/docs/cli/pw/endpoints> (full CLI: <https://parallelworks.com/docs/cli>)

## Repository structure

```
workflows/<name>/yamls/      # the workflow's variant YAMLs (general.yaml, hsp.yaml, k8s.yaml, ...)
workflows/<name>/app/        # runtime files: scripts + support files — the ONLY subtree
                             # the workflow sparse-checkouts at run time
workflows/<name>/<impl>/     # multi-implementation workflows use impl subdirs instead of app/,
                             # named after the form input values (n8n-docker, n8n-singularity,
                             # kasmvnc-singularity, ollama-gguf-container, librechat-singularity, ...)
workflows/<name>/            # README + build tooling (defs, build-container.sh); other
                             # non-runtime dirs (docs/, scripts/, fixtures/) sit beside app/
workflows/<name>/thumbnails/ # marketplace thumbnails (one per registered variant look)
workflows/<name>/tests/<variant>/  # end-to-end tests: <test>.json form inputs + <test>.csv results
workflows/script_submitter/v3.6/  # shared subworkflow: SLURM/PBS/SSH script submission
workflows/wait_for_endpoint/      # shared subworkflow: wait for an endpoint, probe its URL, release the submitter
workflows/doe/, workflows/dakota/, workflows/openfoam-naca/, workflows/design-explorer/
                             # building blocks: a sampler, an optimizer step, a case runner, a study
                             # page; composed by doe-openfoam and dakota-openfoam, which have no code
                             # of their own
workflows/probe/             # PROBE: runs a platform's workflow tests (definitions in a tests repository,
                             # parallelworks/probe-tests-activate-parallel-works for activate.parallel.works)
                             # and serves the results dashboards; app/ holds its Python code
tools/oras, tools/utils      # shared runtime tools, referenced as tools/... from run dirs
                             # (tools/utils/{miniforge,prepare-env}.sh: conda installs + env files;
                             # tools/utils/check-params.sh: the design-parameters check)
tools/tests/                 # the test runner (run-workflow-test.py) and its README
tutorials/                   # staged, runnable lessons on the workflow system
docs/                        # developer + AI docs
.claude/skills/activate-workflows/  # Claude Code skill for building workflows here
.claude/agents/              # Claude Code subagents: workflow-reviewer (read-only review of a workflow directory)
.claude/hooks/               # the scripts those agents' frontmatter hooks run (workflow-reviewer-guard.py)
```

## Versioning

- **One version only — the latest.** No version suffixes in filenames or references:
  `general.yaml`, `controller.sh`, `start-template.sh`. Git tags version the repo.
  (Where older versions live: MIGRATION.md.)
- `script_submitter` keeps an explicit version directory (`v3.6`) because almost every
  workflow calls it: a change that is not backward compatible ships as a new directory
  (`v3.7`, `v4.0`) beside it, the callers move over one by one, and the old directory
  is removed once none is left on it. Marketplace registrations reference the path too.

## Workflow shapes

Every YAML on a compute cluster starts the same way, in a first job (**preprocessing**
in most) on the resource's login node: `parallelworks/checkout` of this repo (sparse:
`workflows/<name>/app` or an impl subdir, plus `tools/...` when the scripts use the
shared tools), `inputs.sh` written from the form values and the `PW_*` environment,
`inputs.sh` + `controller.sh` run inline (idempotent setup, with internet), and whatever
script the next jobs run assembled from `inputs.sh` + a template, its path published
through `$OUTPUTS`. What follows is the shape. Each shape's jobs, what "done" and
"clean" mean for it, and what its test checks are in one file under
`.claude/skills/activate-workflows/references/shapes/`; read it before building or
reviewing one.

Apart from Kubernetes, the mechanics are the same for every shape: the controller
installs into a shared directory on the login node (`service_parent_install_dir`,
visible from the compute nodes), and the script that does the work is handed to the
`script_submitter` subworkflow, which runs it on the login node (`scheduler: false`) or
submits it to SLURM/PBS (`scheduler: true`). **Call subworkflows; compose, never
copy.** `script_submitter`, `wait_for_endpoint`, `doe`, `dakota`, `openfoam-naca` and
`design-explorer` exist to be called; never hand-write job submission, port allocation
or tunnel logic; write a new workflow so it can be called in turn.

| Shape | The run ends when | After preprocessing | Examples | Read |
|---|---|---|---|---|
| **Endpoint service** (most workflows) | the service answers its URL; it outlives the run until `pw endpoints delete` | `session_runner` (`script_submitter`) + `wait_for_endpoint` | `webshell` (smallest), `jupyterlab`, `streamlit` (Singularity), `ollama` | `shapes/endpoint.md` |
| **Batch job** | the script finishes; the run fails when it fails | `script_submitter` once, then a step that reads the exit file the script wrote | `activate-batch` (smallest), `benchmarks`, `3dcs`, `cwl-mpi-hello-world`, `openfoam-naca`, `probe`'s `general_run_tests.yaml` | `shapes/batch.md` |
| **Callable step** (login node only) | its steps finish; one `general.yaml` for every platform | plain `run:` steps; a detached `pw endpoints run` with a `!success()` handler when it serves a page | `doe`, `dakota`, `design-explorer`, `wait_for_endpoint` | `shapes/composed.md` |
| **Composed** | the study or loop finishes | `uses:` of the rows above: a matrix of evaluators, retry-as-loop, a live page | `doe-openfoam`, `dakota-openfoam`, `openfoam-naca`'s `*-restart.yaml` | `shapes/composed.md` |
| **Kubernetes** | never: cancelling the run is the teardown | the sidecar pod jobs; no submitter, nothing checked out | `mlflow/yamls/k8s.yaml` (k8s-only), `openvscode/yamls/general_k8s.yaml` (hybrid) | `references/k8s-workflows.md` |

The rows combine: a **service plus the work that uses it** (`burst-render-demo`,
`monte-carlo-pricing`, `dask-slurm`, `ray-cluster`, `app-testbed`: jobs that `need`
`wait_for_endpoint`, so the run ends when the endpoint answers *and* the work is done),
a **batch job beside a page** (`physicsnemo`: training as a batch job, TensorBoard
started the callable-step way; `dakota-openfoam`: the loop, with `design-explorer`
beside it), **several services in one run** (`librechat`'s `-all` variants, `probe`:
one submitter + wait pair per endpoint). Whatever the combination, every shape keeps
the same invariants:

- **The run ends on evidence** — a health probe that saw the URL answer, an exit file
  the script wrote — and **fails loud without it**. `script_submitter` never forwards
  the script's exit status; the workflow's own steps do.
- **Whatever outlives the run has a teardown** (`pw endpoints delete <name>`, or
  cancelling a Kubernetes run), and the README says what it is.
- **A cancel at any moment leaves nothing behind**: no process, scheduler job,
  container, listener or endpoint record.
- **The test is recorded** (Testing and debugging, below).

### Endpoint service

- The service is served through `pw endpoints run` under a name
  `<service.name>-${PW_RUN_SLUG}`; the hidden `service.name` input is the **endpoint
  name prefix**, not a checkout path. Keep it stable: renaming it changes endpoint names.
- Endpoint names must be lowercase `[a-z0-9-]`. A name that comes from a form input must
  be folded before it reaches `pw endpoints`, and the wait job must look for the same
  folded name (the `endpoint_name` input in `workflows/ollama/yamls/general.yaml`).
- The `wait_for_endpoint` job is two steps: the `wait_for_endpoint` subworkflow
  (`uses: github/parallelworks/workflows@canary`,
  `$yaml: workflows/wait_for_endpoint/general.yaml`, with `early-cancel: any-job-failed`)
  and `parallelworks/cancel-jobs` on the submitter. Pass `endpoint_name`, `host` (the
  login-node IP) and `skip_cleanups_file`; set `healthy`, `budget` and `path` per service
  (how to choose them: `workflows/wait_for_endpoint/README.md`). It probes the URL
  with the run's `PW_API_KEY` and touches the `SKIP_CLEANUP` file once the service
  answers; if it never does, the job fails without the file and the submitter's
  cleanup tears the job down. **The workflow owns this health check**, not the test
  runner. On Kubernetes keep the `pod.running` marker step first and omit `host` and
  `skip_cleanups_file`.
- A **fixed endpoint name** (`hpc_status`'s `hpc-status`, `app-testbed`'s `apptest`) has
  to be freed in preprocessing before the wait job looks it up, or the wait finds the
  previous instance answering (`hpc_status`'s `controller.sh`); `app-testbed` reuses
  the running instance on purpose unless **Restart server** is on.
- A service that only ever runs on the login node (`design-explorer`, TensorBoard in
  `physicsnemo`) starts `pw endpoints run` detached from a plain step
  (`tutorials/endpoint-workflows` Stage 3) with a `stop_server_if_unhealthy` job under
  `if: ${{ !success() }}`, instead of through the submitter.

### Batch job

- The submitted script records its own exit status (`trap 'echo $? > <file>' EXIT`,
  signals trapped too); preprocessing removes a stale exit file before submitting; a
  step or job after the submitter fails the run with an `::error` when the file is
  missing (the script never ran to its end) or non-zero. `submit_and_exit: false`, no
  `skip_cleanups_file`.
- A **runner** that solves one design from a params file (`openfoam-naca`) lists its
  design parameters in `app/design-parameters.txt` and checks the params file against it
  with `tools/utils/check-params.sh` before solving; drivers and callers (`doe`, `dakota`,
  `doe-openfoam`, `dakota-openfoam`) only write `params.in` with those names. The contract:
  `.claude/skills/activate-workflows/references/design-parameters.md`.
- A batch job that outlasts its walltime or runs on preemptible nodes is made
  **resumable**, not given a longer walltime: the solver writes checkpoints (two kept,
  a torn one discarded), the run script resumes only a matching case, skips the stages
  done, never solves a solved or self-failed case again and logs every attempt, the
  batch script forwards the scheduler's SIGTERM (which reaches it alone) down to the
  solver, and a loop variant calls the whole case workflow from a retried step with a
  hidden input that makes a final failure complete the sub-run, so the retry stops on
  it and resumes only interruptions (`openfoam-naca/yamls/general-restart.yaml`;
  `shapes/batch.md`, "A resumable batch job").

### Callable step and composed workflow

- A callable step's **form is its interface**: every path it reads or writes is an
  input, data crosses the call as files under the caller's `${PW_PARENT_JOB_DIR}`, and
  it runs on its own from the platform, which is how it is tested.
- It runs only on the login node and submits no scheduler job, so it keeps a **single
  `general.yaml`**: nothing differs between platforms, and a caller on any platform
  calls that one file. A site difference a hostname can decide is runtime logic inside it.
- A composed workflow **calls, never copies**: `uses: github/parallelworks/workflows@canary`
  with `$yaml: workflows/<name>/yamls/general.yaml` and the callee's form as its `with:`
  block (nested groups as nested maps). Calls nest at most five deep.

### Kubernetes

`yamls/k8s.yaml` is k8s-only, `yamls/general_k8s.yaml` hybrid. The same endpoint,
registered by a `pw-cli` sidecar inside the pod; the run stays alive and **cancelling
the run is the teardown**. Everything else Kubernetes — anatomy, dev loop, inputs,
tests, debugging, cluster facts — is in one place:
`.claude/skills/activate-workflows/references/k8s-workflows.md`.

To convert an older session-tunnel workflow to the endpoint shape, follow
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`
(which workflows those are and where they live: MIGRATION.md).

## Critical rules and conventions

### Scripts
- Scripts MUST be **idempotent** — safe to re-run (check before installing).
- All configuration arrives via the sourced `inputs.sh` — no hardcoded paths/values.
  `PW_API_KEY` stays out of `inputs.sh`; a script that needs it reads the runtime env.
- `controller.sh` runs on the login node (internet access) before anything is
  submitted; the submitted script may run on a compute node without it.
- A **service** binds `0.0.0.0` on the port `pw endpoints run` assigned (the `{port}`
  token or `$PORT`; `--port N` when a client must know it), stays in the foreground for
  the service's life (`pw endpoints run` blocks; a server started in the background
  needs a `wait` or `sleep inf` after it), and exits non-zero when the endpoint never
  registered (copy the tail of `workflows/webshell/app/start-template.sh`). A check
  that must fail the run goes **before** `pw endpoints run`: the run completes the
  moment the URL answers.
- Write **`cancel.sh`** first thing in the start script for anything the submitter's
  process-group kill and `pw endpoints delete` will not reach: a `screen` session, a
  docker container, a daemonizing app that re-parents to PID 1. A service with
  nothing of the kind needs none.
- A **batch** script records its exit status in a file (Batch job, above) and runs a
  long command in the background with `wait $!` so a `scancel` is recorded too.
- Use `${PW_PARENT_JOB_DIR}` for job-dir references in scripts and `run:` steps, and
  `service_parent_install_dir` (default `${HOME}/pw/software`) for installs. Keys the
  platform resolves itself take shell variables literally: a job's `working-directory`,
  and a `with:` value that becomes one (the submitter's `rundir`), must use
  `${{ env.PW_PARENT_JOB_DIR }}` instead. Inside a submitted script, paths are relative
  to the submitter's `rundir` (it `cd`s there).
- Shared tools are referenced as `tools/oras/...` / `tools/utils/...` relative to the
  run directory (the YAML sparse-checkouts them alongside `workflows/<name>`).
- Pull ghcr/ORAS artifacts through `tools/oras/libs.sh:oras_pull_file` (it retries —
  ghcr intermittently rate-limits anonymous pulls) and keep the packages **public**;
  verify anonymous access before shipping.
- `set -o pipefail` and `set -x` so the trace in `run.<JOBID>.out` shows every command;
  fail loud on a missing path or a bad input rather than carrying on.

### Workflow YAMLs
- **The repo is fetched from GitHub at runtime**: `parallelworks/checkout` steps pull
  `https://github.com/parallelworks/workflows.git` (branch **canary**) and subworkflow
  steps use `uses: github/parallelworks/workflows@canary` with
  `$yaml: workflows/<name>/yamls/<variant>.yaml`.
  Changes only take effect once pushed to that branch.
- Checked-out paths are repo-relative: scripts materialize at
  `<rundir>/workflows/<name>/app/...` (or `.../<impl>/...`) — reference them with
  that full prefix, including paths composed from variables. Nothing but runtime
  files sits under `app/`: a glob in preprocessing sweeps the whole directory.
- `permissions: ['*']` on every workflow that runs `pw` (`pw agent open-port` is the
  one exception); without it a `pw` call inside the run gets `401`.
- The resource is the top-level `resource` input (`compute-clusters`, read as
  `${{ inputs.resource }}`) on every variant; the `cluster` group holds the scheduler
  fields (scheduler/slurm/pbs), hidden and ignored as a whole when the resource has no
  scheduler; the rest of the form is grouped by what it configures (`service` for a
  served app; `case`, `doe`, `optimizer`, `software`, ... elsewhere), read as
  `${{ inputs.<group>.* }}`.
- **Variants exist for what differs between platforms**: the submitter
  (`workflows/script_submitter/v3.6/<variant>.yaml`), the SLURM/PBS form fields, install
  paths. Support both SLURM and PBS (`scheduler: true` submits; `false` runs on the
  login node). Copy the `cluster` form and the submitter's `with:` block from the same
  variant of a sibling workflow; `--dry-run` does not catch a mismatch.
- **Code that several variants share is written once**, so a change lands once and
  the variants differ only where the platform does. A step body only this workflow
  runs lives in a script under `app/`, called from a one-line step with its inputs as
  environment variables (`openfoam-naca`'s `read-results.sh`, `OUTPUTS` passed
  through). Logic many workflows call, or that takes several steps or jobs, is a
  subworkflow they call (`wait_for_endpoint`, `script_submitter`).
- Multi-implementation workflows select their script subdir via a runtime input
  (`container_runtime`, `service.container_runtime`, `service.name`): the input
  **values must match the impl subdirectory names** under `workflows/<name>/`.
- Pass values between jobs as `KEY=value` lines appended to `$OUTPUTS`, read with
  `${{ needs.<job>.outputs.KEY }}`; a matrix is static (form inputs and literals),
  guarded by `if:` against a runtime count; a step that waits on another job carries
  `early-cancel: any-job-failed`.

### Comments
- Default to no comments. Only add one when the WHY is non-obvious: a hidden
  constraint, a subtle invariant, a workaround for a specific bug. No WHAT comments.

## No build system

No build system or linter. Deployment happens by the ACTIVATE platform cloning this
repo and executing scripts directly. `emed`/`hsp`/`noaa` variants are meant for
`cluster.einsteinmed.edu`, `activate.hpc.mil` and `noaa.parallel.works`; they also run
on the cloud clusters of `activate.parallel.works`, which is how they are tested. What
a test from here cannot check is the target platform itself (its modules, partitions,
paths): validate that statically.

## Testing and debugging

- **Test every new or changed workflow end-to-end at least once and record the test in
  the repo.** Tests live under `workflows/<name>/tests/<variant>/` (the variant is the
  YAML's basename) and run with `python3 tools/tests/run-workflow-test.py <test.json>`.
  The layout, keys, pass criteria and result columns are documented once, in
  `tools/tests/README.md`. Commit the test and the rows the runner appends with the
  change; never edit a CSV by hand. Run the tests of one resource sequentially.
- **What pass means is the shape's business**; the runner never probes a URL:
  - endpoint service: the run completes (which it only does after its own health check
    saw the URL answer) and `pw endpoints list` shows `<service.name>-<run-slug>`; a
    fixed name goes in `_test.endpoint_name`
  - a run that registers no endpoint (a batch job, a sampler, an add-worker variant):
    `_test.endpoint: false`, pass = the run completes
  - a failure path (a deliberate `exit 1`, an input the form forbids):
    `_test.expect: error`; test one per workflow, the success path never exercises it
  - Kubernetes: pass = the `wait_for_endpoint_k8s` job completes while the run is
    still `running`; teardown = `pw workflows runs cancel <slug>` (tests under
    `tests/k8s/` and `tests/general_k8s/`; details in
    `.claude/skills/activate-workflows/references/k8s-workflows.md` §4–§6)
- **Review before the first test run and before the PR** with the `workflow-reviewer`
  subagent (`.claude/agents/workflow-reviewer.md`): a read-only pass over a workflow
  directory against these rules, the shape file, the skill's pitfalls, the recorded
  tests, and a `--dry-run` of each variant with its test inputs. Hand it the
  directories and the base ref, not your conclusions. It is optional, and it never
  edits or runs anything.
- **Push before testing** anything the run fetches (`app/` scripts, subworkflows):
  checkout and `uses:` steps pull this repo from GitHub at run time. The YAML itself
  is read from the absolute path you pass, so a YAML-only edit tests without a push.
- Run with the **absolute** YAML path (a relative path is parsed as a git host):
  `pw workflows run /abs/path/workflows/<name>/yamls/general.yaml -i '{"resource":"<cluster>","cluster":{"scheduler":false}}'`
- **Tear down:** `pw endpoints delete <name>` kills the remote process tree; verify
  with `ps -x` (daemonizing apps that re-parent to PID 1 can survive). A batch run
  leaves nothing to delete; a Kubernetes run is cancelled.
- **Verify cancel cleanup when developing a workflow:** cancel a run mid-flight
  (`pw workflows runs cancel <slug>`) and confirm nothing survived — no leftover
  processes (`ps -x`), scheduler jobs (`squeue`/`qstat`), container instances
  (`singularity instance list`, `docker ps`), or `stopped` record in `pw endpoints list`.
- **Debug from the job dir** on the execution node — `~/pw/jobs/<run-slug>/` for
  CLI file runs, `~/pw/jobs/<workflow-name>/<run-number, 5 digits>/` for registered
  workflows:
  `run.<JOBID>.out` is the submitted script's output; `logs/<job>/step_N/step.out` the
  step trace; `logs/<job>/step_N/script-unstable.sh` is the **rendered** step showing
  every `${{ input }}` as its literal value — read it first when a form value seems
  ignored. From anywhere: `pw workflows runs errors <slug>`. Kubernetes runs have no
  job dir on a cluster node — debug them per
  `.claude/skills/activate-workflows/references/k8s-workflows.md` §6.
- `pw` auth tokens expire; "Authentication has expired" means a human must run `pw auth`.
- Registered ("remote") workflows pin one YAML path (`pw workflows get <name>` →
  `remote.yaml`); the form and its defaults come from that file — point registrations
  at `workflows/<name>/yamls/<variant>.yaml` and `workflows/<name>/thumbnails/…`.

## Git and deployment

- Primary branch: **canary** (`git@github.com:parallelworks/workflows.git`) — the
  branch the YAMLs reference at runtime. Branch rules require changes to land **via
  pull request**; work on a side branch and merge (squash) into canary.
- Large binaries stay out of this repo. `webshell`'s controller fetches its ttyd/noVNC
  tarball from the old `interactive_session` repo's `legacy` tag at run time — leave
  that clone block alone (background: MIGRATION.md).
- Marketplace registrations pin repo paths; renaming a path here without re-pointing
  the registration breaks the entry (registration notes: MIGRATION.md).
