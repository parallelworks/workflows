# Developer Guide: Creating a New Workflow

A session workflow lives in **one directory**, `workflows/my-session/`, and needs three
things:

| File | Runs on | Purpose |
|------|---------|---------|
| `controller.sh` | Controller (login) node | Install software, download dependencies |
| `start-template.sh` | Controller or compute node | Start the web service |
| `yamls/<variant>.yaml` (e.g. `yamls/general.yaml`) | Platform | Define the UI form, generate `inputs.sh`, orchestrate |

The controller node always has internet access. The compute node may not.

Working with an AI assistant? The repo ships a Claude Code skill —
`.claude/skills/activate-workflows/` — that encodes this process plus the platform
reference. In Claude Code: *"Using the activate-workflows skill, create a new
interactive session workflow for [deployment] that [does X]."*

## 1. The controller script

`workflows/my-session/controller.sh` runs **before** the service starts, on the login
node. Use it for anything needing internet. All `inputs.sh` variables are available.

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

`workflows/my-session/start-template.sh` starts the web service. The platform provides
`service_port` — your service **must** listen on it. All `inputs.sh` variables are
available.

```bash
#!/bin/bash
if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# cancel.sh lets the platform stop the service
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

${service_parent_install_dir}/my-server --port=${service_port} &
pid=$!
echo "kill ${pid}" >> cancel.sh

sleep inf
```

Requirements: listen on **`service_port`**, write a **`cancel.sh`**, end with
**`sleep inf`** (or run the service in the foreground).

## 3. The workflow YAML

`workflows/my-session/yamls/general.yaml`. Its jobs:

1. **preprocessing** — `parallelworks/checkout` of this repo (sparse:
   `workflows/my-session`, plus `tools/...` if the scripts use the shared tools),
   generate `inputs.sh` from the form values + `PW_*` environment, run
   `inputs.sh + controller.sh` inline, and assemble the start script
   (`inputs.sh` + a cleanup trap + `start-template.sh`).
2. **session_runner** (the job name kept for history) — submit the start script via
   `workflows/script_submitter/v3.6/<variant>.yaml`
   (`uses: github/parallelworks/workflows@canary`).
3. **wait_for_endpoint** — poll `pw endpoints list` until the endpoint named
   `<service.name>-${PW_RUN_SLUG}` is online, then leave the service running
   (`SKIP_CLEANUP` marker) and cancel the submitter's wait.

**Copy a real one instead of writing from scratch** —
`workflows/webshell/yamls/general.yaml` is the smallest complete example;
`workflows/jupyterlab/yamls/general.yaml` shows a conda install plus support files.
Key parts to adapt:

- the hidden `service.name` input (endpoint name prefix),
- the sparse-checkout paths (`workflows/my-session`, `tools/...`),
- the `cat workflows/my-session/controller.sh` / `start-template.sh` lines,
- the `service` input group (your form fields → `inputs.sh` variables).

## 4. Platform variants

One YAML per deployment: `yamls/general.yaml` (standard SLURM/PBS clusters), plus
`emed.yaml` / `hsp.yaml` / `noaa.yaml` where the workflow is offered there. Variants
differ in scheduler directives, partitions, module loads, and defaults — copy the
matching variant of a similar workflow (they pass their variant's
`workflows/script_submitter/v3.6/<variant>.yaml`).

## 5. Testing

Push first — the YAML pulls this repo from GitHub at run time, so local edits are
invisible until they are on the referenced branch. Then, with the **absolute** YAML
path (a relative path is parsed as a git host):

```bash
pw workflows run /abs/path/workflows/my-session/yamls/general.yaml \
    -i '{"cluster":{"resource":"<cluster>","scheduler":false}}'
pw endpoints list                       # pass = my-session-<run-slug> online, URL serves
pw endpoints delete my-session-<slug>   # tear down; confirm with ps -x
```

While iterating, point the YAML's checkout `branch:` at a development branch and
restore it to `canary` before the PR merges (canary only accepts pull requests).

## 6. Debugging

Everything a run did is in its job dir on the execution node
(`~/pw/jobs/<slug>/`, or `~/pw/jobs/<name>/<NNNNN>/` for registered workflows):

- `run.<JOBID>.out` — the service's stdout/stderr
- `logs/<job>/step_N/step.out`, `step.exit` — per-step trace and exit code
- `logs/<job>/step_N/script-unstable.sh` — the **rendered** step: every `${{ input }}`
  appears as the literal value the form sent. When a value seems ignored (a default
  not applied, an empty field), read this first.
- From any machine: `pw workflows runs errors <slug>` and `pw workflows runs logs <slug>`.

## Common pitfalls

- **Testing unpushed code** — the checkout fetches GitHub, not your working tree.
- **Relative YAML path in `pw workflows run`** — parsed as a git host; use absolute.
- **Composing checkout paths without the `workflows/` prefix** — checked-out files
  materialize at `${PW_PARENT_JOB_DIR}/workflows/<name>/…`, including paths built
  from variables (`"${PW_PARENT_JOB_DIR}/${service_name}"`-style bugs surface only at
  run time).
- **Globbing the workflow dir** — variant YAMLs live in `yamls/` precisely so
  `cp workflows/<name>/*.yaml .` grabs only support files; keep it that way.
- **Single-attempt ghcr pulls** — ghcr intermittently rate-limits anonymous pulls;
  use `tools/oras/libs.sh:oras_pull_file` (it retries) and keep packages public.
- **A registered workflow ignoring your defaults** — the registration pins one YAML
  path (`pw workflows get <name>` → `remote.yaml`); if it points at the wrong variant,
  the form (and its defaults) are the wrong variant's.
- **"Authentication has expired"** — `pw` tokens lapse; re-run `pw auth`.

## Appendix: the legacy session pattern

The older pattern (a `sessions:` block + the `session_runner` subworkflow registering
a **platform tunnel session** on an injected `${service_port}`) is not used by
anything in this repo. The workflows and variants that still depend on it — vncserver,
langflow-host, the emed files, webshell hsp, kasmvnc general-rstudio/northrop,
langflow-singularity general, librechat-singularity-manager's standalone workflow,
rag-vllm emed — live in `parallelworks/interactive_session`. To convert one to the
endpoint pattern and bring it here, follow
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`.
