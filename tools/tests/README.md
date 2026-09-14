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

Start from an existing test, e.g. `workflows/webshell/tests/<variant>/<test-name>.json`,
and change the `service` block. Commit the test and the rows the runner appends to
its CSV together with the workflow change; never edit a CSV by hand.

Run one or more tests (sequentially, so installs on the same resource never race):

```bash
python3 tools/tests/run-workflow-test.py workflows/jupyterlab/tests/general/gcp-controller.json \
                                         workflows/jupyterlab/tests/general/gcp-compute.json
```

`--emit` prints the launchable inputs (the `_test` object removed) for a manual
`pw workflows run`, `--keep` leaves the service running, `--timeout` overrides
the per-test timeout. `tests/` is never sparse-checked-out by a run.

## The `_test` object

Optional, stripped before launch.

| key | meaning | default |
|---|---|---|
| `timeout_s` | seconds to wait for the run to reach a final status | 1800 |
| `http_expect` | list of acceptable HTTP status codes from the endpoint URL | any 2xx or 3xx |
| `warm_marker` | path or list of paths on the resource; all exist → phase `warm`, none → `cold`, some → `partial` | none |
| `setup` | shell snippet run on the resource before launch; must be idempotent (seed files, create dirs) | none |
| `leftover_patterns` | process patterns that must not survive teardown, matched against `ps -u $USER -o args` | `["pw endpoints"]` |
| `leftover_commands` | `{name: shell snippet}`; each snippet must print `0` after teardown, e.g. `docker ps -q \| wc -l` for containers `ps` cannot see | none |

## Pass criteria

- the run reaches `completed`
- `pw endpoints list` shows an endpoint named `*-<run-slug>`
- its URL answers with an accepted status (unauthenticated, so a login redirect counts)

Cleanup is verified separately after `pw endpoints delete`: no matching processes
for the user on the resource, no queued jobs when the test schedules, and the
endpoint gone. Failing runs keep their platform record; passing ones are not deleted yet.

## CSV columns

| column | meaning |
|---|---|
| `date` | UTC launch time |
| `phase` | `cold`, `warm` or `partial` from `warm_marker`, empty when the test defines none |
| `result` | `pass` or `fail` |
| `cleanup` | `ok`, `leftover:<what>`, `unknown` (check failed), `kept` |
| `http` | status code from the endpoint URL |
| `workflow_tree`, `submitter_tree`, `tools_tree` | git tree hashes of `workflows/<name>`, `workflows/script_submitter/v3.6`, `tools` at the commit the run fetched (the branch named in the YAML). Same content → same hash, across squash merges |
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
