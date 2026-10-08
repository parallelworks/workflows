---
name: activate-workflows
description: >-
  Develop, test, and debug workflows on the Activate platform by Parallel Works.
  Use whenever the task involves an Activate / Parallel Works workflow, a service
  exposed as a pw endpoint, the script_submitter subworkflow, or the `pw` CLI
  (workflows create/update/run, endpoints, cluster). Provides a proven
  target-machine-first process plus a reference of platform facts pointing at the
  repo's real workflows and tutorials.
---

# Developing Activate (Parallel Works) workflows

A repeatable process for building a workflow that runs code on a compute resource
and (optionally) exposes a web service as a **`pw` endpoint**. Read
[references/activate-platform.md](references/activate-platform.md) for the YAML
schema, subworkflow interfaces, `pw` CLI, and job-directory layout — this file is
the **process**; that file is the **facts**; and
[references/pitfalls.md](references/pitfalls.md) is the **memory**: every surprise a
real run taught, searched by symptom when something misbehaves. What one piece of
software needs (OpenFOAM, Dakota, ParaView, conda environments, Singularity/SIF images, MPI benchmarks,
dask-jobqueue) has
its own file under [references/software/](references/software/). Kubernetes targets
have their own process and facts in [references/k8s-workflows.md](references/k8s-workflows.md).

**The platform docs are authoritative and updated over time — this skill is a
snapshot that can fall behind.** When something here conflicts with them, trust the
docs and harden this skill (Step 5):
- Building workflows — <https://parallelworks.com/docs/run/workflows/building-workflows>
  (subpages: [YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
  [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions))
- Endpoint sessions — <https://parallelworks.com/docs/run/sessions/endpoints>
- `pw endpoints` CLI — <https://parallelworks.com/docs/cli/pw/endpoints>
- `pw` CLI — <https://parallelworks.com/docs/cli>

**Assume the `pw` client is already authenticated** — otherwise ask the user to log
in. Confirm context with `pw context list` if unsure. **Set `permissions: ['*']`** in
every workflow: it is what lets the in-workflow
`pw` client authenticate (e.g. `pw endpoints run`).

## Golden rules

- **Reuse the endpoint pattern and `script_submitter`; plain DAGs for the rest.**
  For a web service, copy the repo's endpoint pattern: preprocessing checks out the
  code, `script_submitter` (`v3.6`) submits the start script, the start script runs
  the service under `pw endpoints run`, and a `wait_for_endpoint` job confirms it.
  For "just run a script/sim on a cluster," call `script_submitter` directly. Do
  **not** hand-write job submission, port allocation, or tunnel logic. Pure
  orchestration (multi-job DAG, data flow, fan-out) needs **no** subworkflow — that's
  a first-class use. Learn the patterns from the **repo's own workflows and
  tutorials**, not from invented demos (reference §9): endpoints →
  `workflows/{webshell,jupyterlab,openvscode}/`; **Singularity/SIF services →
  `workflows/streamlit/` (simple) and `workflows/kasmvnc/` (multi-impl)**, delivery and
  gotchas in [references/software/singularity-sif-containers.md](references/software/singularity-sif-containers.md); job DAG / outputs
  → `tutorials/endpoint-workflows/` (staged README); **fan-out / sweep →
  `tutorials/endpoint-workflows/05-matrix.yaml`**; retry/failover →
  `tutorials/endpoint-workflows/07-failover.yaml`; **iterative loop over computed
  cases (retry-as-loop + guarded static matrix) → `tutorials/optimization/`**;
  **Kubernetes** (no script_submitter,
  no login node) → [references/k8s-workflows.md](references/k8s-workflows.md).
- **Pick the deployment variant by platform host — don't default to `general`.**
  `script_submitter` ships as `general` / `emed` / `hsp` / `noaa`, and
  the **resource/scheduler/slurm/pbs form sections differ between them**. Choose:
  `emed` for `cluster.einsteinmed.edu`, `noaa` for `noaa.parallel.works`, `hsp` for
  `activate.hpc.mil`, `general` otherwise — **if unclear, ask the user.** Then copy the
  cluster/slurm/pbs form and `with:` block from the matching
  `workflows/<name>/yamls/<variant>.yaml`. (`pw context list` shows the host.)
- **Pass every required subworkflow input, and `--dry-run` first.** `--dry-run`
  validates the YAML and each subworkflow's required inputs: omit a non-optional input
  with no default and it fails with the terse `Could not parse subworkflow` (the field
  is never named — diff your `with:` block against the subworkflow's form). Inputs the
  form hides and ignores under the values you pass are NOT required
  (`script_submitter` with `define_cleanup_script: false` needs no
  `cleanup_script_path`). Dry-run does NOT flag unknown or wrong-variant fields; they
  pass silently and surface only at run time (verified 2026-09-16).
- **Develop on the target machine before touching YAML.** The YAML is a thin wrapper
  around code that already works there (directly if this shell is the target's login
  node, else via `pw ssh <resource>` — Step 1).
- **Know where your job runs.** `ssh.remoteHost: ${{ inputs.resource.ip }}` runs a
  job on that resource's login node — that's where the job dir and your process
  live. See Step 4.

## Step 1 — Develop the code on the target machine first

Pick the **target resource** before anything else (`pw cluster ls`; it must be
`active`) — developing and testing needs a real machine, and the workflow's jobs will
run on that resource's login node. A **Kubernetes cluster** (`pw kube ls`) has no login
node: follow [references/k8s-workflows.md §3](references/k8s-workflows.md) instead.

- **If this shell IS the target's login node** (common: the agent runs in a session
  on the cluster; compare `hostname` with the resource), work directly — edit files,
  run the program, inspect `~/pw/jobs/…` and `ps -x` locally. This is the fastest loop.
- **Otherwise, drive the target through `pw ssh <resource>`** — stage/edit code in
  the shared home, execute remotely (`pw ssh <resource> "cmd"`), and read job dirs
  the same way. Don't develop against the wrong machine: what runs here may be
  missing there (each cluster has its own filesystem and installed tools).

Then write and test the core program (server, simulation, script) on that machine
until it runs standalone. Do not write any YAML yet.

- For a web service: bind a port from an argument/env var, default to `0.0.0.0`,
  and serve everything the page needs. Prefer the **standard library / preinstalled
  tools** so the controller script has nothing to install. Test every endpoint with
  `curl` and confirm it terminates/looks right.
- Drive it the way the platform will: `python3 server.py --port 8731 …` in the
  background, then `curl localhost:8731/...`.
- Keep each piece a real file (you'll check these into the repo and `checkout` later).

Done when: the program runs from a clean shell on the target machine with no manual
setup and produces correct output.

## Step 2 — Wrap the working code in workflow YAML

Mirror the proven pattern (see `workflows/webshell/yamls/general.yaml`): a
**preprocessing** job (checkout + `inputs.sh` + run `controller.sh` + assemble the
start script), a **script_submitter** job that submits it, and a
**wait_for_endpoint** job that calls the `wait_for_endpoint` subworkflow
(`workflows/wait_for_endpoint/README.md`) and then cancels the submitter. The
subworkflow polls `pw endpoints list` for `<service.name>-${PW_RUN_SLUG}`, probes the
URL with `Authorization: Bearer ${PW_API_KEY}` until the status matches `healthy`
(within `budget`), and touches the `SKIP_CLEANUP` marker so the service outlives the
run; if the service never answers, the job fails without the marker and the
submitter's cleanup tears the job down. **The workflow owns this check.** Copy the call
from `workflows/jupyterlab/yamls/general.yaml` and set its inputs per service:
`healthy` (web UI: `2*|3*`; API server: `path` to its health route and accept what it
returns), `budget` (seconds for a Python server, minutes for a SIF conversion or a
model load); verify the choice in the wait job's log. Why the
key: an anonymous request only gets the platform's `307` login redirect whatever the
service does; with the key the service's own status comes back, and a registered
tunnel with nothing listening yet answers `503` (verified 2026-09-21).

Provide the two contract scripts:
- **`controller.sh`** — idempotent setup on the login node (has internet). Often
  just verifies prerequisites.
- **`start-template.sh`** — launches the service under
  `pw endpoints run ${pw_endpoints_args} -- <cmd with {port}>`, and **fails loud**:
  if `pw endpoints run` exits without the endpoint registered, exit non-zero so
  the submitter job fails and the submitter job's cancel-jobs step stops
  `wait_for_endpoint` (copy the tail of `workflows/webshell/app/start-template.sh`).
  Do NOT self-cancel the run with `pw workflows runs cancel` from inside a start
  template.

**Path rule (learned the hard way):** only the runtime subtree is checked out —
`workflows/<name>/app` (single-implementation) or `workflows/<name>/<impl>` — and it
materializes at `${PW_PARENT_JOB_DIR}/workflows/<name>/app/…`. Every path a YAML or
script builds to reach repo files (including ones composed from variables like
`"${PW_PARENT_JOB_DIR}/${service_name}"`) must carry that full prefix. Keep
`yamls/`, `thumbnails/`, and READMEs out of `app/` so runs never materialize them.

**Getting the scripts onto the node — use `parallelworks/checkout`. The repo is fetched from GitHub **at runtime**, so nothing you edit
locally takes effect until it is pushed. Two modes depending on whether Claude can
push to the repo:
1. **Write access (recommended):** ask the user to grant a **deploy key with write
   permission**. Work on a **development branch — never `canary` directly** (branch
   rules require PRs) — commit and push, then `parallelworks/checkout` that branch
   (`branch: <dev-branch>`, `sparse_checkout: [workflows/<name>/app]`). Open a PR to
   `canary`; after the merge, flip `branch:` back to `canary`.
2. **No write access:** you can't push, so stage the files on the resource (e.g.
   `~/pw/dev/<workflow>/`) and give preprocessing **two steps** — the
   `parallelworks/checkout` step **commented out** (configured for after the merge) and
   a **copy step** (`cp -r ~/pw/dev/<workflow>/. .`) that mimics it. The user later
   pushes & merges, uncomments checkout, and deletes the copy step.

Pass `script_submitter`'s inputs **from the matching variant's YAML** (`resource`,
`use_existing_script`+`script_path`, `scheduler`, `slurm`/`pbs`, and the
`skip_cleanups_file` wiring — copy the whole `with:` block). `skip_cleanups_file` exists
only for endpoint workflows (it is what lets the service outlive the run); a plain
batch job leaves it unset. Add
`include-workspace: true` on the `compute-clusters` input if the workspace should be
selectable. The hidden `service.name` input is the **endpoint name prefix** — keep it
stable (renaming it changes endpoint names users see).

**Base paths:** subdomain endpoints serve at the URL root, so most apps need no
base-URL config and no nginx (reference §11/§12); `--slug` handles a landing path or
query string.

`integer` inputs render as bare digits in the shell and compare numerically in
expressions (`inputs.n == 5`, `inputs.n > 3` — verified 2026-09-16). An **optional
integer left unset renders empty**, so guard those with `${var:-default}`.

**Kubernetes:** the same endpoint, registered by a `pw-cli` sidecar inside the pod; no
script_submitter, no login node, nothing checked out, and the run stays alive until it
is cancelled. Anatomy, dev loop, inputs, tests and debugging are in
[references/k8s-workflows.md](references/k8s-workflows.md); copy
`workflows/mlflow/yamls/k8s.yaml` (k8s-only) or `workflows/openvscode/yamls/general_k8s.yaml`
(hybrid).

## Step 3 — Test end-to-end and record the test

Every workflow is tested end-to-end at least once, and any end-to-end test is recorded
under `workflows/<name>/tests/<variant>/`. The test layout, the `_test` keys, the pass
criteria and the result columns are documented once, in `tools/tests/README.md`; read
it before writing a test. Start from an existing test, e.g.
`workflows/webshell/tests/<variant>/<test-name>.json`.

**Push first, unless only the YAML changed.** The YAML's checkout and `uses:` steps
fetch the repo from GitHub at run time, so a local edit to anything they fetch (`app/`
scripts, the subworkflow) is invisible until it is on the referenced branch. The YAML
itself is read from the local path, so a YAML-only edit tests without a push.

```bash
python3 tools/tests/run-workflow-test.py workflows/<name>/tests/<variant>/<test>.json
```

Pass = `result=pass` and `cleanup=ok` in the row the runner appends. On failure read
`tests/<variant>/logs/<slug>.txt` and `pw workflows runs errors <slug>`, fix, push,
re-run. Commit the test files and CSV rows with the change; never edit a CSV by hand.

**If the `pw` client is not authenticated** (or cannot reach the platform from this
shell), still write the test JSON under `workflows/<name>/tests/<variant>/`, then
hand the exact runner command above to the user and ask them to run it (after
`pw auth`) and report the appended row. Never skip creating the test because the run
cannot happen here, and never claim a workflow was tested if the row does not exist.

Facts that still matter when running by hand (`pw workflows run /abs/path.yaml -i inputs.json`):
- Pass the resource as its URI (`pw://alvaro/gcpsmall`) or bare name; never an IP.
  It must be `active` in `pw cluster ls`.
- **Kubernetes:** pass = the `wait_for_endpoint_k8s` job completes (endpoint listed,
  URL answering) while the run is still `running`; teardown = `pw workflows runs cancel <slug>`. Inputs and checks:
  [references/k8s-workflows.md §4–§5](references/k8s-workflows.md).
- On a compute cluster the run completes once `wait_for_endpoint` sees the endpoint
  and its URL answers (otherwise the run fails and the submitter's cleanup tears the
  service down);
  the service keeps running until `pw endpoints delete <name>`, which kills the remote
  process tree. Daemonizing apps that re-parent to PID 1 (e.g. RStudio's `rsession`)
  can survive it.
- **Verify cleanup on CANCEL — a required test, not an afterthought:** cancel one run
  mid-flight (`pw workflows runs cancel <slug>` while the service is starting or
  serving) and confirm `cancel.sh` actually ran: no service processes (`ps -x`), no
  scheduler job left (`squeue`/`qstat` when `scheduler:true`), no container instances
  (`singularity instance list`, `docker ps`), no stray listeners. If anything
  survives, fix `cancel.sh` (and write it at the very top of the start script so a
  cancel at any moment finds it) before calling the workflow done.

## Step 4 — Debug from the job directory and processes

After every run, inspect artifacts on the **node where the job ran** (the resource's
login node when `scheduler:false`):

```bash
ls -la ~/pw/jobs/<slug-or-name/NNNNN>/            # inline runs: ~/pw/jobs/<run-slug>/
cat   ~/pw/jobs/<run>/run.*.out                   # script_submitter output (service stdout)
cat   ~/pw/jobs/<run>/logs/<job>/step_N/step.out  # per-step trace (+ step.exit)
cat   ~/pw/jobs/<run>/logs/<job>/step_N/script-unstable.sh  # the RENDERED step — every
                                                  # ${{ input }} shown as its literal value:
                                                  # the fastest way to see what the form sent
ps -x | grep <your-process>                       # is the service alive?
pw endpoints list                                 # is the endpoint registered?
```

**The execution node may not be this machine.** It's the login node of the chosen
resource. If files/processes aren't here, you targeted a different resource — either
target the resource whose login node *is* this host, or `pw ssh <resource>` to it.
Logs are always reachable via the API regardless of node:
```bash
pw workflows runs logs   <slug> --job session_runner          # the submitter job (its name in every YAML here)
pw workflows runs errors <slug> -o text                       # just the failures
```

**Kubernetes runs have no job dir on a cluster node** — debug them per
[references/k8s-workflows.md §6](references/k8s-workflows.md).

Diagnose → fix the local code or YAML → push (PR to `canary`, or the dev branch the
checkout points at) → re-run. **Clean up what you started:** `pw endpoints delete`
for live endpoints, `pw workflows runs cancel <slug>` for runs still executing (and for
every Kubernetes run — cancelling is its teardown). A lingering endpoint holds the
service process.

## Step 5 — Harden this skill

Every time you hit a surprise — a wrong YAML field, an unexpected CLI flag, a
misunderstood subworkflow input, a debugging trick that worked — **append it to
[references/pitfalls.md](references/pitfalls.md)**, or, when it is about one piece of
software (a solver, an optimizer, a package manager, a container image), to that
tool's file under [references/software/](references/software/) (new tool → new file,
short, pointing at the workflow that uses it). A platform fact that changes what the
process says belongs in [references/activate-platform.md](references/activate-platform.md)
instead. These files are living documents.
Because the **platform docs change**, re-check them when behavior surprises you and
correct this skill toward the docs. **Do not add a new tutorial to
`tutorials/` without maintainer approval** — each must show something new and
non-repetitive; point at an existing tutorial instead.

## Best practices

- **Develop on the target machine first; prefer the standard library** so controller
  scripts have nothing to install.
- **Deliver code with `parallelworks/checkout`, not base64.** Push to a dev branch and
  checkout that branch (write access), or stage on the resource + a commented-out
  checkout beside a stand-in copy step (no write access). See Step 2 / reference §10.
- **Match the deployment variant to the platform host** (`emed`/`noaa`/`hsp`/`general`)
  and copy that variant's resource/slurm/pbs form — don't reuse `general` blindly.
- **Orchestrate with the job graph.** Share files across jobs via `${PW_PARENT_JOB_DIR}`
  (`cd` into it in shell; as a job's `working-directory` or the submitter's `rundir` write
  `${{ env.PW_PARENT_JOB_DIR }}` — the platform takes `${VAR}` literally there). Pass
  values with `echo "K=v" | tee -a $OUTPUTS` (or pipe a program
  that prints `K=v` lines) and read `${{ needs.<job>.outputs.K }}`. Drive conditional
  steps with `if: ${{ needs.X.outputs.flag == 'true' }}` — compute the boolean
  upstream. For failure/cancel handlers use the `if:` status keywords (`always`,
  `error`, `canceled`, `!completed`; see `tutorials/if-conditions/`). Fan out with a **matrix strategy** (see `tutorials/endpoint-workflows/05-matrix.yaml`); fan
  in with `needs: [w1,w2,w3]`. For **retry/failover**, attach a `retry` block to a step
  and use `PW_WORKFLOW_STEP_CURRENT_RETRY` to pick a target per attempt — round-robin
  over a `list` input fails over across resources (see
  `tutorials/endpoint-workflows/07-failover.yaml`; reference §3 "Step retries").
- **Make scripts idempotent and traceable:** `set -o pipefail`, `set -x`; check
  before installing; safe to re-run.
- **Stream progress and emit structured results.** Print incremental progress (it
  streams to `run.<JOBID>.out` / the page) and write a machine-readable result
  (JSON) — don't make the user guess whether it's alive or done.
- **Defensive inputs:** an optional input with no default renders **empty** in the
  shell (verified for `integer`) — guard with `${var:-default}`; quote every
  `${{ ... }}` interpolation so empties/spaces don't break the shell.
- **Relative paths inside submitted scripts.** `script_submitter` `cd`s into `rundir`
  first; reference files relative to it, not via `${PW_PARENT_JOB_DIR}` (which may be
  unset on a SLURM/PBS compute node — the home FS is shared, so relative paths work).
- **Pin subworkflow versions** (`v3.6`) so an update can't silently change behavior.
- **Pull ghcr artifacts through `tools/oras/libs.sh:oras_pull_file`** (or copy its
  retry loop): ghcr intermittently rate-limits anonymous pulls (`toomanyrequests`) —
  a single-attempt pull fails a whole run for nothing. And keep the packages
  **public**: verify with an anonymous manifest request before shipping (a private
  package 403s and no retry will save you).
- **Registered ("remote") workflows pin one YAML path** (`remote.yaml` in
  `pw workflows get <name> -o json`, plus `readme`/`thumbnail` paths). The form —
  including defaults — comes from *that* file: a desktop that ignores your
  `startup_command` default usually means the registration points at the wrong
  variant. Point registrations at `workflows/<name>/yamls/<variant>.yaml` and
  thumbnails at `workflows/<name>/thumbnails/…`.
- **Cross-node service reach (multi-resource workflows).** When one job/service must reach
  another resource's service, expose it on localhost with `pw forward -L p:host:p
  <resource>` (`host` = `localhost` if unscheduled, the `HOSTNAME` value if scheduled —
  see references/pitfalls.md). Read the other job's runtime values (its allocated port, its
  `HOSTNAME`) with `pw ssh <resource> "cat ${PW_PARENT_JOB_DIR}/<file>"` — that path is the
  same on every resource in a run. Reference §6.
- **Gate dependent services without hanging.** If service A needs service B's runtime
  output (e.g. a dynamically-allocated port), have A **wait** for it, but make B **fail loud**
  on any misconfiguration and rely on `early-cancel: any-job-failed` so B's failure cancels
  A — otherwise an indefinite wait hangs forever. Mirror B's values locally in A once read,
  so later steps don't re-query across hosts.
- **Clean up:** provide `cancel.sh`/cleanup scripts, and cancel runs you're done with
  (`pw workflows runs cancel`) so nothing lingers (`sleep inf`, SLURM allocations).

## Common pitfalls (learned from real runs)

Every surprise a real run taught — wrong YAML fields, CLI and scheduler quirks,
packaging traps, subworkflow inputs misread — is collected with its verification
date in [references/pitfalls.md](references/pitfalls.md), together with the lessons
from the LLM-backed and multi-service builds. **When a run misbehaves, search that
file for the symptom text before debugging from scratch**; when you learn something
new, append it there (Step 5).
