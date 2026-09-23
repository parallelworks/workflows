# Parallel Works Workflows

The home of the Parallel Works / ACTIVATE platform workflows.

**One workflow = one directory** under [`workflows/`](workflows/): the variant YAMLs
(in `yamls/`), the runtime files (`controller.sh`/`start-template.sh` + support files,
in `app/` or an implementation subdir — the only subtree checked out at run time),
README, build tooling, and marketplace thumbnails (in `thumbnails/`) all live together. There are **no
version suffixes** — every file is the latest version; git tags version the repo.
Every workflow but [activate-batch](workflows/activate-batch/) (a batch script run to
completion) and [ray-cluster](workflows/ray-cluster/) (a Ray cluster behind a platform
session, held by its run) serves through the **`pw` endpoint pattern**.

How this repo was assembled, and where anything older lives, is recorded in
[MIGRATION.md](MIGRATION.md).

## Workflow index

| Workflow | What it serves | Variants |
|---|---|---|
| [activate-batch](workflows/activate-batch/) | Batch job: a list of commands run on the login node or via SLURM/PBS (no endpoint) | general, hsp |
| [agent-orchestrator](workflows/agent-orchestrator/) | Multi-agent orchestrator service | general |
| [hermes-agent](workflows/hermes-agent/) | Hermes agent with auth/TCP proxies | general |
| [jupyter](workflows/jupyter/) | Jupyter Notebook (classic) | general, emed, noaa |
| [jupyterlab](workflows/jupyterlab/) | JupyterLab | general, emed, hsp, noaa, general_k8s, k8s |
| [kasmvnc](workflows/kasmvnc/) | KasmVNC desktop (Singularity) | general, general_rstudio, emed, emed_{rstudio, matlab, firefox, fsl, schrodinger, vmd}, hsp, noaa, noaa_rstudio, general_k8s, k8s |
| [langflow-singularity](workflows/langflow-singularity/) | Langflow (Singularity) | hsp |
| [librechat](workflows/librechat/) | LibreChat (+ `-all` stacks with manager & Langflow) | general, hsp, general-all, hsp-all |
| [lite-agent](workflows/lite-agent/) | Lightweight agent worker | general |
| [mlflow](workflows/mlflow/) | MLFlow on Kubernetes | k8s |
| [n8n](workflows/n8n/) | n8n automation (Docker/Singularity) | general, emed, hsp, noaa |
| [ollama](workflows/ollama/) | Ollama GGUF model server (native/container) | general, hsp, noaa |
| [ollama-openwebui](workflows/ollama-openwebui/) | Ollama + OpenWebUI on Kubernetes | k8s |
| [open-notebook](workflows/open-notebook/) | Open Notebook (Docker) | general |
| [openvscode](workflows/openvscode/) | OpenVSCode Server | general, emed, hsp, noaa, general_k8s, k8s |
| [rag-service](workflows/rag-service/) | RAG search/index service | general |
| [rag-vllm](workflows/rag-vllm/) | vLLM inference server + optional RAG stack | general, hsp, noaa |
| [ray-cluster](workflows/ray-cluster/) | Multi-site Ray cluster: head + live dashboard on one resource, SLURM/PBS/SSH workers on any others (platform session; the run holds the cluster, cancel = teardown) | general, hsp, general_add_worker, hsp_add_worker |
| [streamlit](workflows/streamlit/) | Streamlit apps (Singularity) | general, hsp |
| [vncserver](workflows/vncserver/) | Host desktop (KasmVNC, no container) | emed, emed_{rstudio, matlab, firefox, fsl, schrodinger, vmd} |
| [webshell](workflows/webshell/) | Web terminal (ttyd) | general, noaa |

`librechat-singularity-manager` is a component of the librechat `-all` workflows
([workflows/librechat/librechat-singularity-manager/](workflows/librechat/librechat-singularity-manager/)).

**Shared subworkflow** (referenced by the workflow YAMLs via
`uses: github/parallelworks/workflows@canary` + `$yaml:`):

- [workflows/script_submitter/v3.6/](workflows/script_submitter/) — SLURM/PBS/SSH
  script submission used by every workflow

**Shared tools** — [`tools/`](tools/) (`tools/oras`, `tools/utils`) are sparse-checked-out
next to `workflows/<name>` at runtime; scripts reference them as `tools/...` relative
to the run directory.

**Tests** — each workflow's end-to-end tests live under `workflows/<name>/tests/<variant>/`;
layout, runner and results are documented in [`tools/tests/README.md`](tools/tests/README.md).

**Tutorials** — [`tutorials/`](tutorials/) are staged, runnable lessons that build a
small demo app ([`demo-app/`](tutorials/demo-app/)) into a full workflow:
[`endpoint-workflows/`](tutorials/endpoint-workflows/) (the current `pw endpoints`
pattern, stages 1–7 incl. matrix fan-out, first-start-wins, and failover) and
[`session-workflows-hsp/`](tutorials/session-workflows-hsp/) (the same journey, HSP-flavored,
in the older form the upgrade playbook converts). [`if-conditions/`](tutorials/if-conditions/)
is a short standalone lesson on the `if:` status keywords (`always`, `never`, `completed`,
`error`, `canceled` and their negations) on steps and on jobs.

## Variants

`general` targets standard cloud/on-prem SLURM & PBS clusters. `emed`, `hsp`, and
`noaa` are platform-deployment variants with their own schedulers, defaults, and
network constraints — they can only be run from those platforms. `*k8s*` variants
target Kubernetes clusters ([.claude/skills/activate-workflows/references/k8s-workflows.md](.claude/skills/activate-workflows/references/k8s-workflows.md)).

## Running a workflow

From a machine with the [`pw` CLI](https://parallelworks.com/docs/cli) authenticated:

```bash
pw workflows run "$PWD/workflows/webshell/yamls/general.yaml" -i '{"cluster":{"resource":"<cluster-name>","scheduler":false}}'
```

(Pass the YAML as an **absolute path** — the CLI parses relative paths as git hosts.)

When testing a workflow, also verify cleanup: cancel a run mid-flight and confirm
nothing is left behind (processes, scheduler jobs, containers), and delete test
endpoints when done — see [DeveloperGuide.md](DeveloperGuide.md).

Every endpoint workflow registers a **`pw` endpoint** (check `pw endpoints list`);
`activate-batch` runs its commands to completion instead, and `ray-cluster` registers a
platform session and keeps running until it is cancelled.
Note that workflow YAMLs pull this repo from GitHub at runtime
(`parallelworks/checkout` + subworkflow `uses:`), so local YAML edits only take full
effect once pushed to the referenced branch (**canary**).

## Developing

- [DeveloperGuide.md](DeveloperGuide.md) — how to add or change a workflow
- [CLAUDE.md](CLAUDE.md) — repo conventions (also read by AI agents)
- [docs/ai-workflow-development/](docs/ai-workflow-development/) — building workflows
  with AI agents; the `activate-workflows` Claude Code skill lives at
  [.claude/skills/activate-workflows/](.claude/skills/activate-workflows/)
- [MIGRATION.md](MIGRATION.md) — the consolidation map: where every file came from,
  what stayed behind, and why
- Official platform docs:
  [building workflows](https://parallelworks.com/docs/run/workflows/building-workflows)
  ([YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
  [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions)) ·
  [endpoint sessions](https://parallelworks.com/docs/run/sessions/endpoints) ·
  [`pw endpoints` CLI](https://parallelworks.com/docs/cli/pw/endpoints)
