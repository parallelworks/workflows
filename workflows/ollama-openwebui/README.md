# Ollama + Open WebUI on Kubernetes

Deploys an Ollama model server and an Open WebUI chat interface on a
Kubernetes cluster and exposes the WebUI as the `pw` endpoint
`ollama-openwebui-<run-slug>`.

## How it works

Two Deployments are created in the selected namespace:

- **Ollama** (default image `ollama/ollama:latest`, port 11434) — optionally
  with GPUs (NVIDIA/AMD/TPU or a custom resource key). A PersistentVolumeClaim
  mounted at `/root/.ollama` stores the downloaded models; create a new PVC or
  reuse an existing one.
- **Open WebUI** (default image `ghcr.io/open-webui/open-webui:main`, port
  8080) — pointed at the Ollama service in-cluster, with authentication
  disabled, plus a `pw` client sidecar that publishes the port as the endpoint.

Once the pods are ready, the workflow pulls the `llama3`, `mistral`, and
`phi3` models, waits for the endpoint to be listed, and streams logs from both
deployments. The default requests (2 CPUs for Ollama, 1 for Open WebUI, plus the sidecar's
50m) fit a 4-CPU namespace quota.

## Cleanup

Canceling the run is the teardown: it deletes both Deployments, the Ollama
Service and the API key Secret, and the endpoint disappears with the sidecar. A
new PVC is also deleted unless you set **Persist PVC After Completion** — persist
it to avoid re-downloading models on the next run.
