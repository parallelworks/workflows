# PROBE

PROBE checks that workflows still work on the systems connected to an ACTIVATE platform. A
test launches a workflow YAML from a git repository with fixed inputs on one system; PROBE
waits for the run to end, deletes the endpoint the run registered and records the result.
Repeated over time, the records show when a workflow stops working on a system.

```
  test definitions (a git repository per platform)   tests/<platform>/<user>/<workflow_name>/<name>.json
          |
          v
  runner   python3 -m probe run  --pw workflows run-->  the workflow runs on the target system
          |                                             pass = the run completes
          v
  results bucket (ground truth)      <bucket>/<path>/<platform>/<user>/<workflow_name>/<name>/<start>_<run slug>/
          |
          v
  dashboards   python3 -m probe serve         matrix of workflows by system, history, logs
```

The definitions for `activate.parallel.works` are in
[probe-tests-activate-parallel-works](https://github.com/parallelworks/probe-tests-activate-parallel-works);
its README says how to add, change and run them. This directory holds the code (`app/`,
checked out at run time like every other workflow here) and two workflows:

| Workflow | What it does |
|---|---|
| `yamls/general.yaml` | Starts the two dashboards. The run completes once both endpoints answer; the dashboards keep serving until their endpoints are deleted. |
| `yamls/general_run_tests.yaml` | Runs all tests, or the files named in `selection`, once. Ends in error when a test fails. No endpoint. |

Both take the test definitions (repository, branch, directory) and the results bucket and
path as inputs. `general.yaml` also takes:

| Input | Meaning |
|---|---|
| Where to run | The user workspace or a cluster login node with the `pw` CLI, `python3` and `git`. Tests started from the admin dashboard are launched from here. |
| API key | A platform API key of yours. The run's own credential stops working when the run completes, so the dashboards use this key afterwards. |

## Dashboards

- `probe-<run slug>`: read-only, safe to share.
- `probe-admin-<run slug>`: also `Run all`, `Rerun test`, `Cancel run`, and `Delete results`
  for a test whose definition is gone.

`Refresh` re-fetches the test definitions from their repository and replaces the dashboard's
results with the bucket's content. `pw endpoints list` shows the URLs;
`pw endpoints delete <name>` stops a dashboard.

## Running tests

From the admin dashboard, a test shows as running until its record is written; a request
that overlaps a run in progress is refused. Up to 8 tests run at the same time
(`--workers`); two tests of the same workflow on the same system never overlap. Only tests
whose `platform` and `user` match the runner's own are run: the `pw` context selects them,
`PW_PLATFORM_HOST` and `PW_USER` override it.

From a shell, with the test definitions checked out at `../tests`:

```bash
cd workflows/probe/app
python3 -m probe list --tests ../tests                                    # validate the definitions
python3 -m probe run  --tests ../tests --results results --bucket pw://alvaro/gcpbucket/probe/results --all
python3 -m probe run  --tests ../tests --results results --bucket pw://alvaro/gcpbucket/probe/results \
    --test activate.parallel.works/alvaro/webshell/gcp-controller.json  # or --filter, --id
python3 -m probe run  --tests ../tests --results results --dry-run        # list what would run
python3 -m probe serve --results results --tests ../tests --port 8080 [--admin] [--bucket URI]
```

Exit codes: 0 every test passed or was skipped, 1 a test failed, 2 an invalid definition, a
bad selection or a failed upload. `--keep` leaves the endpoints running; without `--bucket`
the results stay local. Interrupting the runner cancels its platform runs and records them
as failed.

## Test definition

One JSON file per test. The id `<platform>/<user>/<workflow_name>/<name>` comes from the
fields; `<platform>/<user>/<workflow_name>/<name>.json` is the recommended location and
`probe list` notes files found elsewhere. Two files with the same id, or an unknown key, are
errors.

```json
{
  "name": "gcp-controller",
  "platform": "activate.parallel.works",
  "user": "alvaro",
  "workflow_name": "webshell",
  "workflow": {
    "repo": "github.com/parallelworks/workflows",
    "path": "workflows/webshell/yamls/general.yaml",
    "ref": "canary"
  },
  "timeout_s": 1200,
  "warm_marker": "${HOME}/pw/software/noVNC-1.3.0/ttyd.x86_64",
  "leftover_patterns": ["ttyd", "pw endpoints run"],
  "inputs": {
    "cluster": { "resource": "pw://alvaro/gcpsmall", "scheduler": false },
    "service": {}
  }
}
```

| Field | Meaning |
|---|---|
| `name` | Test name, unique within its platform, user and workflow. |
| `platform`, `user` | Platform host and user that run the test. |
| `workflow_name` | Groups the tests of one workflow, for example its directory name. |
| `workflow.repo`, `.path`, `.ref` | Any git repository the runner can fetch (GitHub, GitLab, ...): host and path, or a git URL; path of the workflow YAML in it; branch, tag or commit. A branch follows development; a tag or commit pins a release. |
| `timeout_s` | Seconds to wait for the run, default 1800. On timeout the run is canceled and the test fails. |
| `inputs` | Passed verbatim to `pw workflows run -i`. The target system comes from `resource` or `cluster.resource`; `scheduler: true` marks a compute-node test. |
| `warm_marker` | Optional. Path, or list of paths, on the target system. All present before launch: phase `warm`; none: `cold`; some: `partial`. |
| `leftover_patterns` | Optional. Process command-line patterns that must be gone from the target system after cleanup; compute tests also require an empty scheduler queue. Processes that existed before the launch are ignored. |
| `leftover_commands` | Optional. `{name: shell snippet}`; each snippet runs on the target after cleanup and must print `0`, for example `docker ps -q \| wc -l` for containers `ps` cannot see. |
| `setup` | Optional. Shell snippet run on the target before the launch, for example to seed input files. Must be safe to repeat. |

```
  gate      pw cluster ls (or pw kube ls): resource off or not listed  -->  skip
  launch    pw workflows run <YAML at ref> -i inputs                    -->  fail at launch
  wait      pw workflows runs view every 15 s until the run ends        -->  fail at run (error, timeout)
  verdict   run completed                                               -->  pass
  cleanup   pw endpoints delete *-<run slug>; leftover check            -->  cleanup ok | leftover | unknown
  record    record.json + logs written, uploaded to the bucket
```

The workflow is responsible for failing its run when its service is not healthy and
completing once it is; PROBE trusts the run status. A workflow whose run stays alive to serve
(the older `sessions:` pattern) cannot be tested: its run never completes. The tests recorded
under `workflows/<name>/tests/<variant>/` in this repository convert into definitions with
`scripts/import_workflow_tests.py`.

## Results

```
<bucket>/<path>/<platform>/<user>/<workflow_name>/<name>/
|-- 2026-09-21T150902Z_swift-falcon/      one directory per execution: <start time>_<run slug>
|   |-- record.json                       the record (below)
|   |-- run.log                           what PROBE did and saw, with timestamps
|   |-- launch.json                       the run object returned by pw workflows run
|   |-- view.json                         the last pw workflows runs view of the run
|   `-- errors.txt                        pw workflows runs errors, failed runs only
|-- 2026-09-21T150902Z_skip/              a skipped execution: record.json and run.log
`-- 2026-09-21T150902Z_launch-failed/     a launch that produced no run
```

The current state of a test is the record of its newest execution; the history is all of
them. Every execution writes only its own directory, so runners started anywhere share one
bucket without overwriting each other. A directory without `record.json` is an execution
still in progress. To reclaim space, delete the large files of old executions but keep
`record.json`.

```json
{
  "schema": 1,
  "suite_run": "probe-2026-09-21T15:09Z",
  "pw_cli": "v7.99.0",
  "test": {"id": "activate.parallel.works/alvaro/webshell/gcpsmall-compute", "workflow_name": "webshell"},
  "workflow": {"repo": "github.com/parallelworks/workflows", "path": "workflows/webshell/yamls/general.yaml",
               "ref": "canary", "commit": "031eb00c31c1af10de5868c78865e3000004e583"},
  "target": {"platform": "activate.parallel.works", "user": "alvaro", "system": "gcpsmall",
             "resource": "pw://alvaro/gcpsmall", "type": "cluster", "node": "compute"},
  "outcome": {"status": "pass", "failed_at": null, "error": null, "phase": "warm",
              "cleanup": "ok", "run_slug": "swift-falcon", "endpoint": "webshell-swift-falcon",
              "started_at": "2026-09-21T15:09:02Z", "ended_at": "2026-09-21T15:13:09Z", "duration_s": 247}
}
```

| Field | Values |
|---|---|
| `suite_run` | Label of the run of the suite this execution belonged to. |
| `workflow.commit` | Commit `ref` resolved to at launch. |
| `target.type`, `target.node` | `cluster` or `kubernetes`; `controller` or `compute` (null on Kubernetes). |
| `outcome.status` | `pass`, `fail`, `skip`. |
| `outcome.failed_at` | `launch`, `run`, or null. |
| `outcome.error` | One line; the skip reason for skipped tests. Details are in `run.log` and `errors.txt`. |
| `outcome.phase` | `cold`, `warm`, `partial`, or null without `warm_marker`. |
| `outcome.cleanup` | `ok`, `leftover`, `unknown` (the check could not run), `kept` (`--keep`). Independent of `status`. |
| `outcome.run_slug` | Platform handle: `pw workflows runs view <slug>`. |
| `outcome.endpoint` | Endpoint names deleted after the verdict, comma separated; null when the run registered none. |
| `outcome.duration_s` | Test start to verdict, excluding cleanup. |

Every key is always present; not applicable or unknown is null. A `pass` followed by a `fail`
for the same test, ignoring skips in between, is a regression; the dashboard marks it.

## Development

[DEVELOPER.md](DEVELOPER.md): code layout, self-tests, design decisions.
