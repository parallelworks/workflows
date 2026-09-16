# MLflow on Kubernetes

Deploys the MLflow tracking UI on a Kubernetes cluster and exposes it as a `pw`
endpoint.

## How it works

The workflow authenticates `kubectl` against the selected cluster, creates a
Deployment from the chosen image (default `ubuntu/mlflow:2.1.1_1.0-22.04`,
running `mlflow ui` on the configured port, default 5000) with a `pw` client
sidecar that publishes that port as the endpoint `mlflow-<run-slug>`, waits for
the pod to be ready and for the endpoint to be listed, and streams the pod logs
into the run for the life of the deployment.

Storage: a PersistentVolumeClaim is mounted at the configured mount path
(default `/mnt`) — create a new PVC (size, storage class) or select an
existing one.

## Cleanup

Canceling the run is the teardown: it deletes the Deployment and the API key
Secret, and the endpoint disappears with the sidecar. A new PVC is also deleted
unless you set **Persist PVC After Completion**.
