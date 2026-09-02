# Parallel Works Workflows

The home of the Parallel Works / ACTIVATE platform workflows.

**One workflow = one directory** under [`workflows/`](workflows/): the variant YAMLs
(in `yamls/`), the `controller.sh`/`start-template.sh` scripts, support files, README,
and marketplace thumbnails (in `thumbnails/`) all live together. There are **no
version suffixes** — every file is the latest version; git tags version the repo.
Every workflow serves through the **`pw` endpoint pattern**.

How this repo was assembled, and where anything older lives, is recorded in
[MIGRATION.md](MIGRATION.md).

## Workflow index

| Workflow | What it serves | Variants |
|---|---|---|
| [agent-orchestrator](workflows/agent-orchestrator/) | Multi-agent orchestrator service | general |
| [hermes-agent](workflows/hermes-agent/) | Hermes agent with auth/TCP proxies | general |
| [jupyter](workflows/jupyter/) | Jupyter Notebook (classic) | general, noaa |
| [jupyterlab](workflows/jupyterlab/) | JupyterLab | general, hsp, noaa, general_k8s, k8s |
| [kasmvnc](workflows/kasmvnc/) | KasmVNC desktop (Singularity) | general, general_rstudio, hsp, noaa, noaa_rstudio, general_k8s, k8s |
| [langflow-singularity](workflows/langflow-singularity/) | Langflow (Singularity) | hsp |
| [librechat](workflows/librechat/) | LibreChat (+ `-all` stacks with manager & Langflow) | general, hsp, general-all, hsp-all |
| [lite-agent](workflows/lite-agent/) | Lightweight agent worker | general |
| [mlflow](workflows/mlflow/) | MLFlow on Kubernetes | k8s |
| [n8n](workflows/n8n/) | n8n automation (Docker/Singularity) | general, hsp, noaa |
| [ollama](workflows/ollama/) | Ollama GGUF model server (native/container) | general, hsp, noaa |
| [ollama-openwebui](workflows/ollama-openwebui/) | Ollama + OpenWebUI on Kubernetes | k8s |
| [open-notebook](workflows/open-notebook/) | Open Notebook (Docker) | general |
| [openvscode](workflows/openvscode/) | OpenVSCode Server | general, emed, hsp, noaa, general_k8s, k8s |
| [rag-service](workflows/rag-service/) | RAG search/index service | general |
| [rag-vllm](workflows/rag-vllm/) | vLLM inference server + optional RAG stack | general, hsp, noaa |
| [streamlit](workflows/streamlit/) | Streamlit apps (Singularity) | general, hsp |
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

**Tutorials** — [`tutorials/`](tutorials/) are staged, runnable lessons that build a
small demo app ([`demo-app/`](tutorials/demo-app/)) into a full workflow:
[`endpoint-workflows/`](tutorials/endpoint-workflows/) (the current `pw endpoints`
pattern, stages 1–7 incl. matrix fan-out, first-start-wins, and failover) and
[`session-workflows-hsp/`](tutorials/session-workflows-hsp/) (the same journey with
the older session-tunnel pattern, HSP-flavored).

## Variants

`general` targets standard cloud/on-prem SLURM & PBS clusters. `emed`, `hsp`, and
`noaa` are platform-deployment variants with their own schedulers, defaults, and
network constraints — they can only be run from those platforms. `*k8s*` variants
target Kubernetes clusters ([docs/k8s-workflows.md](docs/k8s-workflows.md)).

## Running a workflow

From a machine with the [`pw` CLI](https://parallelworks.com/docs/cli) authenticated:

```bash
pw workflows run "$PWD/workflows/webshell/yamls/general.yaml" -i '{"cluster":{"resource":"<cluster-name>","scheduler":false}}'
```

(Pass the YAML as an **absolute path** — the CLI parses relative paths as git hosts.)

Every workflow registers a **`pw` endpoint** (check `pw endpoints list`).
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
