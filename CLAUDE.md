# CLAUDE.md — Parallel Works Workflows Repository

## Project Overview

This repository is the consolidated home of the **ACTIVATE platform workflows**
(interactive sessions, model servers, k8s services) for [Parallel Works](https://parallelworks.com).
It replaces the split layouts of the old `interactive_session` and `activate-rag-vllm`
repos: **one workflow = one self-contained directory** under `workflows/`.

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
workflows/<name>/            # scripts + support files + README
workflows/<name>/thumbnails/ # marketplace thumbnails (one per registered variant look)
workflows/<name>/<impl>/     # multi-implementation workflows keep impl subdirs whose names
                             # match the form input values (n8n-docker, n8n-singularity,
                             # kasmvnc-singularity, ollama-gguf-container, librechat-singularity, ...)
workflows/script_submitter/v3.6/  # shared subworkflow: SLURM/PBS/SSH script submission
tools/oras, tools/utils      # shared runtime tools, referenced as tools/... from run dirs
tutorials/                   # staged, runnable lessons on the workflow system
docs/                        # developer + AI docs
.claude/skills/activate-workflows/  # Claude Code skill for building workflows here
```

## Versioning

- **One version only — the latest.** No version suffixes in filenames or references:
  `general.yaml`, `controller.sh`, `start-template.sh`. Git tags version the repo.
- Legacy-generation variants that required older scripts were **not migrated**; they
  live in `parallelworks/interactive_session` until converted to the endpoint pattern
  (see MIGRATION.md and
  `.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`).
- `script_submitter` keeps its explicit version directory (`v3.6`) because platform
  marketplace registrations reference that path.

## The endpoint pattern

Every workflow here uses it: preprocessing checks out this repo
(`parallelworks/checkout`, sparse `workflows/<name>` [+ `tools/...`]), assembles
`inputs.sh` + `controller.sh` + `start-template.sh`, submits through
`workflows/script_submitter/v3.6/<variant>.yaml`, and waits for a **`pw` endpoint**
(`pw endpoints list`) named `<service>-${PW_RUN_SLUG}`. No `sessions:` block.

The older session pattern (a `sessions:` block + the `session_runner` subworkflow
registering a platform tunnel session) is legacy and lives only in
`parallelworks/interactive_session`; to convert one of those workflows, follow
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`.

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

### Workflow YAMLs
- **The repo is fetched from GitHub at runtime**: `parallelworks/checkout` steps pull
  `https://github.com/parallelworks/workflows.git` (branch **canary**) and subworkflow
  steps use `uses: github/parallelworks/workflows@canary` with
  `$yaml: workflows/script_submitter/v3.6/<variant>.yaml`.
  Changes only take effect once pushed to that branch.
- Checked-out paths are repo-relative: scripts materialize at
  `<rundir>/workflows/<name>/...` — reference them with that prefix.
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
repo and executing scripts directly. Validate YAML changes with
`pw workflows run ./workflows/<name>/yamls/<variant>.yaml -i '{...}'` against a real
cluster (remember to push first — see above). `emed`/`hsp`/`noaa` variants can only
run from those platforms.

## Git and deployment

- Primary branch: **canary** (`git@github.com:parallelworks/workflows.git`) — the
  branch the YAMLs reference at runtime.
- Large binaries stay out of this repo. Legacy binaries (noVNC tarballs, SIF images)
  are still fetched from the old `interactive_session` repo's `legacy` tag by the
  scripts that need them — leave those clone blocks alone.
- Platform marketplace registrations may still point at old repo paths; changing a
  path here without re-pointing the registration breaks the marketplace entry
  (see MIGRATION.md).
