# End-to-end workflow tests

Every workflow is tested end-to-end at least once, and any end-to-end test is
recorded the same way. A test is one form submission: a JSON file containing the
input JSON payload that defines it, launched with `pw workflows run -i` against the
YAML of the same variant. Tests live next to the YAML they exercise and their
results accumulate in a CSV next to the test, one row per launch:

```
workflows/<name>/tests/<variant>/<test>.json   inputs for workflows/<name>/yamls/<variant>.yaml
workflows/<name>/tests/<variant>/<test>.csv    one row per launch (created on first run)
workflows/<name>/tests/<variant>/logs/<slug>.txt   `pw workflows runs errors` output of failed launches
```

Start from an existing test, e.g. `workflows/webshell/tests/<variant>/<test-name>.json`
(compute cluster) or `workflows/mlflow/tests/k8s/k3sgpu.json` (Kubernetes), and
change the `service` block. Commit the test and the rows the runner appends to
its CSV together with the workflow change; never edit a CSV by hand.

Run one or more tests (sequentially, so installs on the same resource never race):

```bash
python3 tools/tests/run-workflow-test.py workflows/jupyterlab/tests/general/gcp-controller.json \
                                         workflows/jupyterlab/tests/general/gcp-compute.json
```

`--emit` prints the launchable inputs (the `_test` object removed) for a manual
`pw workflows run`, `--keep` leaves the service running, `--timeout` overrides
the per-test timeout. `tests/` is never sparse-checked-out by a run.

## Lanes

The runner picks the lane from the inputs:

| lane | how it is recognised | pass | teardown |
|---|---|---|---|
| cluster | `cluster.resource` (or `resource`) is a resource name or `pw://` URI | the run reaches `completed`, an endpoint named `*-<run-slug>` is listed and its URL answers | `pw endpoints delete`; leftovers are checked over `pw ssh` |
| k8s | `resource` is an object with `"type": "kubernetes"` (hybrid `*_k8s.yaml`) or the inputs carry `k8s.cluster` (standalone `k8s.yaml`) | the run is still `running` when an endpoint named `*-<run-slug>` is listed and its URL answers | `pw workflows runs cancel`; leftovers are Kubernetes objects |

## The `_test` object

Optional, stripped before launch.

| key | lane | meaning | default |
|---|---|---|---|
| `timeout_s` | both | seconds to wait for the verdict | 1800 |
| `http_expect` | both | list of acceptable HTTP status codes from the endpoint URL | any 2xx or 3xx |
| `warm_marker` | cluster | path or list of paths on the resource; all exist → phase `warm`, none → `cold`, some → `partial` | none |
| `setup` | cluster | shell snippet run on the resource before launch; must be idempotent (seed files, create dirs) | none |
| `leftover_patterns` | cluster | process patterns that must not survive teardown, matched against `ps -u $USER -o args` | `["pw endpoints"]` |
| `leftover_commands` | cluster | `{name: shell snippet}`; each snippet must print `0` after teardown, e.g. `docker ps -q \| wc -l` for containers `ps` cannot see | none |
| `leftover_kinds` | k8s | object kinds that must be gone after teardown; drop `persistentvolumeclaims` for a test that sets `pvc_persist: true` | `deployments`, `services`, `pods`, `persistentvolumeclaims`, `secrets` |

## Pass criteria

Cluster lane:

- the run reaches `completed`
- `pw endpoints list` shows an endpoint named `*-<run-slug>`
- its URL answers with an accepted status (unauthenticated, so a login redirect counts)

Cleanup is verified separately after `pw endpoints delete`: no matching processes
for the user on the resource, no queued jobs when the test schedules, and the
endpoint gone. Failing runs keep their platform record; passing ones are not deleted yet.

## Kubernetes tests

On Kubernetes the run stays alive while the service serves and cancelling it is the
teardown (why, and everything else k8s: `.claude/skills/activate-workflows/references/k8s-workflows.md`), so the runner never calls
`pw endpoints delete` on this lane.

- **Inputs.** The platform wants a Kubernetes resource as an object. A hybrid test
  carries only its stable part, `"resource": {"name": "k3sgpu", "type": "kubernetes"}`,
  and the runner fills in `id` and `uri` from `pw kube ls`. A standalone test names
  the cluster in `k8s.cluster`. Both need `k8s.namespace`.
- **Skip rule.** The cluster must appear in `pw kube ls`; otherwise the test is skipped
  like an inactive compute resource.
- **Pass.** Within `timeout_s`, `pw endpoints list` shows `*-<run-slug>` while the run
  is still `running`, and the URL answers. A run that reaches a final status first
  fails with its `pw workflows runs errors` summary.
- **Teardown.** `pw workflows runs cancel`, then up to three minutes for: the run to
  reach `canceled`, no object of the `leftover_kinds` whose name contains the run slug
  left in `k8s.namespace` (every k8s YAML here names its objects after the run), and
  the endpoint gone. The check needs `kubectl` on this machine; the runner configures
  it with `pw kube auth --no-context-switch <cluster>` and uses the `pw#<cluster>`
  context. Without `kubectl` the cleanup column is `unknown`.
- **Failure log.** `logs/<slug>.txt` also gets the last 40 namespace events, where
  scheduling problems show up (k8s reference §6).
- **Versions.** Nothing is fetched from GitHub on this lane (the YAML is read locally
  and its manifests are inline), so the tree hashes are those of the local HEAD and
  `commit` is `-dirty` when the YAML has uncommitted changes.
- `--keep` leaves the run, and with it the service, running; cancel it yourself.
- `warm_marker` and `setup` need a login node and are ignored on this lane.

## CSV columns

| column | meaning |
|---|---|
| `date` | UTC launch time |
| `phase` | `cold`, `warm` or `partial` from `warm_marker`, empty when the test defines none (always empty on the k8s lane) |
| `result` | `pass` or `fail` |
| `cleanup` | `ok`, `leftover:<what>`, `unknown` (check failed), `kept` |
| `http` | status code from the endpoint URL |
| `workflow_tree`, `submitter_tree`, `tools_tree` | git tree hashes of `workflows/<name>`, `workflows/script_submitter/v3.6`, `tools` at the commit the run fetched (the branch named in the YAML; the local HEAD on the k8s lane). Same content → same hash, across squash merges |
| `commit` | local HEAD; `-dirty` when the local YAML differs from the fetched branch |
| `fetched` | the fetched commit; `?` when the fetch failed and local HEAD was used |
| `branch` | local branch |
| `user` | platform user who launched |
| `run_slug` | for `pw workflows runs view|logs|errors <slug>` |
| `duration_s` | launch to verdict, excluding teardown |
| `error` | one-line failure summary |

CSVs merge with `merge=union` (see `.gitattributes`): rows are independent, so
concurrent appends from two branches keep both sides.

`run-workflows-on-active-clusters.py` and `clean-software-dir-on-active-clusters.py`
predate this runner and target the old session pattern.
