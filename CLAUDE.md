# CLAUDE.md — Parallel Works Workflows Repository

## Project Overview

This repository is the home of the **ACTIVATE platform workflows** (interactive
sessions, model servers, k8s services) for [Parallel Works](https://parallelworks.com):
**one workflow = one self-contained directory** under `workflows/`. Provenance and
anything predating this layout: MIGRATION.md.

A typical workflow consists of:
- **Variant YAMLs** (`workflows/<name>/yamls/<variant>.yaml`) — the UI form + job
  orchestration, one file per platform variant (`general`, `emed`, `hsp`, `noaa`, `*k8s*`)
- A **controller script** (`controller.sh`) — runs on the login node, idempotent
  install/setup with internet access
- A **start script** (`start-template.sh`) — runs on the compute or login node,
  launches the service
- Support files (conda env YAMLs, container defs, helper scripts), `README.md`, and
  marketplace thumbnails in `thumbnails/`

## Official platform documentation (authoritative — consult when in doubt)

- Building workflows: <https://parallelworks.com/docs/run/workflows/building-workflows>
  — with the [YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields),
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions),
  and [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions) subpages
- Endpoint sessions: <https://parallelworks.com/docs/run/sessions/endpoints>
- `pw endpoints` CLI: <https://parallelworks.com/docs/cli/pw/endpoints> (full CLI: <https://parallelworks.com/docs/cli>)

## Repository structure

```
workflows/<name>/yamls/      # the workflow's variant YAMLs (general.yaml, hsp.yaml, k8s.yaml, ...)
workflows/<name>/app/        # runtime files: scripts + support files — the ONLY subtree
                             # the workflow sparse-checkouts at run time
workflows/<name>/<impl>/     # multi-implementation workflows use impl subdirs instead of app/,
                             # named after the form input values (n8n-docker, n8n-singularity,
                             # kasmvnc-singularity, ollama-gguf-container, librechat-singularity, ...)
workflows/<name>/            # README + build tooling (defs, build-container.sh)
workflows/<name>/thumbnails/ # marketplace thumbnails (one per registered variant look)
workflows/script_submitter/v3.6/  # shared subworkflow: SLURM/PBS/SSH script submission
workflows/wait_for_endpoint/      # shared subworkflow: wait for the endpoint, probe its URL, release the submitter
tools/oras, tools/utils      # shared runtime tools, referenced as tools/... from run dirs
workflows/<name>/tests/<variant>/  # end-to-end tests: <test>.json form inputs + <test>.csv results
tools/tests/                 # the test runner (run-workflow-test.py) and its README
tutorials/                   # staged, runnable lessons on the workflow system
docs/                        # developer + AI docs
.claude/skills/activate-workflows/  # Claude Code skill for building workflows here
```

## Versioning

- **One version only — the latest.** No version suffixes in filenames or references:
  `general.yaml`, `controller.sh`, `start-template.sh`. Git tags version the repo.
  (Where older versions live: MIGRATION.md.)
- `script_submitter` keeps its explicit version directory (`v3.6`) because platform
  marketplace registrations reference that path.

## The endpoint pattern

Every workflow here serves through a **`pw` endpoint** (`pw endpoints list`) named
`<service>-${PW_RUN_SLUG}`. On a compute cluster,
preprocessing checks out this repo (`parallelworks/checkout`, sparse
`workflows/<name>/app` — or an impl subdir — [+ `tools/...`]), assembles
`inputs.sh` + `controller.sh` + `start-template.sh`, submits through
`workflows/script_submitter/v3.6/<variant>.yaml`, and a `wait_for_endpoint` job calls
the `wait_for_endpoint` subworkflow (`workflows/wait_for_endpoint/`): it waits until
the endpoint is listed, **probes its URL until the service answers**, then touches the
`SKIP_CLEANUP` file; the job cancels the submitter and the run completes while the
service outlives it. **The workflow is responsible for checking that the endpoint is
healthy before it exits.** The probe carries the run's `PW_API_KEY` (an anonymous
request only sees the platform's `307` login redirect; with the key the service's own
status comes back, `503` while nothing listens behind the tunnel yet). If the service
never answers within the budget the wait job fails without touching the skip file, so
the submitter's cleanup tears the job down and the run ends in error. Which HTTP codes
count as healthy and how long to retry are set per workflow through the call's inputs.

**Kubernetes** (`yamls/k8s.yaml` = k8s-only example, `yamls/general_k8s.yaml` = hybrid):
the same endpoint, registered by a `pw-cli` sidecar inside the pod; the run stays alive
and **cancelling the run is the teardown**. Everything else Kubernetes — anatomy, dev
loop, inputs, tests, debugging, cluster facts — is in one place:
`.claude/skills/activate-workflows/references/k8s-workflows.md`.

To convert an older workflow to this pattern, follow
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`
(which workflows those are and where they live: MIGRATION.md).

## Critical rules and conventions

### Scripts
- Scripts MUST be **idempotent** — safe to re-run (check before installing).
- The service MUST listen on `${service_port}` (allocated at runtime).
- Scripts MUST create `cancel.sh` for graceful shutdown.
- The start script MUST end with `sleep inf` (or run the service in the foreground).
- All configuration arrives via the sourced `inputs.sh` — no hardcoded paths/values.
- Use `${PW_PARENT_JOB_DIR}` for job-dir references in scripts and `run:` steps, and
  `service_parent_install_dir` (default `${HOME}/pw/software`) for installs. Keys the
  platform resolves itself take shell variables literally: a job's `working-directory`,
  and a `with:` value that becomes one (the submitter's `rundir`), must use
  `${{ env.PW_PARENT_JOB_DIR }}` instead.
- Shared tools are referenced as `tools/oras/...` / `tools/utils/...` relative to the
  run directory (the YAML sparse-checkouts them alongside `workflows/<name>`).
- Pull ghcr/ORAS artifacts through `tools/oras/libs.sh:oras_pull_file` (it retries —
  ghcr intermittently rate-limits anonymous pulls) and keep the packages **public**;
  verify anonymous access before shipping.

### Workflow YAMLs
- **The repo is fetched from GitHub at runtime**: `parallelworks/checkout` steps pull
  `https://github.com/parallelworks/workflows.git` (branch **canary**) and subworkflow
  steps use `uses: github/parallelworks/workflows@canary` with
  `$yaml: workflows/script_submitter/v3.6/<variant>.yaml`.
  Changes only take effect once pushed to that branch.
- Checked-out paths are repo-relative: scripts materialize at
  `<rundir>/workflows/<name>/app/...` (or `.../<impl>/...`) — reference them with
  that full prefix, including paths composed from variables.
- Form inputs are grouped as `cluster` (resource/scheduler) and `service`
  (service-specific); values read as `${{ inputs.cluster.* }}` / `${{ inputs.service.* }}`.
- The hidden `service.name` input is the **endpoint name prefix** — it is not
  a checkout path. Keep its value stable; renaming it changes endpoint names.
- Endpoint names must be lowercase `[a-z0-9-]`. `<service.name>-${PW_RUN_SLUG}` already
  is; a name that comes from a form input must be folded before it reaches
  `pw endpoints` — see the `endpoint_name` input in `workflows/ollama/yamls/general.yaml`.
- The `wait_for_endpoint` job is two steps: the `wait_for_endpoint` subworkflow
  (`uses: github/parallelworks/workflows@canary`,
  `$yaml: workflows/wait_for_endpoint/general.yaml`, with `early-cancel: any-job-failed`)
  and `parallelworks/cancel-jobs` on the submitter. Pass `endpoint_name`, `host` (the
  login-node IP) and `skip_cleanups_file`; set `healthy`, `budget` and `path` per service
  (inputs and how to choose them: `workflows/wait_for_endpoint/README.md`). On Kubernetes
  keep the `pod.running` marker step first and omit `host` and `skip_cleanups_file`.
- Multi-implementation workflows select their script subdir via a runtime input
  (`container_runtime`, `service.container_runtime`, `service.name`): the input
  **values must match the impl subdirectory names** under `workflows/<name>/`.
- Support both SLURM and PBS (`scheduler: true` submits; `false` runs on the login node).

### Comments
- Default to no comments. Only add one when the WHY is non-obvious: a hidden
  constraint, a subtle invariant, a workaround for a specific bug. No WHAT comments.

## No build system

No build system or linter. Deployment happens by the ACTIVATE platform cloning this
repo and executing scripts directly. `emed`/`hsp`/`noaa` variants can only run from
those platforms — validate them statically.

## Testing and debugging

- **Test every new or changed workflow end-to-end at least once and record the test in
  the repo.** Tests live under `workflows/<name>/tests/<variant>/` and run with
  `python3 tools/tests/run-workflow-test.py <test.json>`. The layout, keys, pass
  criteria and result columns are documented once, in `tools/tests/README.md`. Commit
  the test and the rows the runner appends with the change; never edit a CSV by hand.
- **Push before testing** anything the run fetches (`app/` scripts, subworkflows):
  checkout and `uses:` steps pull this repo from GitHub at run time. The YAML itself
  is read from the absolute path you pass, so a YAML-only edit tests without a push.
- Run with the **absolute** YAML path (a relative path is parsed as a git host):
  `pw workflows run /abs/path/workflows/<name>/yamls/general.yaml -i '{"cluster":{"resource":"<cluster>","scheduler":false}}'`
- **Pass = the run completes and `pw endpoints list` shows `<service.name>-<run-slug>`.**
  The run only completes after the workflow's own health check saw the URL answer, so
  the runner does not probe URLs. The service keeps running after the run completes.
- **Tear down:** `pw endpoints delete <name>` kills the remote process tree; verify
  with `ps -x` (daemonizing apps that re-parent to PID 1 can survive).
- **Kubernetes runs differ:** pass = the `wait_for_endpoint_k8s` job completes (endpoint
  listed, URL answering) while the run is still `running`; teardown =
  `pw workflows runs cancel <slug>`. The runner's k8s lane
  does both (tests under `tests/k8s/` and `tests/general_k8s/`); details in
  `.claude/skills/activate-workflows/references/k8s-workflows.md` §4–§6.
- **Verify cancel cleanup when developing a workflow:** cancel a run mid-flight
  (`pw workflows runs cancel <slug>`) and confirm `cancel.sh` ran — no leftover
  processes (`ps -x`), scheduler jobs (`squeue`/`qstat`), or container instances
  (`singularity instance list`, `docker ps`). Write `cancel.sh` first thing in the
  start script so a cancel at any moment finds it.
- **Debug from the job dir** on the execution node — `~/pw/jobs/<run-slug>/` for
  CLI file runs, `~/pw/jobs/<workflow-name>/<run-number, 5 digits>/` for registered
  workflows:
  `run.<JOBID>.out` is the service output; `logs/<job>/step_N/step.out` the step
  trace; `logs/<job>/step_N/script-unstable.sh` is the **rendered** step showing every
  `${{ input }}` as its literal value — read it first when a form value seems ignored.
  From anywhere: `pw workflows runs errors <slug>`. Kubernetes runs have no job dir on
  a cluster node — debug them per `.claude/skills/activate-workflows/references/k8s-workflows.md` §6.
- `pw` auth tokens expire; "Authentication has expired" means a human must run `pw auth`.
- Registered ("remote") workflows pin one YAML path (`pw workflows get <name>` →
  `remote.yaml`); the form and its defaults come from that file — point registrations
  at `workflows/<name>/yamls/<variant>.yaml` and `workflows/<name>/thumbnails/…`.

## Git and deployment

- Primary branch: **canary** (`git@github.com:parallelworks/workflows.git`) — the
  branch the YAMLs reference at runtime. Branch rules require changes to land **via
  pull request**; work on a side branch and merge (squash) into canary.
- Large binaries stay out of this repo. A few controllers fetch prebuilt binaries
  from an external `legacy` git tag at run time — leave those clone blocks alone
  (background: MIGRATION.md).
- Marketplace registrations pin repo paths; renaming a path here without re-pointing
  the registration breaks the entry (registration notes: MIGRATION.md).
