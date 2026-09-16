# Kubernetes workflows

How a workflow in this repo serves a web app from a Kubernetes cluster attached to
the platform, and how to build, run, test and debug one. Everything here was
verified on the `k3sgpu` cluster (2026-09-16); the files named are the working
examples.

## Two layouts, one pattern

| layout | files | use it when |
|---|---|---|
| Standalone, k8s-only | `workflows/{jupyterlab,kasmvnc,openvscode,mlflow,ollama-openwebui}/yamls/k8s.yaml` | the service only runs on Kubernetes; the smallest complete example to copy |
| Hybrid | `workflows/{jupyterlab,kasmvnc,openvscode}/yamls/general_k8s.yaml` | one form for compute clusters and Kubernetes; every k8s job carries `if: ${{ inputs.resource.type == 'kubernetes' }}` and every script_submitter job the negation |

Both serve the app the way every workflow here does: through a **`pw` endpoint**
named `<service_k8s.name>-${PW_RUN_SLUG}`. What differs from the compute-cluster
pattern is where the `pw` client runs and who owns the service's lifetime.

Nothing is fetched from GitHub on the k8s path: the platform reads the YAML you
pass and the steps render the Kubernetes manifests inline, so a YAML-only change
runs without a push.

## How the k8s path works

The k8s jobs have no `ssh:` block, so they run on the user's workspace node, where
`pw` and `kubectl` are installed.

1. **`auth_k8s`** runs `pw kube auth <cluster>`: it writes a kubeconfig context
   `pw#<cluster>` whose exec plugin is `pw kube token`.
2. **`prepare_k8s_pvc`** renders `pvc.yaml` for a new PVC (default StorageClass
   unless one is given) and checks it with `kubectl apply --dry-run=client`.
3. **`prepare_k8s_deployment`** derives the app name from `${PW_USER}` and the job
   directory (`<user>jobs<run-slug>` for CLI runs) and renders `app.yaml`: a
   Deployment with an init container that opens the mount path, the app container,
   and the **`pw-endpoint` sidecar**:

   ```yaml
   - name: pw-endpoint
     image: ghcr.io/parallelworks/pw-cli:v7.79.0
     args:
       - endpoints
       - http                       # https when the image serves TLS (kasmweb)
       - --name
       - ${{ inputs.service_k8s.name }}-${PW_RUN_SLUG}
       - --slug                     # optional landing path or query string
       - lab
       - --output
       - text
       - "${{ inputs.service_k8s.image_port }}"
     env:
       - name: PW_PLATFORM_HOST
         value: "${PW_PLATFORM_HOST}"
       - name: PW_API_KEY
         valueFrom:
           secretKeyRef:
             name: <app-name>-pw-api-key
             key: PW_API_KEY
     resources:
       requests: {memory: "64Mi", cpu: "50m"}
       limits: {memory: "256Mi", cpu: "500m"}
   ```

   The sidecar dials out from inside the pod and forwards the endpoint to
   `localhost:<image_port>`, so the pod needs no Service and no ingress.
   `ollama-openwebui` keeps one Service, for Open WebUI to reach Ollama in-cluster.
4. **`apply_k8s_deployment`** applies the PVC, creates the Secret from the run's
   `PW_API_KEY` (`kubectl create secret generic … --from-literal=PW_API_KEY="${PW_API_KEY}"
   --dry-run=client -o yaml | kubectl apply -f -`, so the key never lands in a file;
   the top-level `env: {PW_API_KEY: ${PW_API_KEY}}` exposes it to the step), applies
   the Deployment, waits for it and its pod, then **streams the pod logs for as long
   as the service runs** (`kubectl logs -f … --all-containers`, so the sidecar's
   URL and health-check lines are in the run log). Each apply step has a `cleanup:`
   that deletes what it created.
5. **`wait_for_endpoint_k8s`** waits for the `pod.running` marker, then polls
   `pw endpoints list` for the name and prints its URL. In every verified run the
   endpoint was listed within seconds of the pod going Ready.

**Lifecycle.** The run stays `running`. **Cancelling the run is the teardown**: the
cleanup steps delete the Deployment, the Secret and the PVC (unless
`pvc_persist`), and the endpoint deregisters when the sidecar dies; every verified
run was clean within about 20 seconds. `pw endpoints delete` does not tear a k8s
service down: the Deployment restarts the exited sidecar.

## Inputs

- Standalone: `k8s.cluster` (`kubernetes-clusters`), `k8s.namespace`
  (`kubernetes-namespaces`), `k8s.volumes.*`, `k8s.resources.*`, and
  `service_k8s.{name, image, image_port, …}`. `service_k8s.name` is hidden: it is the
  endpoint name prefix, keep it stable.
- Hybrid: `resource` (`compute-resources`; the k8s jobs read `.type` and `.name`),
  the same `k8s` group, `service_k8s` for the container and `service` for the
  compute-cluster scripts, each hidden when the other applies.
- From the CLI, a kubernetes `resource` must be an **object**, not a name:
  `{"id":"<pw kube ls id>","name":"k3sgpu","type":"kubernetes","uri":"pw://k3sgpu"}`
  (a bare name reaches the workflow as a string and every `type == 'kubernetes'`
  guard is false). `k8s.cluster` takes the bare name.

## Running one by hand

```bash
pw kube ls -o json                                   # cluster id and name
python3 tools/tests/run-workflow-test.py --emit workflows/mlflow/tests/k8s/k3sgpu.json > inputs.json
pw workflows run --dry-run /abs/path/workflows/mlflow/yamls/k8s.yaml -i inputs.json
pw workflows run /abs/path/workflows/mlflow/yamls/k8s.yaml -i inputs.json -o json
pw endpoints list                                    # mlflow-<slug>  running  https://<random>.activate.pw/
curl -sI https://<random>.activate.pw/               # 307 to the platform login when anonymous
pw workflows runs cancel <slug>                      # teardown
```

## Testing

Every k8s YAML has a test under `workflows/<name>/tests/k8s/` (standalone) or
`workflows/<name>/tests/general_k8s/` (hybrid), run with the k8s lane of the test
runner, which passes on "endpoint listed and answering while the run is still
running" and tears down by cancelling the run:

```bash
python3 tools/tests/run-workflow-test.py workflows/mlflow/tests/k8s/k3sgpu.json
```

Run k8s tests one at a time: the namespace quota (below) is shared. The lane, its
`_test` keys and the pass criteria are documented in `tools/tests/README.md`.

## Debugging

- `pw workflows runs logs <slug> --job apply_k8s_deployment` has the kubectl output
  and the streamed pod logs; `pw workflows runs errors <slug> -o text` the failures.
- Inspect the cluster from your machine: `pw kube auth --no-context-switch k3sgpu`,
  then `kubectl --context pw#k3sgpu -n <namespace> get pods,pvc,secret` and
  `kubectl --context pw#k3sgpu -n <namespace> get events --sort-by=.lastTimestamp`.
  Scheduling problems only show up in the events.
- **Quota.** Platform namespaces carry a `pw-quota` ResourceQuota (`alvarok8s`:
  4 CPU, 10Gi memory, 2 GPUs). Over quota, the ReplicaSet reports
  `FailedCreate … exceeded quota` in the events while the run log only shows the
  600-second `kubectl wait` timeout and `ProgressDeadlineExceeded`; the job errors,
  the wait job is cancelled and the cleanups still run. Requests add up per pod,
  the sidecar's count too, and under a quota every container must declare
  requests. `ollama-openwebui`'s defaults need the whole 4-CPU quota.
- **Node taints.** `k3sgpu` is one untainted node, so CPU-only pods schedule on the
  GPU node without tolerations. The `nvidia` RuntimeClass is attached only when GPUs
  are requested.
- **Image pulls.** The first pull of a large image (jupyter datascience about 2 GB,
  kasmweb about 1.5 GB) adds a minute or more; pulls are cached on the node.

## Writing a new one

Copy `workflows/mlflow/yamls/k8s.yaml` (the smallest) for a k8s-only workflow or
`workflows/openvscode/yamls/general_k8s.yaml` for a hybrid. Change the image, port
and container args, the hidden `service_k8s.name`, the sidecar's `--slug`, and use
`endpoints https` if the image serves TLS. Keep the Secret, the sidecar, the
`cleanup:` blocks, the log-streaming step and `wait_for_endpoint_k8s`. Add a test
under `tests/k8s/` and record its row.
