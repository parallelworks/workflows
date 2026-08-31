# Migration map: `interactive_session` + `activate-rag-vllm` → `workflows`

Consolidation performed 2026-08-31. Sources (read-only, untouched):
`parallelworks/interactive_session@main` (ca0d0e24) and
`parallelworks/activate-rag-vllm@main` (5c68590). **Latest version only** per workflow
and platform variant; older versions stay behind in the source repos.

## Global rewrite rules

Applied to every migrated YAML (verbatim copies otherwise):

| Old | New |
|---|---|
| `repo: https://github.com/parallelworks/interactive_session.git` | `repo: https://github.com/parallelworks/workflows.git` |
| checkout `branch: main` (also dead branches, see below) | `branch: canary` |
| `uses: github/parallelworks/interactive_session@main` | `uses: github/parallelworks/workflows@canary` |
| `$yaml: workflow/session_runner/v1.4/…` | `$yaml: workflows/session_runner/v1.4/…` |
| `$yaml: workflow/script_submitter/v3.6/…` | `$yaml: workflows/script_submitter/v3.6/…` |
| sparse checkout / script paths `<dir>/…` | `workflows/<name>[/<impl>]/…` |
| `…/controller-v4.sh`, `…/start-template-v4.sh` | `…/controller.sh`, `…/start-template.sh` |
| `…/controller-v3.sh` (where a v4 also exists) | unchanged filename, new path prefix |
| `…/controller-v3.sh` (v3 is the only generation: vncserver, langflow-host) | `…/controller.sh` |

**Branch choice:** the empty `parallelworks/workflows` repo advertises `canary` as its
default branch, so all runtime references target `@canary`. A later rename to `main`
is a mechanical find/replace (`@canary`→`@main`, `branch: canary`→`branch: main`) —
flagged as an open question below.

**Filename versioning:** `<variant>_v{4,5}.yaml` → `<variant>.yaml`; newest script
generation loses its suffix; a `-v3` script kept **only** where a migrated legacy
variant still executes it. In `rag-vllm`, `controller_v5.sh`/`start_service_v5.sh`
keep their suffix because the legacy `controller.sh`/`start_service.sh` (still used by
`emed.yaml`) already own the unsuffixed names.

## Per-workflow map (interactive_session)

| New directory | YAMLs (from `workflow/yamls/<src>/`) | Scripts (from) | Notes |
|---|---|---|---|
| `workflows/jupyter` | jupyter-host: general_v5, noaa_v5, emed_v4 | `jupyter-host/` v4→unsuffixed, v3 kept (emed) | env YAMLs enumerated in `cp` (glob would grab workflow YAMLs) |
| `workflows/jupyterlab` | jupyterlab-host: general_v5, hsp_v5, noaa_v5, general_k8s_v5, emed_v4 | `jupyterlab-host/` v4→unsuffixed, v3 kept (emed) | same `cp` fix; + `k8s.yaml`/`k8s-readme.md` from `workflow/k8s/jupyter/` |
| `workflows/openvscode` | openvscode: all five _v5 | `openvscode/` v4→unsuffixed (v3 left behind) | + `k8s.yaml`/`k8s-readme.md` from `workflow/k8s/vscode/` |
| `workflows/webshell` | webshell: general_v5, noaa_v5, hsp_v4 | `webshell/` v4→unsuffixed, v3 kept (hsp) | controller keeps its `interactive_session@legacy` clone for the noVNC/ttyd tarball (see "downloads") |
| `workflows/vncserver` | vncserver: all 14 _v4 | `vncserver/` v3→unsuffixed (only generation) | readme from typo dir `workflow/readmes/vnserver/` |
| `workflows/kasmvnc` | kasmvnc-container: general/hsp/noaa/noaa_rstudio/general_k8s _v5; emed, general-rstudio, northrop (unversioned) | impl subdirs `kasmvnc-docker/` (v3 only, names kept), `kasmvnc-singularity/` (v4→unsuffixed, v3 kept) | v3 filenames kept so air-gapped `northrop.yaml` (local copy + `marketplace/session_runner/v1.4`, zero rewrites) works against either repo clone; + `k8s.yaml`/`k8s-readme.md` from `workflow/k8s/kasmvnc/` |
| `workflows/n8n` | n8n: general/hsp/noaa _v5, emed_v4 | impl subdirs `n8n-docker/`, `n8n-singularity/` (v4→unsuffixed, v3 kept for emed) | runtime input values = subdir names |
| `workflows/librechat` | librechat-container: general_v5, hsp_v5, general-all_v5, hsp-all_v5 | impl subdir `librechat-singularity/` (v4→unsuffixed; v3 left behind) | `-all` variants also sparse-checkout `workflows/librechat-singularity-manager` and `workflows/langflow-singularity` (cross-workflow refs, one repo now); `browser-demo/` migrated |
| `workflows/librechat-singularity-manager` | librechat-singularity-manager: general, hsp | own dir, v4→unsuffixed (used by librechat `-all`), v3 kept (own yamls) | |
| `workflows/langflow-host` | langflow-host: general_v4, hsp_v4 | v3→unsuffixed (only generation) | |
| `workflows/langflow-singularity` | langflow-singularity: general_v4, hsp_v5 | v4→unsuffixed, v3 kept (general) + `flows/` | both start-templates' `flows` path updated to `workflows/langflow-singularity/flows` |
| `workflows/streamlit` | streamlit: general_v5, hsp_v5 | from `streamlit-singularity/` (v4 only) + `demo/`, def, build script | start-template's demo-app path updated |
| `workflows/open-notebook` | open-notebook: general_v5 | from `open-notebook-docker/` (v4 only) | |
| `workflows/ollama` | ollama-gguf: general/hsp/noaa _v5 | impl subdirs `ollama-gguf/`, `ollama-gguf-container/` (v4→unsuffixed) | dir renamed to avoid `ollama-gguf/ollama-gguf/`; impl names (= input values) unchanged |
| `workflows/agent-orchestrator` | agent-orchestrator: general_v5 | v4→unsuffixed + .py files (v3 left behind) | sparse `tools/utils` unchanged |
| `workflows/hermes-agent` | hermes-agent: general_v5 | v4 (only) + proxies | |
| `workflows/lite-agent` | lite-agent: general_v5 | v4→unsuffixed + .py files (v3 left behind) | |
| `workflows/rag-service` | rag-service: general_v5 | v4 (only) + support files, `fixtures/` | checkout branch `rag-service` was deleted upstream → now `canary` (see "dead branches") |
| `workflows/mlflow` | `workflow/k8s/mlflow/general.yaml` → `k8s.yaml` | none (self-contained) | k8s-only workflow |
| `workflows/ollama-openwebui` | `workflow/k8s/ollama-openwebui/general.yaml` → `k8s.yaml` | none (self-contained) | k8s-only workflow |
| `workflows/session_runner/v1.4` | copied as-is + READMEs | — | internal `uses`/`$yaml` re-pointed to this repo (it calls script_submitter v3.6) |
| `workflows/script_submitter/v3.6` | copied as-is + READMEs | — | fully self-contained |
| `tools/oras`, `tools/utils`, `tools/tests` | `tools/` (repo root, unchanged path) | — | scripts reference `tools/...` relative to the run dir; keeping the root path means zero script edits |

Readmes: each workflow's `workflow/readmes/<src>/` content moved into its directory;
`general.md` → `README.md` (`cloud.md` for jupyter); `general_k8s.md` → `README_k8s.md`;
per-deployment mds kept as-is. Thumbnails: matched by name from the shared
`workflow/thumbnails/` pool into each workflow dir (kept their filenames).

## rag-vllm (from activate-rag-vllm)

Everything the stack runs from moved wholesale to `workflows/rag-vllm/` (lib/, scripts/,
singularity/, docker/, configs/, docs/, tests/, the .py services, legacy
`controller.sh`/`start_service.sh`, v5 scripts, READMEs, thumbnails, LICENSE.md,
.gitignore). YAMLs: `yamls/general_v5.yaml`→`general.yaml` (supersedes root
`workflow.yaml`), `yamls/hsp_v5.yaml`→`hsp.yaml`, `yamls/noaa_v5.yaml`→`noaa.yaml`,
`yamls/emed.yaml`→`emed.yaml` (no v5 exists; legacy generation).

The old repo cloned **itself** with scripts at the checkout root; that layout shifted,
so beyond the global rules:

- v5 YAMLs: checkout gained `sparse_checkout: [workflows/rag-vllm]`; script existence
  checks and `cat` lines prefixed with `workflows/rag-vllm/`; `service.repository`
  default → this repo; `repository_branch` default → `canary`; RAG run-dir defaults
  `…/activate-rag-vllm` → `…/workflows` (it now holds a clone of this repo).
- `controller_v5.sh`: after cloning `${repository}` into `${rag_rundir}`, the stack
  root is now `rag_appdir="${rag_rundir}/workflows/rag-vllm"` — run artifacts,
  `cache/`, and `.run.env` target it, and it is exported in `inputs.sh`.
- `start_service_v5.sh`: launches `start_service.sh` from (and cancels via)
  `${rag_appdir}` instead of `${rag_rundir}`.
- `emed.yaml`: post-clone `cd`s, `working-directory`, and the four session_runner
  paths gained the `/workflows/rag-vllm` suffix; defaults updated as above.

## Dead branches (pre-existing breakage, now fixed)

Three selected YAMLs checked out branches that **no longer exist upstream** — those
workflows were broken at run time before this migration:

- `librechat-container/general-all_v5.yaml` → `branch: librechat-v2`
- `streamlit/general_v5.yaml` → `branch: streamlit`
- `rag-service/general_v5.yaml` → `branch: rag-service`

All three now check out this repo `@canary` with the scripts as they exist on the
sources' `main`. Strictly this changes behavior from "fails at checkout" to "runs" —
worth a close look at testing time.

## Left behind (not copied), with reasons

- **Old YAML versions** (87 files under `workflow/yamls/`): superseded per-variant
  (`_v4` where a `_v5` exists, unversioned where any versioned file exists), e.g. all of
  `vncserver`'s pre-v4 none, `kasmvnc-container/{general,noaa,noaa_rstudio,general_k8s}.yaml`,
  `librechat-container/{general,hsp,general-all,hsp-all}.yaml`, `jupyter-host/general_v4.yaml`, etc.
- **`workflow.yaml`, `yamls/{hsp,noaa}.yaml` in activate-rag-vllm**: superseded by the
  v5 files (per the known facts: `general_v5` supersedes root `workflow.yaml`).
- **`session_runner/v1.3`, `script_submitter/v3.5`**: no selected YAML references them
  (v3.5 is still referenced as a **marketplace** slug by `vncserver/rstudio_k8s.yaml` —
  that's a platform registration, not a repo path).
- **Older scripts nothing selected uses**: `agent-orchestrator/{controller,start-template}-v3.sh`,
  `lite-agent/*-v3.sh`, `openvscode/*-v3.sh`, `librechat-singularity/{controller,start-template}-v3.sh`.
- **`workflow/tutorials/` (27 files)**: teaching material, not platform workflows; the
  AI skill still points at them in `interactive_session`. Candidate for a follow-up move.
- **`workflow/batch/` (helios/kestrel hsp batch examples)**: not part of the session
  workflow catalog this migration covers. Candidate for a follow-up decision.
- **48 unmatched thumbnails**: stale pool entries (abaqus, ansys, fluent, gt_logo, …)
  with no migrated workflow.
- **`downloads/` binaries**: already absent from `main` (live only in the old repo's
  `legacy` tag). The scripts that need them (`webshell/controller*.sh`,
  `jupyter*/controller-v3.sh`, `vncserver/controller.sh`) intentionally keep cloning
  `interactive_session` at `legacy` — left untouched.
- **Old repo docs** (`CLAUDE.md`, `DeveloperGuide.md`, `README.md`,
  `AIPromptAddingNewWorkflow.md`): rewritten fresh for this repo rather than copied.
- `.claude/settings.json`, `.gitignore`, `.gitattributes`, `workflow/.DS_Store`: repo-local
  config/noise.
- `jupyter-host/notebook*.yaml` naming note: both env files migrated; all other support
  files followed their scripts.

## Judgment calls (review these)

1. **Branch `canary`** for all runtime references (the repo's advertised default).
2. **Directory renames**: `jupyter-host`→`jupyter`, `jupyterlab-host`→`jupyterlab`,
   `kasmvnc-container`→`kasmvnc`, `librechat-container`→`librechat`,
   `ollama-gguf`→`ollama`, `open-notebook`(-docker)→`open-notebook`,
   `streamlit`(-singularity)→`streamlit`, `activate-rag-vllm`→`rag-vllm`.
   Hidden `service.name` **values** were NOT changed, so endpoint/session names are
   identical to before.
3. **Impl subdirectories keep their old names** (`kasmvnc-docker`, `n8n-singularity`,
   `ollama-gguf-container`, `librechat-singularity`) because form input values select
   them at runtime; renaming them would change visible input values.
4. **`tools/` stays at the repo root** so scripts' `tools/...` run-dir-relative
   references work unchanged.
5. **`cp <dir>/*.yaml .` globs** (jupyter, jupyterlab) now enumerate the two conda env
   files — the glob would otherwise sweep up the workflow YAMLs that live alongside.
6. **Thumbnail guesses** (registration data not visible from here): openvscode→`gitpod.png`
   (openvscode-server is Gitpod's project), vncserver→`desktop.png`,
   agent-orchestrator→`python-ai-orchestrator.png`, lite-agent→`python-ai-worker.png`,
   librechat-singularity-manager→`librechat.png`, ollama-openwebui→`ollama.png`.
   rag-service has no plausible thumbnail in the pool (none copied).
7. **webshell has no general readme** in the old repo (only `noaa-onprem.md`) — none was
   invented; the noaa one moved.
8. **AI home**: canonical skill at `.claude/skills/activate-workflows/` (auto-discovered
   by Claude Code in-repo); approach guides + installer at `docs/ai-workflow-development/`;
   references updated for the new layout, with the historical upgrade/container guides
   carrying a layout-mapping note instead of a risky full rewrite.
9. **Latent quirk preserved**: ollama's singularity→native fallback flips
   `service_impl` to `ollama-gguf` even when only `ollama-gguf-container` was
   sparse-checked-out, so the fallback still fails at the controller step exactly as it
   did before (fail-loud guard). Fixing it (checkout both impls) is a one-line change
   left out to keep this a pure reorganization.
10. **librechat's Docker option** (`container_runtime: librechat-docker`) was already
    broken on `main` (no such directory) and remains so — the singularity default works.

## Marketplace / platform registrations to re-point (out of scope here)

Platform-side registrations still reference old repo paths. When re-pointing them:

- Every marketplace workflow entry that pins `workflow/yamls/<x>/<variant>_vN.yaml`
  → `workflows/<name>/<variant>.yaml` in `parallelworks/workflows@canary`.
- Marketplace subworkflow slugs: `marketplace/session_runner/v1.4`,
  `marketplace/script_submitter/v3.5|v3.6` (used by `kasmvnc/northrop.yaml` and
  `vncserver/rstudio_k8s.yaml`) — their registrations must move to
  `workflows/{session_runner,script_submitter}/...` in this repo (v3.5 would need to
  stay on the old repo or the yaml bumped to v3.6).
- Readme/thumbnail paths in registrations (`workflow/readmes/...`,
  `workflow/thumbnails/...`) → the files inside each `workflows/<name>/`.
- The air-gapped **northrop** deployment: its `interactive_sessions_dir` input must
  point at a clone of this repo's `workflows/kasmvnc` directory (impl subdirs and v3
  filenames unchanged, so the old clone keeps working too).

## Test results

_Pending checkpoint approval — to be filled in after push + testing._

| Workflow | Variant tested | Target | Result |
|---|---|---|---|
| (all) | — | — | not yet run |

Static-only (platform-bound variants): emed/hsp/noaa/northrop/k8s variants — YAML
parse + path-existence + reference checks only.

## Open questions

1. Keep `canary` as the long-lived default branch, or rename to `main` after the
   migration lands? (Mechanical find/replace either way.)
2. Migrate `workflow/tutorials/` (the AI skill leans on them) and `workflow/batch/`
   in a follow-up?
3. Thumbnail guesses in judgment call 6 — confirm against the actual registrations.
4. `jupyter` vs `jupyterlab` naming: `workflow/k8s/jupyter/` actually deploys
   JupyterLab and was folded into `workflows/jupyterlab/k8s.yaml` per the plan; the
   classic-notebook workflow now lives at `workflows/jupyter/`. Comfortable?
