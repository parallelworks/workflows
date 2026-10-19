---
name: activate-workflows
description: >-
  Develop, test, and debug workflows for the Activate platform by Parallel Works.
  Use it whenever the task touches an Activate / Parallel Works workflow YAML
  (`workflows/<name>/yamls/*.yaml`, `on.execute.inputs`, jobs, steps, `${{ }}`
  expressions), a service exposed as a `pw` endpoint (`pw endpoints run`,
  `wait_for_endpoint`), the `script_submitter` subworkflow, SLURM/PBS or Kubernetes
  submission from a workflow, the end-to-end test runner
  (`tools/tests/run-workflow-test.py`, `tests/<variant>/`), or the `pw` CLI
  (`pw workflows run/create/update`, `pw workflows runs logs/errors/cancel`,
  `pw endpoints`, `pw cluster`, `pw ssh`) — also when the user only asks to run,
  test, debug, review or convert a workflow rather than build one. Provides a proven
  target-machine-first process and a verified platform reference that points at the
  repo's real workflows and tutorials.
---

# Developing Activate (Parallel Works) workflows

A repeatable process for building a workflow that runs code on a compute resource and,
usually, exposes a web service as a **`pw` endpoint**. This file is the **process**; the
rest of the skill is read on demand ("reference §N" below means a section of the first
file):

| Read | When |
|---|---|
| [references/activate-platform.md](references/activate-platform.md) | Any YAML or CLI question: schema, inputs and expressions, DAG / matrix / retries, `script_submitter`, `pw` CLI, job-dir layout, endpoints, LLM services. Numbered sections, contents at the top. |
| [references/pitfalls.md](references/pitfalls.md) | **A run misbehaves**: grep it for the symptom text before debugging from scratch. Every surprise a real run taught, grouped by theme, dated. |
| [references/shapes/](references/shapes/) | The jobs after preprocessing for each workflow shape (endpoint service, batch job, callable step, composed workflow): what "done" means, the teardown, the test. Step 2 picks one. |
| [references/k8s-workflows.md](references/k8s-workflows.md) | The target is a Kubernetes cluster: no login node, no `script_submitter`, its own dev loop, tests and debugging. |
| [references/design-parameters.md](references/design-parameters.md) | A driver (`doe`, `dakota`) and a runner (`openfoam-naca`) exchange designs: the `params.in` / `results.out` contract. |
| [references/session-to-endpoint-upgrade.md](references/session-to-endpoint-upgrade.md) | Converting an older session-tunnel workflow to the endpoint pattern. |
| [references/software/](references/software/) | One piece of software (OpenFOAM, Dakota, ParaView, conda, Singularity/SIF, MPI benchmarks, dask-jobqueue, PhysicsNeMo, PostgreSQL, ...): one file per tool. |

**The platform docs are authoritative and change over time; this skill is a snapshot.**
When the two conflict, trust the docs and harden the skill (Step 5):
[building workflows](https://parallelworks.com/docs/run/workflows/building-workflows)
([YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
[inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
[actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions)) ·
[endpoint sessions](https://parallelworks.com/docs/run/sessions/endpoints) ·
[`pw endpoints` CLI](https://parallelworks.com/docs/cli/pw/endpoints) ·
[`pw` CLI](https://parallelworks.com/docs/cli). Every docs page is also served as
`<url>.md`, the form to fetch.

Assume the `pw` client on this machine is authenticated (`pw context list` shows the
platform and user); "Authentication has expired" needs a human to run `pw auth`. Add
`permissions: ['*']` whenever the workflow or a subworkflow runs `pw` (`pw agent
open-port` is the one exception): it lets the run use any `pw` command the launching
user can.

## Golden rules

- **Compose from the repo's standalone workflows; plain DAGs for the rest.** The
  workflows here are building blocks called as subworkflows (reference §3):
  `script_submitter` (`v3.6`) runs a script on a resource, `wait_for_endpoint` waits
  until an endpoint answers, `doe` samples designs, `dakota` proposes the next batch,
  `openfoam-naca` solves one design, `design-explorer` serves a study. A web service
  copies the endpoint pattern (Step 2); "run a script on a cluster" calls
  `script_submitter` directly. Never hand-write job submission, port allocation or
  tunnel logic. Write a new workflow so it can be called in turn: it does one thing,
  its form is its interface, the paths it reads and writes are inputs, and it runs on
  its own. Composing them is a YAML with no code of its own (`doe-openfoam`,
  `dakota-openfoam`). Pure orchestration (a multi-job DAG, data flow, fan-out) needs no
  subworkflow at all.
- **Learn the patterns from the repo's workflows and tutorials, not invented demos.**
  Reference §8 maps each need (simplest endpoint, Singularity service, sweep, failover,
  iterative loop, composition, Kubernetes) to the file to copy.
- **Add a variant only where the platform changes the YAML; pick it by host.**
  `general.yaml` serves every platform unless the workflow submits scheduler jobs:
  `script_submitter` and its scheduler/slurm/pbs form sections ship per platform
  (`emed` for `cluster.einsteinmed.edu`, `noaa` for `noaa.parallel.works`, `hsp` for
  `activate.hpc.mil`, `general` otherwise; `pw context list` shows the host, and when it
  is unclear, ask). Copy the cluster form and the submitter's `with:` block from the
  matching `workflows/<name>/yamls/<variant>.yaml`; `--dry-run` does not catch a
  mismatch. A workflow that only runs on the login node keeps one `general.yaml`
  (`wait_for_endpoint`, `doe`, `dakota`, `design-explorer`); a site difference a
  hostname can decide is runtime logic inside it. Code the variants share is
  written once, so the variants differ only where the platform does and a change
  lands once: a step body only this workflow runs goes into a script under `app/`,
  called with its inputs as environment variables (`openfoam-naca/app/read-results.sh`);
  logic many workflows call, or that takes several steps or jobs, is a subworkflow
  they call (`wait_for_endpoint`, `script_submitter`).
- **Pass every required subworkflow input, and `--dry-run` first.** Dry-run validates
  the YAML and each subworkflow's required inputs; a missing one fails with the terse
  `Could not parse subworkflow` (the field is never named: diff your `with:` block
  against the subworkflow's form). Inputs the form hides and ignores under your values
  are not required. Dry-run does **not** flag unknown or wrong-variant fields; those
  surface at run time (verified 2026-09-16).
- **Develop on the target machine before touching YAML.** The YAML is a thin wrapper
  around code that already works there (Step 1).
- **Know where your job runs.** `ssh.remoteHost: ${{ inputs.resource.ip }}` runs a job
  on that resource's login node: that is where the job dir and your process live
  (Step 4). The workspace resolves with an empty `ip`, so its jobs run on the workspace
  node, as do a Kubernetes YAML's.

## Step 1 — Develop the code on the target machine first

Pick the **target resource** first (`pw cluster ls`; it must be `active`): developing
and testing need a real machine, and the workflow's jobs will run on its login node. A
Kubernetes cluster (`pw kube ls`) has no login node; follow
[references/k8s-workflows.md §3](references/k8s-workflows.md) instead.

- **If this shell is the target's login node** (compare `hostname` with the resource),
  work directly: edit files, run the program, inspect `~/pw/jobs/…` and `ps -x`. This
  is the fastest loop.
- **Otherwise drive the target through `pw ssh <resource>`**: stage code in its home,
  run commands remotely (`pw ssh <resource> "cmd"`), read job dirs the same way. Each
  cluster has its own filesystem and tools; what runs here may be missing there.

Write and test the core program (server, simulation, script) there until it runs
standalone from a clean shell with no manual setup. No YAML yet.

- A web service binds the port it is given (an argument or `$PORT`) on `0.0.0.0` and
  serves everything its page needs. Prefer the standard library and preinstalled tools,
  so the controller script has nothing to install.
- Drive it the way the platform will: `python3 server.py --port 8731 …` in the
  background, then `curl localhost:8731/...` on every route.
- Keep each piece a real file: they go into `workflows/<name>/app/` and are checked out
  at run time.

## Step 2 — Wrap the working code in workflow YAML

Every YAML here starts the same way, whatever it goes on to do: a **preprocessing** job
that checks out the code with `parallelworks/checkout` (sparse: `workflows/<name>/app`,
plus `tools/...` when the scripts use the shared tools), writes `inputs.sh` from the
form values and the `PW_*` environment, runs `inputs.sh + controller.sh` inline, and
assembles whatever script the next jobs run, publishing its path as an output. The
rules every shape shares:

**Paths.** Only the runtime subtree is checked out, `workflows/<name>/app` (or an
implementation subdir), and it materializes at
`${PW_PARENT_JOB_DIR}/workflows/<name>/app/…`. Every path a YAML or script builds to
reach repo files carries that full prefix, including paths composed from variables.
Keep `yamls/`, `thumbnails/` and READMEs out of `app/`. Inside the submitted script,
reference files relative to the submitter's `rundir` (it `cd`s there, and a compute
node may not export `PW_PARENT_JOB_DIR`) or through the `PW_PARENT_JOB_DIR` that
`inputs.sh` carries. As a job's `working-directory` or the submitter's `rundir` write
`${{ env.PW_PARENT_JOB_DIR }}`: the platform resolves those keys itself and takes
`${VAR}` literally.

**Form.** The resource is the top-level `resource` input (`compute-clusters`) on every
variant; the `cluster` group holds the scheduler fields and is hidden and ignored as a
whole when the resource has no scheduler (`${{ inputs.resource.schedulerType == '' }}`);
the rest of the form is grouped by what it configures (`service` for a served app,
`case`, `doe`, `optimizer`, `software`, ... elsewhere). An optional input left unset
renders empty in the shell (verified for a numeric input): guard with `${var:-default}` and
quote every `${{ }}` interpolation. Write the form to be read, not hovered: every
shown input labeled in sentence case, booleans as statements, a one-line `description`
for what the user must know before submitting, the detail in the `tooltip`
(AGENTS.md, "Form text").

**Code delivery: `parallelworks/checkout`, never base64.** The repo is fetched from
GitHub at run time, so nothing you edit locally takes effect until it is pushed (both
modes in detail: reference §9).
1. **Write access (recommended):** work on a development branch, never `canary`
   directly (branch rules require a PR); push, and point the checkout at that branch
   (`branch: <dev-branch>`). After the merge, flip `branch:` back to `canary`.
2. **No write access:** stage the files on the resource (`~/pw/dev/<workflow>/`) and
   give preprocessing the checkout step commented out plus a copy step
   (`cp -r ~/pw/dev/<workflow>/. .`) that stands in for it. The user swaps them after
   merging.

Then pick the **shape** by what the run must leave behind. Its file has the jobs that
follow preprocessing, what "done" means, how the run is torn down and what its test
checks:

| Shape | The run ends when | After preprocessing | Copy from | Read |
|---|---|---|---|---|
| **Endpoint service** (most workflows) | the service answers its URL; it outlives the run until `pw endpoints delete` | `session_runner` (`script_submitter`) + `wait_for_endpoint` | `workflows/webshell` | [shapes/endpoint.md](references/shapes/endpoint.md) |
| **Batch job** | the script finishes; the run fails when it fails | `script_submitter` once, then a step that reads the exit file the script wrote | `workflows/activate-batch`, `workflows/benchmarks` | [shapes/batch.md](references/shapes/batch.md) |
| **Callable step** (login node only) | its steps finish; one `general.yaml` for every platform | plain `run:` steps; a detached `pw endpoints run` with a `!success()` handler when it serves | `workflows/doe`, `workflows/design-explorer` | [shapes/composed.md](references/shapes/composed.md) |
| **Composed** | the study or loop finishes | `uses:` of the rows above: a matrix of evaluators, retry-as-loop, a live page | `workflows/doe-openfoam`, `workflows/dakota-openfoam` | [shapes/composed.md](references/shapes/composed.md) |
| **Kubernetes** | never: cancelling the run is the teardown | the sidecar pod jobs; no submitter, nothing checked out | `workflows/mlflow/yamls/k8s.yaml`, `workflows/openvscode/yamls/general_k8s.yaml` (hybrid) | [k8s-workflows.md](references/k8s-workflows.md) |

A simulation that must survive its walltime, a preempted or lost node, or a cancel is
the resumable batch job: `workflows/openfoam-naca/yamls/general-restart.yaml` (and the
`hsp`/`noaa` ones) retries the whole case workflow from one step, the solver writes
checkpoints and `app/restart.sh` resumes from the latest complete one; the README's
"Resubmitting an interrupted case" is the walkthrough to copy for another solver
([shapes/batch.md](references/shapes/batch.md), "A resumable batch job").

The rows are tested shapes, not a menu: combine them (`physicsnemo`, `dakota-openfoam`)
or build a new one from the same parts, as long as it keeps what every row keeps: the
run ends on evidence (a health probe, an exit file) and fails loud without it, whatever
outlives it has a teardown, a cancel leaves nothing behind, and the test is recorded. A
new shape proven end-to-end earns a row (Step 5).

## Step 3 — Test end-to-end and record the test

Every workflow is tested end-to-end at least once, and the test is recorded under
`workflows/<name>/tests/<variant>/` (layout, `_test` keys, pass criteria and result
columns: `tools/tests/README.md`; start from `workflows/webshell/tests/general/`).

**Push first, unless only the YAML changed.** The checkout and `uses:` steps fetch the
repo from GitHub, so an edit to `app/` scripts or a subworkflow is invisible until it is
on the referenced branch. The YAML itself is read from the local path.

```bash
python3 tools/tests/run-workflow-test.py workflows/<name>/tests/<variant>/<test>.json
```

Pass = `result=pass` and `cleanup=ok` in the row the runner appends. What `completed`
proves is the shape's business: an endpoint workflow only completes after its own
health check saw the URL answer, so the runner never probes it; a batch test sets
`_test.endpoint: false`. On failure read `tests/<variant>/logs/<slug>.txt` and
`pw workflows runs errors <slug>`, fix, push, re-run. Commit the test and the CSV rows
with the change; never edit a CSV by hand. Run the tests of one resource sequentially.

If `pw` is not authenticated here, still write the test JSON, hand the user the exact
runner command to run after `pw auth`, and ask for the appended row. Never claim a
workflow was tested while the row does not exist.

Running by hand instead (`pw workflows run /abs/path.yaml -i inputs.json`, the absolute
path because the shell's cwd is not guaranteed between tool calls):
- Pass the resource as its URI (`pw://<user>/<cluster>`) or bare name, never an IP; it
  must be `active` in `pw cluster ls`. A `compute-resources` input (the hybrid k8s
  forms) needs the resource object (reference §2).
- What the run's completion proves, and how the service or job is torn down, is in
  the shape's file (Step 2).
- **Kubernetes:** pass = the `wait_for_endpoint_k8s` job completes while the run is
  still `running`; teardown = `pw workflows runs cancel <slug>`
  ([references/k8s-workflows.md §4–§5](references/k8s-workflows.md)).

**Verify cleanup on cancel, every time, not as an afterthought:** cancel one run
mid-flight (`pw workflows runs cancel <slug>` while the service is starting or serving)
and confirm nothing survived: no service or worker processes (`ps -x`), no scheduler
job (`squeue`/`qstat` when `scheduler: true`), no container instances
(`singularity instance list`, `docker ps`), no stray listeners, no endpoint record left
in `pw endpoints list` (a cancel while a service starts can leave a `stopped` one). If
anything survives, fix the cleanup (`cancel.sh`, the submitter's cleanup script) before
calling the workflow done. Test the failure path too: a deliberate failure (an `exit 1`
before the service starts, an input the form forbids) must end the run in `error`; the
success path never exercises those steps.

## Step 4 — Debug from the job directory and processes

After every run, inspect the job dir on the **node where the job ran** (the resource's
login node when `scheduler: false`; `~/pw/jobs/<run-slug>/` for CLI file runs,
`~/pw/jobs/<workflow-name>/<run-number, 5 digits>/` for registered workflows):

```bash
ls -la ~/pw/jobs/<run>/                               # inputs.sh, the assembled scripts, SKIP_CLEANUP, the checkout
cat   ~/pw/jobs/<run>/inputs.sh                       # the form values the scripts saw
cat   ~/pw/jobs/<run>/logs/<job>/step_N/step.out      # per-step trace (set -x shows every expanded command); step.exit
find  ~/pw/jobs/<run> -name 'run.*.out'               # the submitted script's stdout (under subworkflows/<submitter job>/step_0/ unless rundir is set)
find  ~/pw/jobs/<run> -name step.out | xargs grep -h '^::error'   # every failure of the run, nested subworkflows included
ps -x | grep <your-process>                           # is the service alive?
pw endpoints list                                     # is the endpoint registered? (endpoint shapes)
```

From anywhere, through the API:
```bash
pw workflows runs errors <slug> -o text                       # just the failures
pw workflows runs logs   <slug> --job <job>                   # one job's steps (`session_runner` is the submitter job of endpoint workflows)
pw workflows runs logs   <slug> --job wait_for_endpoint       # the statuses the health probe saw
pw workflows runs view   <slug> -o json                       # the inputs the run was launched with, the resolved YAML
```

If files or processes are not where you look, you targeted a different resource: the
execution node is the chosen resource's login node (the workspace node for `workspace`
and for Kubernetes jobs, which have no job dir on a cluster node:
[references/k8s-workflows.md §6](references/k8s-workflows.md)).

Diagnose, fix the code or YAML, push (the dev branch the checkout points at, then a PR
to `canary`), re-run. **Clean up what you started:** `pw endpoints delete` for live
endpoints, `pw workflows runs cancel <slug>` for runs still executing (every Kubernetes
run: cancelling is its teardown). A lingering endpoint holds the service process.

## Step 5 — Harden this skill

Every surprise (a wrong YAML field, a CLI flag, a misread subworkflow input, a debugging
trick that worked) goes into [references/pitfalls.md](references/pitfalls.md), under the
matching section, with the date it was verified; one about a single piece of software
goes into its file under [references/software/](references/software/) (new tool, new
file: short, pointing at the workflow that uses it). A platform fact that changes what
the process says belongs in
[references/activate-platform.md](references/activate-platform.md); a workflow shape
proven end-to-end gets a file under `references/shapes/` and a row in Step 2's table.
Because the platform docs change, re-check them when behavior surprises you and correct the skill toward the
docs. Do not add a tutorial to `tutorials/` without maintainer approval; point at an
existing one.

## Best practices

- **Orchestrate with the job graph.** Share files across jobs through
  `${PW_PARENT_JOB_DIR}`; pass values as `KEY=value` lines appended to `$OUTPUTS` (write
  them to a file and `cat` it in, so a program's own output never lands there) and read
  `${{ needs.<job>.outputs.KEY }}`, listing every job whose outputs you read in
  `needs:`. Compute booleans upstream and drive `if:` with string equality; use the
  status functions (`failure()`, `cancelled()`, `!success()`, `always()`) for handlers
  (`tutorials/if-conditions/`; the old keywords such as `!completed` are text now).
  Fan out with a matrix (static: form inputs and literals; guard a computed count
  with `if: ${{ matrix.job_id <= needs.X.outputs.N }}`) and join
  with `needs: [w1, w2, w3]`; retry or fail over with a step `retry` block and
  `PW_WORKFLOW_STEP_CURRENT_RETRY`, always with a `timeout` sized for the whole attempt
  (reference §3).
- **Scripts idempotent and traceable:** `set -o pipefail`, `set -x`, check before
  installing, safe to re-run. Stream progress (it lands in `run.<JOBID>.out`) and write
  a machine-readable result.
- **Fail loud, never hang.** A missing path or a misconfiguration exits non-zero. A
  step waiting on another job's runtime output carries `early-cancel: any-job-failed`,
  so that job's death releases it instead of leaving an indefinite wait.
- **Cross-node reach.** Expose another resource's service locally with
  `pw forward -L p:host:p <resource>` (`host` = `localhost` for a login-node service, the
  job's `HOSTNAME` file for a compute-node one); read a sibling job's files with
  `pw ssh <resource> "cat ${PW_PARENT_JOB_DIR}/<file>"`, the same path on every resource
  of a run (reference §6).
- **Pin subworkflow versions** (`v3.6`); pull ghcr artifacts through
  `tools/oras/libs.sh:oras_pull_file` (it retries rate-limited anonymous pulls) and keep
  the packages public.
- **Registered workflows pin one YAML path** (`pw workflows get <name> -o json` →
  `remote.yaml`); the form and its defaults come from that file, so a default the UI
  ignores usually means the registration points at the wrong variant.
