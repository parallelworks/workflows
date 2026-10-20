# Developer Guide: Creating a New Workflow

A workflow lives in **one directory**, `workflows/my-workflow/`: a YAML form plus job
graph around scripts that already work on the target machine. What a run leaves
behind is the workflow's **shape**, and the shape decides which jobs follow the first
one:

| Shape | The run ends when | Copy from | Reference |
|---|---|---|---|
| **Endpoint service** (most workflows; this guide) | the service answers its URL; it keeps serving until `pw endpoints delete` | `workflows/webshell` | [shapes/endpoint.md](.claude/skills/activate-workflows/references/shapes/endpoint.md) |
| **Batch job** | the script finishes; the run fails when it fails | `workflows/activate-batch` | [shapes/batch.md](.claude/skills/activate-workflows/references/shapes/batch.md) |
| **Callable step** (login node only) | its steps finish; one `general.yaml` for every platform | `workflows/doe`, `workflows/design-explorer` | [shapes/composed.md](.claude/skills/activate-workflows/references/shapes/composed.md) |
| **Composed** | the study or loop finishes | `workflows/doe-openfoam`, `workflows/dakota-openfoam` | [shapes/composed.md](.claude/skills/activate-workflows/references/shapes/composed.md) |
| **Kubernetes** | never: cancelling the run is the teardown | `workflows/mlflow/yamls/k8s.yaml` | [k8s-workflows.md](.claude/skills/activate-workflows/references/k8s-workflows.md) |

This guide walks the endpoint service; §3 says where the other shapes differ. The
rules every shape shares, and how the shapes combine, are in [AGENTS.md](AGENTS.md).

Apart from Kubernetes, every shape works the same way: the controller script installs
what the workflow needs into a shared directory on the login node
(`service_parent_install_dir`, default `${HOME}/pw/software`, visible from the compute
nodes), and the script that does the work is handed to the `script_submitter`
subworkflow, which runs it on the login node or submits it to SLURM/PBS. Call a
subworkflow for anything one already does (`script_submitter`, `wait_for_endpoint`,
the sampler, the optimizer step, the case runner, the study page) instead of
re-implementing it, and write your workflow so others can call it in turn: its form is
its interface, and the paths it reads and writes are inputs.

An endpoint workflow needs three things:

| File | Runs on | Purpose |
|------|---------|---------|
| `app/controller.sh` | Controller (login) node | Install software, download dependencies |
| `app/start-template.sh` | Controller or compute node | Start the web service behind `pw endpoints run` |
| `yamls/<variant>.yaml` (e.g. `yamls/general.yaml`) | Platform | Define the UI form, generate `inputs.sh`, orchestrate |

A batch workflow submits a run template instead of a start template
(`run-template.sh`, `train-template.sh`, or a script preprocessing writes from the
form); a callable step may need no scripts at all.

`app/` holds everything the run needs (scripts + support files) and is the only
subtree the workflow sparse-checkouts; `yamls/`, `thumbnails/`, `tests/`, README, and
build tooling stay outside it.

The controller node always has internet access. The compute node may not.

The platform docs are the source of truth — consult them when anything here is
unclear or behaves differently:
[building workflows](https://parallelworks.com/docs/run/workflows/building-workflows)
([YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
[inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
[actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions)) ·
[endpoint sessions](https://parallelworks.com/docs/run/sessions/endpoints) ·
[`pw endpoints` CLI](https://parallelworks.com/docs/cli/pw/endpoints).
An app that signs its users in with their ACTIVATE account (OIDC): the recipe and the
proxy constraints are in
[references/oidc-sign-in.md](.claude/skills/activate-workflows/references/oidc-sign-in.md);
`workflows/openproject` is the worked example.

**Develop on the target machine first.** Pick the resource (`pw cluster ls`, it must be
`active`), run the program there by hand (`pw ssh <resource>`) until it starts from a
clean shell with no manual setup, then wrap it. The YAML is a thin wrapper around code
that already works.

Working with an AI assistant? The repo ships a Claude Code skill —
`.claude/skills/activate-workflows/` — that encodes this process plus the platform
reference. In Claude Code: *"Using the activate-workflows skill, build a workflow for
[deployment] that [does X]."* Before the first test run or the PR, *"Use the
workflow-reviewer subagent on `workflows/<name>`"* gets a read-only review against
AGENTS.md's rules, the shape's reference and the recorded tests
(`.claude/agents/workflow-reviewer.md`).

## 1. The controller script

`workflows/my-workflow/app/controller.sh` runs **before** the service starts, on the
login node. Use it for anything needing internet, and install under
`service_parent_install_dir`, which the compute nodes see too. All `inputs.sh`
variables are available.

```bash
#!/usr/bin/env bash
set -o pipefail

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if ! [ -f "${service_parent_install_dir}/my-server" ]; then
    echo "Installing my-server..."
    mkdir -p ${service_parent_install_dir}
    wget https://example.com/my-server.tar.gz -O /tmp/my-server.tar.gz
    tar -xzf /tmp/my-server.tar.gz -C ${service_parent_install_dir}
fi
```

Keep it **idempotent** — check whether software exists before installing.

## 2. The start script

`workflows/my-workflow/app/start-template.sh` starts the web service **behind
`pw endpoints run`**, which picks a free port, registers the endpoint and forwards its
URL to the service. All `inputs.sh` variables are available, among them
`pw_endpoints_args` (`--name <service.name>-${PW_RUN_SLUG}`, written by preprocessing).

```bash
#!/bin/bash
if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# {port} is replaced by pw endpoints run with the port it forwards to; the
# command stays in the foreground for the life of the service
pw endpoints run ${pw_endpoints_args} -- \
    ${service_parent_install_dir}/my-server --host 0.0.0.0 --port {port}

if [ $? -ne 0 ]; then
    # pw endpoints run also returns non-zero when the run cancels this job after a
    # successful launch (that is how wait_for_endpoint releases the run): only a
    # launch that never registered its endpoint is a failure
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
```

Requirements:

- **Bind `0.0.0.0` on the port `pw endpoints run` assigns**: the `{port}` token in the
  command, or `$PORT` in the environment of the wrapped command. `PW_ENDPOINT_URL`,
  `PW_ENDPOINT_HOST` and `PW_ENDPOINT_PATH` are there too, for apps that build absolute
  URLs: generate a small launcher and run `pw endpoints run ${pw_endpoints_args} -- ./launch.sh`.
- **Stay in the foreground** for the life of the service: `pw endpoints run` blocks; a
  server started in the background needs a `wait` after it.
- **Exit non-zero when the endpoint never registered**, and never cancel the run from
  inside the script (the tail above, from `workflows/webshell/app/start-template.sh`).
- **A check that must fail the run goes before `pw endpoints run`.** The run completes
  the moment the URL answers, so a check made after that fails a run that is already
  complete. Start the service on a free loopback port, check it, then
  `pw endpoints run --port <port> -- <foreground command>` (`workflows/pgadmin4`).
- **`cancel.sh`, first thing, for anything the process-tree kill will not reach**: a
  `screen` session, a docker container, an app that daemonizes and re-parents to PID 1
  (RStudio's `rsession`). The submitter runs it on cancel. A service with nothing of
  the kind needs none (`webshell` writes one only when it attaches to `screen`).
- **A page the workflow draws itself looks like the platform.** Vendor the theme
  contract of [`@parallelworks/ui`](https://github.com/parallelworks/foundation) with
  `bash tools/ui/sync-theme.sh workflows/my-workflow/app/web` (the `--theme-*` tokens
  and the Geist fonts), write the page's stylesheet against those tokens following the
  package's component recipes, and draw its icons inline:
  [references/app-ui.md](.claude/skills/activate-workflows/references/app-ui.md);
  `workflows/probe/app/web` is the worked example. A third-party app keeps its own UI.

A **batch** script does something else: it records its own exit status, because
`script_submitter` never forwards it,

```bash
trap 'echo $? > ${PWD}/commands.exit' EXIT
```

and a step after the submitter fails the run when the file is missing or non-zero
(`workflows/activate-batch/yamls/general.yaml`; signals, `wait $!` and `scancel` in
[shapes/batch.md](.claude/skills/activate-workflows/references/shapes/batch.md)).

## 3. The workflow YAML

`workflows/my-workflow/yamls/general.yaml`. Its jobs:

1. **preprocessing** — `parallelworks/checkout` of this repo (sparse:
   `workflows/my-workflow/app`, plus `tools/...` if the scripts use the shared tools),
   generate `inputs.sh` from the form values + `PW_*` environment, run
   `inputs.sh + controller.sh` inline, and assemble the start script
   (`inputs.sh` + a cleanup trap + `start-template.sh`).
2. **session_runner** (the job name kept for history) — submit the start script via
   `workflows/script_submitter/v3.6/<variant>.yaml`
   (`uses: github/parallelworks/workflows@canary`).
3. **wait_for_endpoint** — calls the `wait_for_endpoint` subworkflow
   (`uses: github/parallelworks/workflows@canary`,
   `$yaml: workflows/wait_for_endpoint/general.yaml`), then cancels the submitter. The
   subworkflow polls `pw endpoints list` for `<service.name>-${PW_RUN_SLUG}`, probes the
   URL with the run's key until the status matches `healthy` (within `budget`), and
   touches the `SKIP_CLEANUP` file so the service outlives the run. If the service never
   answers, the job fails without the skip file and the submitter's cleanup tears the
   job down. The workflow, not the test runner, owns this check. Set `healthy` (a web UI
   answers 2xx/3xx), `path` (an API server's health route) and `budget` (minutes for a
   container or a model load) per service and verify them in a test. Inputs:
   [workflows/wait_for_endpoint/README.md](workflows/wait_for_endpoint/README.md).

**Copy a real one instead of writing from scratch** —
`workflows/webshell/yamls/general.yaml` is the smallest complete example;
`workflows/jupyterlab/yamls/general.yaml` shows a conda install plus support files;
`workflows/streamlit/yamls/general.yaml` + its scripts show a **Singularity/SIF**
service (SIF pulled via oras, `.def` + `build-container.sh` alongside).
Key parts to adapt:

- the hidden `service.name` input (endpoint name prefix),
- the `healthy`, `budget` and `path` inputs of the `wait_for_endpoint` call,
- the sparse-checkout paths (`workflows/my-workflow/app`, `tools/...`),
- the `cat workflows/my-workflow/app/controller.sh` / `start-template.sh` lines,
- the `service` input group (your form fields → `inputs.sh` variables),
- the form text: labels in sentence case, booleans as statements, a one-line
  `description` for what a user must know before submitting, the detail in the
  `tooltip` (AGENTS.md, "Form text").

**The other shapes** keep preprocessing and change what follows it:

- **Batch job** — one `script_submitter` call (no `skip_cleanups_file`), then a step
  or a `results` job that reads the exit file the script wrote and fails the run with
  an `::error` when it is missing or non-zero. Copy `workflows/activate-batch`
  (smallest) or `workflows/benchmarks` (a results job with figures).
- **Callable step** — plain `run:` steps on the login node, one `general.yaml`, and a
  form that is its interface: every path it reads or writes is an input, so a caller
  passes paths under its own job dir. When it serves a page, it starts
  `pw endpoints run` detached from a step (`setsid`), calls `wait_for_endpoint`, and
  adds a `stop_server_if_unhealthy` job under `if: ${{ !success() }}`
  (`workflows/design-explorer`; the same wiring serves TensorBoard beside the training
  job of `workflows/physicsnemo`).
- **Composed** — a YAML with no code of its own: `uses:` of the workflows above with
  their form as the `with:` block, a matrix of evaluators, a retried `uses:` step as
  the loop (`workflows/doe-openfoam`, `workflows/dakota-openfoam`; the mechanics step by
  step in `tutorials/optimization/`).
- **Kubernetes** — the same endpoint is registered by a `pw-cli` sidecar in the pod,
  the run stays alive streaming pod logs, and cancelling the run is the teardown; see
  [.claude/skills/activate-workflows/references/k8s-workflows.md](.claude/skills/activate-workflows/references/k8s-workflows.md).

## 4. Platform variants

One YAML per deployment: `yamls/general.yaml` (standard SLURM/PBS clusters), plus
`emed.yaml` / `hsp.yaml` / `noaa.yaml` where the workflow is offered there, and
`k8s.yaml` / `general_k8s.yaml` for Kubernetes. Variants differ in scheduler
directives, partitions, module loads, and defaults — copy the matching variant of a
similar workflow (they pass their variant's
`workflows/script_submitter/v3.6/<variant>.yaml`). `emed`, `hsp` and `noaa` are meant
for `cluster.einsteinmed.edu`, `activate.hpc.mil` and `noaa.parallel.works`, but they
also run on the cloud clusters of `activate.parallel.works`, which is how their tests
are recorded. A workflow that only runs on the
login node and submits no scheduler job keeps a single `general.yaml` (`doe`, `dakota`,
`design-explorer`): nothing differs between platforms, so a caller on any platform
calls that one file.

## 5. Testing

Every workflow is tested end-to-end at least once, and any end-to-end test is recorded
under `workflows/my-workflow/tests/<variant>/`. The test layout, the test file keys, the
pass criteria and the result columns are documented once, in
[`tools/tests/README.md`](tools/tests/README.md). Start from an existing test, e.g.
`workflows/webshell/tests/<variant>/<test-name>.json`.

Push first — the YAML pulls this repo from GitHub at run time, so local edits to
`app/` are invisible until they are on the referenced branch. Then:

```bash
python3 tools/tests/run-workflow-test.py workflows/my-workflow/tests/<variant>/<test-name>.json
```

Commit the test and the rows the runner appends to its CSV with your change; never
edit a CSV by hand. What pass means depends on the shape:

- An **endpoint** test passes when the run completes and the endpoint is listed. The
  runner never probes the URL: a run only completes after the workflow's own health
  check, and the wait job's output (`pw workflows runs logs <slug> --job wait_for_endpoint`)
  shows the status codes it saw.
- A workflow that **registers no endpoint** sets `_test.endpoint: false` and passes
  when the run completes.
- A **failure-path** test (an `exit 1` before the service starts, an input the form
  forbids) sets `_test.expect: error`. Record one: the success path never exercises
  the error-handling steps.
- A **Kubernetes** test (`tests/k8s/`, `tests/general_k8s/`) passes when the wait job
  completes while the run is still running; the runner cancels the run to tear it down.

**Verify cleanup on cancel — part of testing, every time.** Cancel a run mid-flight
(`pw workflows runs cancel <slug>` while the service is starting or serving) and
confirm the cleanup actually ran: no service processes left (`ps -x`), no scheduler
job (`squeue`/`qstat` when `scheduler:true`), no container instances
(`singularity instance list`, `docker ps`), no stray listeners, no `stopped` record
left in `pw endpoints list`. Apps that daemonize and re-parent to PID 1 (e.g. RStudio's
`rsession`) survive the tree kill and need `cancel.sh` (§2).

While iterating, point the YAML's checkout `branch:` at a development branch and
restore it to `canary` before the PR merges (canary only accepts pull requests).

## 6. Debugging

Everything a run did is in its job dir on the execution node:
`~/pw/jobs/<run-slug>/` for CLI file runs, or
`~/pw/jobs/<workflow-name>/<run-number, 5 digits>/` for registered workflows.

- `run.<JOBID>.out` — the submitted script's stdout/stderr (the service's, or the
  batch job's)
- `logs/<job>/step_N/step.out`, `step.exit` — per-step trace and exit code
- `logs/<job>/step_N/script-unstable.sh` — the **rendered** step: every `${{ input }}`
  appears as the literal value the form sent. When a value seems ignored (a default
  not applied, an empty field), read this first.
- From any machine: `pw workflows runs errors <slug>` and `pw workflows runs logs <slug>`.

## Common pitfalls

- **Testing unpushed code** — the checkout fetches GitHub, not your working tree.
- **Relative YAML path in `pw workflows run`** — parsed as a git host; use absolute.
- **Composing checkout paths wrong** — checked-out files materialize at
  `${PW_PARENT_JOB_DIR}/workflows/<name>/app/…` (or `…/<impl>/…`), including paths
  built from variables (`"${PW_PARENT_JOB_DIR}/${service_name}"`-style bugs surface
  only at run time).
- **Globs copy everything in the directory they target.** Some preprocessing steps
  collect support files with a glob — e.g. jupyter runs `cp workflows/jupyter/app/*.yaml .`
  to gather its conda-env files. That only works because `app/` contains nothing but
  runtime files: the workflow's own variant YAMLs live in `yamls/`, outside `app/`.
  Keep it that way — a workflow YAML (or any unrelated file) placed inside `app/`
  would be swept into every run.
- **A `--dry-run` that passes proves little** — it validates the YAML and each
  subworkflow's required inputs, not unknown fields or a wrong variant; only a real run
  tests a workflow.
- **Single-attempt ghcr pulls** — ghcr intermittently rate-limits anonymous pulls;
  use `tools/oras/libs.sh:oras_pull_file` (it retries) and keep packages public.
- **A registered workflow ignoring your defaults** — the registration pins one YAML
  path (`pw workflows get <name>` → `remote.yaml`); if it points at the wrong variant,
  the form (and its defaults) are the wrong variant's.
- **"Authentication has expired"** — `pw` tokens lapse; re-run `pw auth`.

## Appendix: converting an older workflow

To bring an older session-tunnel workflow onto the endpoint shape, follow
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`; which
workflows those are and where they live is in MIGRATION.md.
