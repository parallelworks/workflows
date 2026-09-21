# Kubernetes workflows

> The one place for everything Kubernetes in this repo. SKILL.md, CLAUDE.md,
> `activate-platform.md`, the upgrade playbook and the tests README point here instead
> of repeating it. Verified on the platform cluster `k3sgpu` on 2026-09-16: every file
> named below ran (§8).

## 1. Layouts and examples

| layout | files | use it when |
|---|---|---|
| Standalone, k8s-only | `workflows/{jupyterlab,kasmvnc,openvscode,mlflow,ollama-openwebui}/yamls/k8s.yaml` | the service only runs on Kubernetes; `mlflow` is the smallest complete example to copy |
| Hybrid | `workflows/{jupyterlab,kasmvnc,openvscode}/yamls/general_k8s.yaml` | one form for compute clusters and Kubernetes; every k8s job carries `if: ${{ inputs.resource.type == 'kubernetes' }}` and every script_submitter job the negation |

Both keep the repo's one rule: the app is served as a **`pw` endpoint** named
`<service_k8s.name>-${PW_RUN_SLUG}`. The standalone files stay in the repo as k8s-only
examples even where a hybrid covers the same service (maintainer decision, 2026-09-16).
Registrations pin these paths: `marketplace.mlflow.latest` → `mlflow/yamls/k8s.yaml`,
`marketplace.{jupyterlab,openvscode,desktop}.latest` → the `general_k8s.yaml` files.

There is no `script_submitter`, no login node and no checkout on the k8s path: the
platform reads the YAML you pass and the steps render the Kubernetes manifests inline,
so a YAML-only change runs without a push.

## 2. Anatomy of the k8s path

The k8s jobs have no `ssh:` block, so they run on the user's **workspace exec node**,
where `pw` and `kubectl` are installed.

1. **`auth_k8s`** — `pw kube auth <cluster>` writes a kubeconfig context `pw#<cluster>`
   whose exec plugin is `pw kube token`.
2. **`prepare_k8s_pvc`** — renders `pvc.yaml` for a new PVC (default StorageClass
   unless one is given) and checks it with `kubectl apply --dry-run=client`; skipped
   for an existing PVC.
3. **`prepare_k8s_deployment`** — derives the app name from `${PW_USER}` and the job
   directory (`<user>jobs<run-slug>` for CLI runs, so every object carries the run
   slug) and renders `app.yaml`: a Deployment with an init container that opens the
   mount path, the app container, and the **`pw-endpoint` sidecar**:

   ```yaml
   - name: pw-endpoint
     image: ghcr.io/parallelworks/pw-cli:v7.79.0     # public; v7.99.0 is public too
     args:
       - endpoints
       - http                           # https when the image serves TLS (kasmweb)
       - --name
       - ${{ inputs.service_k8s.name }}-${PW_RUN_SLUG}
       - --slug                         # optional landing path or query string
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
   `localhost:<image_port>`: no Service, no ingress (the CLI's env-var auth and the
   distroless image: [activate-platform.md §12](activate-platform.md), "Env-var auth for
   containers/sidecars"). `ollama-openwebui` keeps one Service, for Open WebUI to reach
   Ollama in-cluster.
4. **`apply_k8s_deployment`** — applies the PVC; creates the Secret from the run's key
   (`kubectl create secret generic <app>-pw-api-key --from-literal=PW_API_KEY="${PW_API_KEY}"
   --dry-run=client -o yaml | kubectl apply -f -`: idempotent, and the key never lands
   in a file — the top-level `env: {PW_API_KEY: ${PW_API_KEY}}` exposes it to the step);
   applies the Deployment; waits for it and its pod (`kubectl wait`, 600 s; wait for
   **every** Deployment the file creates); then **streams the pod logs for as long as
   the service runs** (`kubectl logs -f … --all-containers`, so the sidecar's URL and
   health-check lines are in the run log). Every apply step has a `cleanup:` that
   deletes what it created; cleanups run in reverse step order (Deployment → Secret →
   PVC).
5. **`wait_for_endpoint_k8s`** — waits for the `pod.running` marker, then calls the
   `wait_for_endpoint` subworkflow with no `host` (it probes from the workspace) and no
   skip file: it polls `pw endpoints list` for the name and probes the URL until the
   service answers. On failure it does **not** call `pw endpoints delete` — the
   Deployment would just restart the sidecar — the job fails, the log-stream step's
   `early-cancel: any-job-failed` ends the apply job, whose cleanups delete the
   Deployment, and the endpoint deregisters with the sidecar. In every verified run the
   endpoint was listed within seconds of the pod going Ready.

**Lifecycle.** The run stays `running`. **Cancelling the run is the teardown**: the
cleanups delete Deployment, Secret and PVC (unless `pvc_persist`), and the endpoint
deregisters when the sidecar dies — clean within 20–35 s in every verified run.
`pw endpoints delete` cannot tear a k8s service down: the Deployment restarts the
exited sidecar. There is no `skip_cleanups_file` on this path.

## 3. Develop first: the k8s analog of SKILL.md Step 1

There is no login node and `pw ssh` does not apply. Work from your machine:

```bash
pw kube ls -o json                                   # clusters: id, name, cpus, memory
pw kube auth --no-context-switch k3sgpu              # context pw#k3sgpu; your current context stays
K="kubectl --context pw#k3sgpu -n alvarok8s"
$K get resourcequota; $K get storageclass; $K get runtimeclass
kubectl --context pw#k3sgpu get nodes -o wide        # taints: kubectl get nodes -o json | jq '.items[].spec.taints'
```

Prove the image serves on its port before writing any YAML (verified 2026-09-16,
about 10 s end to end):

```bash
cat <<'EOF' | $K apply -f -
apiVersion: v1
kind: Pod
metadata: {name: probe}
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: python:3-alpine
      command: ["python", "-m", "http.server", "8080"]
      resources: {requests: {cpu: "100m", memory: "64Mi"}, limits: {cpu: "500m", memory: "256Mi"}}
EOF
$K wait --for=condition=Ready pod/probe --timeout=180s
$K port-forward pod/probe 18080:8080 & sleep 3; curl -sI http://127.0.0.1:18080/ | head -1; kill %1
$K delete pod probe
```

Use a manifest, not `kubectl run`: under a ResourceQuota every container must declare
requests, and `kubectl run` (1.33) has no `--requests` flag, only `--overrides`. Then
copy the closest example from §1 and change the image, port and args, the hidden
`service_k8s.name`, and the sidecar's `--slug` (`https` for TLS images).

## 4. Inputs and running from the CLI

- Standalone: `k8s.cluster` (`kubernetes-clusters`, takes the **bare cluster name**),
  `k8s.namespace` (`kubernetes-namespaces`), `k8s.volumes.*`, `k8s.resources.*`, and
  `service_k8s.{name, image, image_port, …}` — `name` is hidden and is the endpoint
  prefix; keep it stable.
- Hybrid: `resource` (`compute-resources`; the k8s jobs read `.type` and `.name`), the
  same `k8s` group, `service_k8s` for the container and `service` for the
  compute-cluster scripts, each hidden when the other applies. From the CLI the
  kubernetes `resource` must be an **object**, not a name; the exact JSON and why are
  in [activate-platform.md §2](activate-platform.md#2-resources).

```bash
python3 tools/tests/run-workflow-test.py --emit workflows/mlflow/tests/k8s/k3sgpu.json > inputs.json
pw workflows run --dry-run /abs/path/workflows/mlflow/yamls/k8s.yaml -i inputs.json
pw workflows run /abs/path/workflows/mlflow/yamls/k8s.yaml -i inputs.json -o json
pw endpoints list                               # mlflow-<slug>  running  https://<random>.activate.pw/
curl -sI https://<random>.activate.pw/ | head -1   # 307 to the platform login when anonymous
pw workflows runs cancel <slug>                 # teardown
```

`--dry-run` validated all eight files with these inputs; a dry run is not a test (§5).

## 5. Testing

One test per k8s YAML: `workflows/<name>/tests/k8s/k3sgpu.json` (standalone) and
`workflows/<name>/tests/general_k8s/k3sgpu.json` (hybrid). The runner's **k8s lane**
passes on "endpoint listed and answering while the run is still `running`", tears down
by cancelling the run and checks the namespace with kubectl; its keys, skip rule and
columns are in [tools/tests/README.md](../../../../tools/tests/README.md).

```bash
python3 tools/tests/run-workflow-test.py workflows/mlflow/tests/k8s/k3sgpu.json
```

Run k8s tests **one at a time**: the namespace quota (§7) is shared.

## 6. Debugging

- `pw workflows runs logs <slug> --job apply_k8s_deployment` has the kubectl output and
  the streamed pod logs; the sidecar prints `Endpoint "<name>" serving localhost:<port>`,
  the URL, `Endpoint tunnel connected`, then a health-check line.
  `pw workflows runs errors <slug> -o text` lists the failures.
- The job dir is `~/pw/jobs/<slug>/` **on the workspace exec node** (rendered
  `pvc.yaml`, `app.yaml`, `OUTPUTS`, the `pod.running`/`app.deleted` markers); nothing
  exists on a cluster node.
- From your machine: `kubectl --context pw#<cluster> -n <ns> get pods,pvc,secret` and
  `… get events --sort-by=.lastTimestamp`. **Scheduling failures appear only in the
  events**: over quota, the ReplicaSet logs `FailedCreate … exceeded quota: pw-quota`
  while the run log shows only the 600 s `kubectl wait` timeout and
  `ProgressDeadlineExceeded`; the job errors, `early-cancel: any-job-failed` cancels
  the wait job, and the cleanups still run.
- A hybrid job without the job-level `if` runs on the workspace on k8s: an
  `ssh.remoteHost` that renders empty logs `[pw] ssh.remoteHost is empty; running this
  step on localhost` and proceeds (jupyterlab's `preprocessing` cloned canary for
  nothing until 2026-09-16).

## 7. Cluster facts (k3sgpu, 2026-09-16)

- One untainted control-plane node, `gpu.parallel.works`: 20 CPU, 64 GiB, 2 GPUs (A30 +
  RTX 3050, `nvidia.com/gpu: 2`). CPU-only pods schedule without tolerations.
- Default StorageClass `local-path` (`WaitForFirstConsumer`); RuntimeClasses include
  `nvidia` — attach `runtimeClassName: nvidia` only when GPUs are requested.
- Namespaces carry a `pw-quota` ResourceQuota. `alvarok8s`: cpu 4, memory 10Gi,
  nvidia.com/gpu 2 (other users' namespaces allow 100 CPUs). Requests add up per pod
  (init containers do not), the sidecar's 50m counts, and every container must declare
  requests. `ollama-openwebui`'s defaults (2 + 1 CPU) fit exactly.
- Image pulls: jupyter datascience ≈2 GB, ollama ≈3.7 GB, kasmweb ≈1.5 GB, code-server
  ≈0.4 GB; a first pull adds up to a minute, then it is cached on the node.

## 8. Run evidence (2026-09-16, k3sgpu, namespace `alvarok8s`)

| YAML | before conversion | after conversion (runner rows) |
|---|---|---|
| jupyterlab, kasmvnc, openvscode `general_k8s.yaml` | pass (`settling-aphid`, `wanted-kitten`, `merry-python`) | pass (`skilled-starling`, `strong-flea`, `full-tomcat`) |
| jupyterlab, kasmvnc, openvscode, mlflow `k8s.yaml` | pass (two runs each) | pass (`special-lacewing`, `light-seal`, `dear-mongoose`, `neat-lemming`) |
| ollama-openwebui `k8s.yaml` | quota fail (`dynamic-penguin`), pass alone (`useful-leopard`) | quota fail from the sidecar's extra 50m (`picked-tapir`), pass after the 1-CPU default (`pleasant-puma`) |

Pass = `wait_for_endpoint_k8s` completed (endpoint in `pw endpoints list`, its health
step saw the service answer), run still `running`; then cancel → Deployment, Secret,
PVC and endpoint gone within 35 s. (Rows before 2026-09-21 recorded the runner's own
anonymous curl, which only ever saw the `307` login redirect.)

## 9. Gotchas (each bit a real run)

- Quota failures are silent in the run log (§6); run tests one at a time.
- The sidecar shifts a pod's requests by 50m: a form default that just fit a quota
  stops fitting (ollama-openwebui).
- A readiness step that waits for one of two Deployments hangs when the other cannot
  schedule; wait for all of them.
- Guard cluster-only jobs at the job level, not the step level (§6).
- `runtimeClassName: nvidia` attached unconditionally works on k3sgpu but is wrong for
  CPU pods; make it conditional on the GPU limits.
- kasmweb serves TLS: `endpoints https`, and one `health check failed … not reachable
  yet` while it boots is normal.
- A backgrounded `kubectl logs -f … &` needs `$!`, not `$?`, for the pid it kills later.
- A `dropdown` without `default:` (`select_gpu`) renders empty from the form and turns
  `"" != "None"` into a bogus GPU limit; give it `default: None`.
- PVC steps need `if: ${{ inputs.k8s.volumes.pvc == New }}`, or an existing-PVC run
  creates a stray PVC.
