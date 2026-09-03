# Ollama + Open WebUI on Kubernetes

Deploys an Ollama model server and an Open WebUI chat interface on a
Kubernetes cluster and exposes the WebUI through a platform session.

## How it works

Two Deployments are created in the selected namespace:

- **Ollama** (default image `ollama/ollama:latest`, port 11434) — optionally
  with GPUs (NVIDIA/AMD/TPU or a custom resource key). A PersistentVolumeClaim
  mounted at `/root/.ollama` stores the downloaded models; create a new PVC or
  reuse an existing one.
- **Open WebUI** (default image `ghcr.io/open-webui/open-webui:main`, port
  8080) — pointed at the Ollama service in-cluster, with authentication
  disabled.

Once the pods are ready, the workflow pulls the `llama3`, `mistral`, and
`phi3` models, attaches the session to the WebUI service, and streams logs
from both deployments.

## Cleanup

Canceling the run deletes both Deployments and Services. A new PVC is also
deleted unless you set **Persist PVC After Completion** — persist it to avoid
re-downloading models on the next run.

Only variant: `yamls/k8s.yaml`.
