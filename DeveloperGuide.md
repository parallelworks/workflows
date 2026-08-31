# Developer Guide: Creating a New Workflow

A session workflow lives in **one directory**, `workflows/my-session/`, and needs three
things:

| File | Runs on | Purpose |
|------|---------|---------|
| `controller.sh` | Controller (login) node | Install software, download dependencies |
| `start-template.sh` | Controller or compute node | Start the web service |
| `<variant>.yaml` (e.g. `general.yaml`) | Platform | Define the UI form, generate `inputs.sh`, orchestrate |

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

`workflows/my-session/general.yaml`. Its jobs:

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

**Copy a real one instead of writing from scratch** — `workflows/webshell/general.yaml`
is the smallest complete example; `workflows/jupyterlab/general.yaml` shows a conda
install plus support files. Key parts to adapt:

- the hidden `service.name` input (endpoint name prefix),
- the sparse-checkout paths (`workflows/my-session`, `tools/...`),
- the `cat workflows/my-session/controller.sh` / `start-template.sh` lines,
- the `service` input group (your form fields → `inputs.sh` variables).

Never copy file globs from the workflow dir (`cp workflows/my-session/*.yaml .` would
grab the workflow YAMLs themselves) — enumerate the files you need.

## 4. Platform variants

One YAML per deployment: `general.yaml` (standard SLURM/PBS clusters), plus
`emed.yaml` / `hsp.yaml` / `noaa.yaml` where the workflow is offered there. Variants
differ in scheduler directives, partitions, module loads, and defaults — copy the
matching variant of a similar workflow (they pass their variant's
`workflows/script_submitter/v3.6/<variant>.yaml`).

## 5. Testing

```bash
# from the repo root, after pushing your branch (the YAML pulls the repo from GitHub at runtime)
pw workflows run ./workflows/my-session/general.yaml -i '{"cluster":{"resource":"<cluster>","scheduler":false}}'
pw endpoints list        # your endpoint should come online
# cancel the run in the UI or with pw, then confirm the service was cleaned up
```

While iterating you can point the YAML's checkout `branch:` at a development branch;
restore it to `canary` before merging.

## Appendix: the v4 / session_runner generation

Some variants (all of `vncserver` and `langflow-host`; the `emed` variants of
`jupyter`, `jupyterlab`, `n8n`, `kasmvnc`; `webshell/hsp.yaml`; `kasmvnc/general-rstudio.yaml`;
`librechat-singularity-manager`; `langflow-singularity/general.yaml`; `rag-vllm/emed.yaml`)
still use the older pattern: a `sessions:` block, `-v3` scripts, and
`workflows/session_runner/v1.4/<variant>.yaml`, which registers a **platform tunnel
session** instead of a `pw` endpoint. Its interface (session, resource, cluster
scheduler settings, `service.{start_service_script,controller_script,inputs_sh,slug,rundir}`)
is documented in `workflows/session_runner/v1.4/README.md`. New workflows should use
the endpoint pattern; to upgrade an old variant, follow
`.claude/skills/activate-workflows/references/v4-to-v5-endpoints-upgrade.md`.
