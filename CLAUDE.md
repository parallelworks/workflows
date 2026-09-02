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
tools/oras, tools/utils      # shared runtime tools, referenced as tools/... from run dirs
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

Every workflow here uses it: preprocessing checks out this repo
(`parallelworks/checkout`, sparse `workflows/<name>/app` — or an impl subdir —
[+ `tools/...`]), assembles
`inputs.sh` + `controller.sh` + `start-template.sh`, submits through
`workflows/script_submitter/v3.6/<variant>.yaml`, and waits for a **`pw` endpoint**
(`pw endpoints list`) named `<service>-${PW_RUN_SLUG}`. No `sessions:` block.

To convert a legacy session-pattern workflow to this pattern, follow
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`
(what is legacy and where it lives: MIGRATION.md).

## Critical rules and conventions

### Scripts
- Scripts MUST be **idempotent** — safe to re-run (check before installing).
- The service MUST listen on `${service_port}` (allocated at runtime).
- Scripts MUST create `cancel.sh` for graceful shutdown.
- The start script MUST end with `sleep inf` (or run the service in the foreground).
- All configuration arrives via the sourced `inputs.sh` — no hardcoded paths/values.
- Use `${PW_PARENT_JOB_DIR}` for job-dir references and `service_parent_install_dir`
  (default `${HOME}/pw/software`) for installs.
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
- The hidden `service.name` input is the **endpoint/session name prefix** — it is not
  a checkout path. Keep its value stable; renaming it changes endpoint names.
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

- **Push before testing.** Checkout and `uses:` steps fetch this repo from GitHub at
  run time; local edits are invisible until they are on the referenced branch.
- Run with the **absolute** YAML path (a relative path is parsed as a git host):
  `pw workflows run /abs/path/workflows/<name>/yamls/general.yaml -i '{"cluster":{"resource":"<cluster>","scheduler":false}}'`
- **Pass = the endpoint serves:** `pw endpoints list` shows `<service.name>-<run-slug>`
  and its URL answers. The run completes while the service keeps running.
- **Tear down:** `pw endpoints delete <name>` kills the remote process tree; verify
  with `ps -x` (daemonizing apps that re-parent to PID 1 can survive).
- **Debug from the job dir** on the execution node — `~/pw/jobs/<run-slug>/` for
  CLI file runs, `~/pw/jobs/<workflow-name>/<run-number, 5 digits>/` for registered
  workflows:
  `run.<JOBID>.out` is the service output; `logs/<job>/step_N/step.out` the step
  trace; `logs/<job>/step_N/script-unstable.sh` is the **rendered** step showing every
  `${{ input }}` as its literal value — read it first when a form value seems ignored.
  From anywhere: `pw workflows runs errors <slug>`.
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
