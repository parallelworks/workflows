# MLflow on Kubernetes

Deploys the MLflow tracking UI on a Kubernetes cluster and exposes it through
a platform session.

## How it works

The workflow authenticates `kubectl` against the selected cluster, creates a
Deployment and Service from the chosen image (default
`ubuntu/mlflow:2.1.1_1.0-22.04`, running `mlflow ui`), waits for the pod to be
ready, and attaches the session to the service port (default 5000). Logs
stream into the run for the life of the deployment.

Storage: a PersistentVolumeClaim is mounted at the configured mount path
(default `/mnt`) — create a new PVC (size, storage class) or select an
existing one.

## Cleanup

Canceling the run deletes the Deployment and Service. A new PVC is also
deleted unless you set **Persist PVC After Completion**.
