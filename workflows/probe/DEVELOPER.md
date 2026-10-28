# PROBE developer guide

## Layout

```
app/probe/__main__.py       command line: run, serve, list, fetch-tests
app/probe/definitions.py    test definition files: validation, ids (from the fields, not the path), target
app/probe/pw.py             pw CLI wrapper, git checkout of workflow YAMLs
app/probe/runner.py         one run of the suite: gate, launch, poll, verdict, cleanup, record, upload
app/probe/results.py        results tree: one record.json per execution directory, state and history
app/probe/server.py         dashboard server: static web/ plus the JSON API
app/probe/tests_source.py   fetch the test definitions directory from its git repository (probe fetch-tests)
app/web/                    index.html, app.js, styles.css; theme.css, fonts.css and the two Geist fonts
                            vendored from @parallelworks/ui (no build step, no external assets)
app/setup.sh                the step both workflows share: form defaults, probe.env, test definitions,
                            results location (and the bucket restore for the dashboards)
app/credential.sh           the dashboards' credential check, before anything is submitted
app/start-dashboard.sh      the start script of one dashboard, submitted through script_submitter
app/run-tests.sh            one run of the tests named in selection.txt (general_run_tests.yaml)
selftest/                   offline unit tests with a mock pw CLI, browser check
scripts/import_workflow_tests.py  converts this repository's recorded tests into definitions
yamls/general.yaml          platform workflow: the two dashboards
yamls/general_run_tests.yaml  platform workflow: run all or selected tests once
tests/<variant>/            end-to-end tests of the two YAMLs (tools/tests/run-workflow-test.py)
thumbnails/probe.png
```

`app/` is the only subtree the workflows check out at run time, so everything the
runner and the dashboards need is below it and nothing else is. The test definitions
are not here: they live in a tests repository per platform
(`parallelworks/probe-tests-activate-parallel-works` for `activate.parallel.works`), together with the
GitHub actions that deploy these YAMLs.

No third-party Python packages. The code targets Python 3.8; cluster login nodes run
3.6 to 3.12 (gcpsmall has 3.9).

## Self-tests

```bash
cd workflows/probe
PYTHONPATH=app python3 -m unittest discover -s selftest -t .
```

No platform needed. `selftest/mockbin/pw` stands in for the CLI and follows a JSON
configuration (see its docstring); every test also gets a small local git repository
shaped like this one. Covered: definition validation, target derivation, every verdict
path (pass, skip, launch failure, run error, timeout, setup, a stuck endpoint, `--keep`,
the wait behind another test of the workflow),
selection by file, record and directory layout, bucket upload, the results reader
(regressions, running detection, malformed records) and the server API including path
safety and the read-only refusal of admin actions. Under two minutes.

### Browser check

`bash selftest/ui_check.sh` starts a local admin dashboard on the mock CLI with a
seeded results tree and drives every control in headless Chrome over the DevTools
protocol (`selftest/ui_check.js`): filters, search, theme, matrix chips, the drawer and
its tabs, artifact files, Refresh (bucket pull), Rerun test, Cancel run, Run all with
its second-click confirmation, and the refusal of an overlapping run. Needs Chrome and
Node 22 or newer. Destructive buttons ask for a second click instead of
`window.confirm`, which the platform blocks inside its session frame. With
`UI_SHOTS=<dir>` it also saves full-page screenshots of the page in light and dark and
of the drawer, to look at after a change to the look.

## The dashboard's look

The page looks like the platform because it is drawn on the platform's theme contract,
the way `.claude/skills/activate-workflows/references/app-ui.md` describes for any
workflow's own page:

- `app/web/theme.css` holds the `--theme-*` tokens of
  [`@parallelworks/ui`](https://github.com/parallelworks/foundation/tree/canary/packages/ui)
  (the default theme, light and dark as `light-dark()` pairs) and `fonts.css` the Geist
  faces; `bash tools/ui/sync-theme.sh workflows/probe/app/web` rewrites them from the
  version the header of `theme.css` names (`-v` moves to another) and is the only way
  to change them.
- `styles.css` reads nothing but those tokens, and each of its blocks names the
  component of the package it mirrors (the page header bar, `buttonClasses`, `fieldBox`,
  `StatusBadge` and its tones, `Table`, `Section`, `Tabs`, `Drawer`, `DescriptionList`,
  `Callout`), so a change there has one place to land here.
- The color mode is the platform's choice of three: light, dark, or the device's. The
  theme button cycles them; `data-theme` on the root, set before the first paint from
  `localStorage`, becomes the `color-scheme` the tokens follow.
- Icons are the package's glyphs (`src/icons.tsx`), drawn inline by `icon()` in
  `app.js` and in `index.html`, since the page's `<base>` would break `<use>` fragment
  references. A status reads as the platform draws a run's: pass as success, fail as
  error, running turning in the warning tone, skip and never run muted.
- `server.py` names the MIME types of the fonts, styles and script, whatever the login
  node's Python has in its table, and lets the fonts cache for a day.

Check a change with the browser check's screenshots (above) and, on the platform, by
fetching `theme.css` and a font through the endpoint with the API key, as the skill
reference's "Verify" section says.

## One test execution

`runner.TestRun.execute`, in order:

1. Resource gate: `pw cluster ls -o json` (or `pw kube ls`), fetched once per suite run.
   Off or unlisted: a `<start>_skip` directory with the record and the log.
2. Execution directory `<start>_pending`, renamed to `<start>_<slug>` after the launch
   or `<start>_launch-failed`.
3. Workflow YAML: one shallow `git fetch --depth 1` per `(repo, ref)` per suite run, the
   YAML materialised with sparse checkout. Its HEAD is `workflow.commit`.
4. Under a lock per `(resource, workflow_name)`, so two tests of one workflow never
   install into the same directory at once: the test's clock starts (`started_at`,
   `duration_s`; a wait for the lock is logged, not counted), then `warm_marker` check
   and `setup` snippet over `pw ssh`, then `pw workflows run --trust <local yaml> -i
   <inputs> --name "probe: <id>" -o json`, retried on transient errors. A failing setup
   fails the test at `launch`.
5. Poll `pw workflows runs view -o json` every 15 s until a final status, the timeout
   (`timeout_s` from the launch, then `pw workflows runs cancel`) or an interrupt.
6. Verdict: `completed` passes; anything else fails at `run` with the first error
   annotation of `pw workflows runs errors`. The workflow, not PROBE, checks that its
   service is healthy before it completes. This is why only workflows that run to
   completion are supported and the older session pattern (a `sessions:` block, a run
   that stays alive) is not.
7. Teardown: every endpoint named `*-<slug>` is deleted and waited for, up to a
   minute; `outcome.cleanup` records what became of them. A run that registered no
   endpoint has nothing to delete and a null `cleanup`. Nothing else is checked (below).
8. `record.json` is written into the execution directory (atomically), then the
   directory is uploaded to the bucket (`--bucket`). Each execution has its own
   directory, so uploads never overwrite another runner's results. A failed upload is
   reported and makes the runner exit 2.

The record is written on every path, including internal errors.

### Why a local copy of the YAML

The platform gives every inline run of one repository
(`pw workflows run <repo>/<path>@<ref>`) the same slug (`gh-parallelworks-workflows`,
then `-2`, `-3`), and two launches at the same moment fail with `Slug ... is already in
use`. A suite launches many tests of the same repository at once, so PROBE fetches the
repository at the ref and launches the YAML as a local file, which gets a slug of its
own. The YAML's own `parallelworks/checkout` and `uses:` references are untouched, so
the run is the same one, and the checkout's HEAD is the exact commit for the record.

### Why there is no leftover check

PROBE used to look for leftover processes after the teardown: `leftover_patterns`
matched against `ps -u $USER`, `leftover_commands` snippets and, for compute tests, an
empty `squeue`/`qstat`. The check could not tell the run's leftovers from anyone else's:
tests run in parallel on one cluster, so two tests of one workflow, or two workflows
serving the same program, matched each other's processes, and `squeue -u $USER` counted
every job of the user; a test without patterns was recorded as `cleanup ok` without any
check. A check that attributes what it finds to the run that made it needs a mark the
platform puts on everything a run starts, and only processes on the login node have
one: each step exports `PW_RUN_SLUG`, what the step starts inherits it unless it clears
its environment, and `/proc/<pid>/environ` shows it (verified on gcpsmall for a
detached process, a process inside a `screen` session and one inside an Apptainer
container; a Docker container takes its environment from the image). Scheduler jobs
have no such mark: SLURM records a job's working directory, script and submit line but
not the environment it was submitted from (`scontrol show job`, `sacct`,
`scontrol write batch_script`), PBS lists only `PBS_O_*` in `qstat -f` unless the job
was submitted with `-V`, and the only trace of the run is the job directory
`~/pw/jobs/<slug>` in those paths, which a workflow is free to leave before submitting.
Nor can PROBE mark the run itself: `pw workflows run` takes no environment, and
`pw endpoints list` reports no run for an endpoint. So a general check does not exist,
and rather than a partial one PROBE records only what its own teardown did.

### Concurrency

Tests run in a thread pool (`--workers`, default 8). Launches of the same workflow on
the same resource are serialised, and the wait counts neither in the waiting test's
`duration_s` nor against its `timeout_s`; everything else runs in parallel. `SIGINT`
and `SIGTERM` stop the suite: polling loops cancel their runs and record them as
failed; queued tests are not started.

## Results and the dashboard

`results.py` owns the conventions: execution directory `<start time without
colons>_<run slug>` (or `_skip`, `_launch-failed`) holding `record.json`, and the last
`HISTORY_LENGTH` records in the state. A test shows as running when an execution
directory has no `record.json` yet and its `run.log` changed in the last two hours.

`server.py` serves `web/` and this API, recognised by the `/api/` segment wherever the
endpoint prefix puts it:

| Route | Returns |
|---|---|
| `GET api/state` | every test (from records and definitions) with status, change, history, target; suite runs; definition errors |
| `GET api/tests/<id>/records` | all records of a test, oldest first |
| `GET api/tests/<id>/definition` | the definition file |
| `GET api/tests/<id>/artifacts` | execution directories and their files |
| `GET api/tests/<id>/artifacts/<dir>/<file>` | a file (last 4 MB) |
| `POST api/refresh` | re-fetches the test definitions from their repository (when the server was given one), then downloads the bucket into a staging directory and swaps it in as the local results copy, or merges it while a run started from this dashboard is in progress (both dashboards) |
| `POST api/delete` `{"id"}` | admin: removes every result of a test that has no definition, from the bucket and then locally; 400 with a definition, 409 while an execution is in progress |
| `POST api/run` `{"ids": [...]}` or `{"all": true}` | admin: starts `python3 -m probe run --bucket ...` in the background; 409 while an overlapping run is in progress |
| `POST api/cancel` `{"slug", "platform"}` | admin: `pw workflows runs cancel` |

Ids and file names are validated against `[A-Za-z0-9._-]` segments and resolved inside
the results directory. Without `--admin` every POST except `api/refresh` answers 403.
The runner the admin dashboard starts runs with `app/` as its working directory, which
is how it finds the `probe` package.

The dashboard is served at `/` behind a subdomain endpoint or under
`/me/session/<user>/<name>/` behind a path-based one. `index.html` builds a `<base>`
from its own location; the server takes the prefix from `--prefix` (`pw endpoints run`
passes `{path}`), `PW_ENDPOINT_PATH` or `X-Forwarded-Prefix`.

## The workflows

Both YAMLs are thin: their steps hand the form values to scripts under `app/` as
environment variables. `yamls/general.yaml` follows the endpoint pattern of the other
workflows here. `setup` checks out `workflows/probe/app` from this repository and runs
`app/setup.sh`, shared with `general_run_tests.yaml`: it applies the form's defaults (a
CLI run leaves an omitted input empty or `undefined`), fetches the test definitions
(`python3 -m probe fetch-tests`, which the dashboard's Refresh uses too), locates the
results and writes `probe.env` (`TESTS_*`, `RESULTS_DIR`, `RESULTS_BUCKET`, the `PW_*`
identity of the run) for the later steps and scripts. With `results.location` `bucket`,
also the default for a run launched without the input, the results are restored from
`<bucket>/<path>` into `results/` in the job directory when `RESTORE_RESULTS` is true,
which the dashboards ask for (a bucket path with no objects yet is fine; any other
failure stops the run); with `local`, `results.directory` on the host is created when
missing and read and written in place, with no bucket behind it. `app/credential.sh`
then decides the credential (below) and appends `PROBE_AUTH` to `probe.env`. For each
dashboard a runner job submits `app/start-dashboard.sh` through the `script_submitter`
subworkflow from `dashboard/` or `admin/`: the directory it runs in names the
dashboard, `../probe.env` holds the rest, and it runs `pw endpoints run --name
probe[-admin]-${PW_RUN_SLUG} -- python3 -m probe serve ... --results <dir>` plus
`--bucket <bucket>/<path>` when there is a bucket. A wait job calls the
`wait_for_endpoint` subworkflow, which waits until the endpoint is listed and its URL
answers, touches the skip-cleanups file and cancels the runner job. The run then
completes while the servers keep running; a runner that exits before its endpoint came
online fails the run. Runs started from the admin dashboard inherit the results
location: they write into the same directory and sync to the same bucket, if any.
`pw endpoints delete` tears a dashboard down.

**Credentials.** Every step of a run has `PW_API_KEY`, the run's token, and that token
is rejected as soon as the run completes (verified by testing a stored run token before
and after completion). The user workspace and a cluster the ACTIVATE agent connects
(`existing`, `managed-cluster`) are signed in as the user on their own; a cloud cluster's
node has no user context, and secret user variables are not readable from a run. The
dashboards outlive their run, so `general.yaml` runs them on a credential that does. The
`api_key` input is hidden and ignored on those hosts (`inputs.resource.provider` is
`existing` or `managed-cluster`, or `inputs.resource.name` is `user-workspace`) and
required on a cloud cluster; it travels in the top-level `env` block as `PROBE_API_KEY`,
which reaches every step, including the script that `script_submitter` launches
(`PW_API_KEY` itself cannot be overridden: the platform injects the run's token).
`app/credential.sh` decides before anything is submitted and records `PROBE_AUTH` in
`probe.env`: a key given must authenticate (`PW_API_KEY=<key> pw auth whoami`) and the
start script exports it as `PW_API_KEY`; without one the host's own sign-in must
(`env -u PW_API_KEY pw auth whoami`) and the start script does `unset PW_API_KEY` so it
takes over; neither working ends the run with an error. The start script reads
`${PROBE_API_KEY}` from its environment, so the key lives in the environment of
`pw endpoints run`, `probe serve` and the runners it spawns, and nowhere on disk.

Like every other input, the platform keeps it in the run's record (`pw workflows runs
view -o json` shows it in `inputs`, in plain text as of September 2026) and renders it
into the step's script under the job's `logs/` directory on the resource; deleting the
job directory removes that copy. The equivalent without an input is a credentials
directory on the resource authenticated once with `pw auth` and selected with
`PW_CREDENTIALS_DIR`, which the CLI honours the same way. `general_run_tests.yaml`
needs no key: its runner works while its run is alive.

`yamls/general_run_tests.yaml` has one job: checkout, `app/setup.sh` (without the
bucket restore), then `app/run-tests.sh`, which runs `python3 -m probe run --results
<dir> [--bucket <bucket>/<path>] --all` or `--test <file>` per line of the `selection`
input (written to `selection.txt` by the step). The runner exits 1 when a test failed
and 2 when it could not run or record the tests; the script reports the first as one
`::warning::` per failed test and exits 0, since the failures are recorded and on the
dashboard, and fails on the second. The GitHub action therefore fails only when the suite could not run.

The GitHub actions live in the tests repository: they install the `pw` CLI on the
runner, authenticate with the platform's repository secret through `PW_API_KEY`, write
`inputs.json`, check out this repository at a chosen ref and `pw workflows run --trust`
the YAML from it. The dashboard action passes the same secret as the dashboards' API
key. Both are manual (`workflow_dispatch`); a `schedule` trigger on the test action
would run the suite periodically.

Validate a change with `pw workflows run --trust --dry-run -i inputs.json
/abs/path/workflows/probe/yamls/<file>.yaml`. The YAML is read locally, but `app/` is
fetched from GitHub at run time: push the branch and point both YAMLs' checkout
`branch:` at it while developing, and restore `canary` before the change merges.
`setup.sh` and `credential.sh` also run on a laptop from a directory holding a copy of
`workflows/probe/app`, with the form values as environment variables, which is the
quickest check of a change to them.

## End-to-end tests of PROBE itself

`tests/general/gcpsmall.json` starts the dashboards on `pw://alvaro/gcpsmall`
(`tests/general/gcptest.json` the same on `pw://alvaro/gcptest`) and
`tests/general_run_tests/gcpsmall.json` runs one PROBE test (the `script_submitter`
canary) through `general_run_tests.yaml`; all of them read and write the production
results bucket. The `gcpsmall-local.json` test beside each does the same with the
results in `${HOME}/pw/probe/results` on gcpsmall (`results.location: local`). The
dashboards tests take their API key from the environment at launch (`_test.secrets`:
`PROBE_API_KEY`), so the key is never in the test file. `tests/general/labcluster.json`,
`a30gpuserver.json` and `workspace.json` start the dashboards without a key on a managed
cluster, an existing cluster (the same machine, two resource types) and the user
workspace, with the results on the host; on a cloud cluster the form refuses a launch
without a key, and `gcpsmall-bad-key.json` is the dashboards' failure path: a key that
does not authenticate ends the run at setup.

```bash
PROBE_API_KEY=<key> python3 tools/tests/run-workflow-test.py workflows/probe/tests/general/gcpsmall.json
python3 tools/tests/run-workflow-test.py workflows/probe/tests/general_run_tests/gcpsmall.json
```

## Test definitions

The format is in [README.md](README.md); adding, changing and running tests is described in
the tests repository's README. `scripts/import_workflow_tests.py` converts the tests recorded
under `workflows/<name>/tests/<variant>/` here (their `_test` object maps to `timeout_s`,
`warm_marker` and `setup`; `leftover_patterns` and `leftover_commands` belong to that
runner's own check and are dropped; tests with other `_test` keys are reported and
skipped). A `script_submitter` test needs `define_cleanup_script: false` in its inputs or
the platform rejects the launch.
