# Parallel Works Workflows

The consolidated home of the Parallel Works / ACTIVATE platform workflows previously
split across [`interactive_session`](https://github.com/parallelworks/interactive_session)
and [`activate-rag-vllm`](https://github.com/parallelworks/activate-rag-vllm).

**One workflow = one directory** under [`workflows/`](workflows/): the variant YAMLs
(grouped in a `yamls/` subdirectory), the `controller.sh`/`start-template.sh` scripts,
support files, README, and thumbnail all live together. There are **no version
suffixes** — every file is the latest version, and git tags version the repo.
Legacy-generation variants that still depended on older scripts were left behind in
`interactive_session` until they are converted to the endpoint pattern
(see [MIGRATION.md](MIGRATION.md)).

## Workflow index

| Workflow | What it serves | Variants |
|---|---|---|
| [agent-orchestrator](workflows/agent-orchestrator/) | Multi-agent orchestrator service | general |
| [hermes-agent](workflows/hermes-agent/) | Hermes agent with auth/TCP proxies | general |
| [jupyter](workflows/jupyter/) | Jupyter Notebook (classic) | general, noaa |
| [jupyterlab](workflows/jupyterlab/) | JupyterLab | general, hsp, noaa, general_k8s, k8s |
| [kasmvnc](workflows/kasmvnc/) | KasmVNC desktop (Singularity) | general, hsp, noaa, noaa_rstudio, general_k8s, k8s |
| [langflow-host](workflows/langflow-host/) | Langflow (host install) | general, hsp |
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
| [vncserver](workflows/vncserver/) | VNC desktop + apps (MATLAB, RStudio, …) | general, emed(+apps), noaa(+apps), general_k8s, rstudio_k8s |
| [webshell](workflows/webshell/) | Web terminal (ttyd) | general, noaa |

`librechat-singularity-manager` is a component of the librechat `-all` workflows
([workflows/librechat/librechat-singularity-manager/](workflows/librechat/librechat-singularity-manager/));
its standalone workflow was legacy-generation and stayed in `interactive_session`.

**Shared subworkflows** (referenced by the workflow YAMLs via
`uses: github/parallelworks/workflows@canary` + `$yaml:`):

- [workflows/session_runner/v1.4/](workflows/session_runner/) — session orchestration
  for the session-generation workflows (vncserver, langflow-host)
- [workflows/script_submitter/v3.6/](workflows/script_submitter/) — SLURM/PBS/SSH
  script submission used by everything else

**Shared tools** — [`tools/`](tools/) (`tools/oras`, `tools/utils`) are sparse-checked-out
next to `workflows/<name>` at runtime; scripts reference them as `tools/...` relative
to the run directory.

**Tutorials** — [`tutorials/`](tutorials/) are staged, runnable lessons on the
workflow system (job DAGs, sessions, endpoints, matrix fan-out, retries/failover).

## Variants

`general` targets standard cloud/on-prem SLURM & PBS clusters. `emed`, `hsp`, and
`noaa` are platform-deployment variants with their own schedulers, defaults, and
network constraints — they can only be run from those platforms. `*k8s*` variants
target Kubernetes clusters ([docs/k8s-workflows.md](docs/k8s-workflows.md)).

## Running a workflow

From a machine with the [`pw` CLI](https://parallelworks.com/docs/cli) authenticated:

```bash
pw workflows run ./workflows/webshell/yamls/general.yaml -i '{"cluster":{"resource":"<cluster-name>","scheduler":false}}'
```

Most workflows register a **`pw` endpoint** (check `pw endpoints list`); the
session-generation ones (vncserver, langflow-host) create a **platform tunnel
session**. Note that workflow YAMLs pull this repo from GitHub at runtime
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
