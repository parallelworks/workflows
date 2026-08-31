# Kubernetes Workflows

Some workflows in this repo target Kubernetes clusters instead of (or in addition to)
SLURM/PBS compute clusters. There are two distinct patterns, and both can live in the
same workflow directory:

## Standalone Kubernetes workflows (`k8s.yaml`)

Single self-contained YAML files that deploy directly to a Kubernetes cluster with
`kubectl` — Deployments, Services, PersistentVolumeClaims, and the full lifecycle
including cleanup. They need no scripts or other files, and they do not use the
`session_runner`/`script_submitter` subworkflows.

| Workflow | File | Notes |
|---|---|---|
| JupyterLab | `workflows/jupyterlab/k8s.yaml` | readme: `k8s-readme.md` |
| KasmVNC | `workflows/kasmvnc/k8s.yaml` | readme: `k8s-readme.md` |
| Code Server | `workflows/openvscode/k8s.yaml` | readme: `k8s-readme.md` |
| MLFlow | `workflows/mlflow/k8s.yaml` | k8s-only workflow (its `README.md`) |
| Ollama + OpenWebUI | `workflows/ollama-openwebui/k8s.yaml` | k8s-only workflow (its `README.md`) |

## Hybrid workflows (`general_k8s.yaml`)

One workflow file that adapts to the selected resource: on a compute cluster it runs
the usual controller/start-template scripts through `script_submitter`; on a
Kubernetes cluster it conditionally executes k8s jobs instead.

| Workflow | File |
|---|---|
| JupyterLab | `workflows/jupyterlab/general_k8s.yaml` |
| KasmVNC | `workflows/kasmvnc/general_k8s.yaml` |
| Code Server | `workflows/openvscode/general_k8s.yaml` |
| VNC Desktop | `workflows/vncserver/general_k8s.yaml`, `workflows/vncserver/rstudio_k8s.yaml` |

### When to use each

- **Standalone `k8s.yaml`**: Kubernetes-only deployments of containerized services —
  simpler, no setup scripts, no subworkflow features.
- **Hybrid `general_k8s.yaml`**: one workflow that must support both compute clusters
  and Kubernetes, reusing the existing controller/start-template scripts on the
  cluster side.
