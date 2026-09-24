# Migration map: `interactive_session` + `activate-rag-vllm` → `workflows`

Consolidation performed 2026-08-31, revised the same day after review feedback
(round 2). Sources (read-only, untouched): `parallelworks/interactive_session@main`
(ca0d0e24) and `parallelworks/activate-rag-vllm@main` (5c68590).

**Review changes (applied after the initial migration, in order):**
1. **One script version only, the latest.** All `-v3` scripts and the legacy-generation
   variants that called them were removed from this repo (see "Left behind"); the
   remaining scripts are unsuffixed (`controller.sh`, `start-template.sh`).
2. **Per-workflow `yamls/` subdirectory**: variant YAMLs live at
   `workflows/<name>/yamls/<variant>.yaml`; scripts and support files stay at the
   directory root (which restored the original `cp workflows/<name>/*.yaml .`
   conda-env glob in the jupyter/jupyterlab YAMLs — the workflow YAMLs no longer
   share that directory).
3. **Tutorials migrated** to `tutorials/` (from `workflow/tutorials/`), with their own
   checkout/`uses:` references re-pointed to this repo.
4. **No version suffixes anywhere**: filenames, YAML references, script comments,
   docs, and the AI skill were scrubbed. The two deliberate exceptions are this file
   (it records history) and the skill's
   `references/session-to-endpoint-upgrade.md` (a conversion guide whose old-name
   references point at files in `interactive_session`, where the unconverted variants
   still live).
5. **Tutorials trimmed and renamed**: `matrix/`, `nginx/`, and `round-robin-failover/`
   were dropped (their topics live on as stages 5–7 of the two courses);
   `fractal-demo`→`tutorials/demo-app`, `pw_endpoints`→`tutorials/endpoint-workflows`,
   `hsp`→`tutorials/session-workflows-hsp` (all internal paths, the demo venv dir, and
   the AI-skill references re-pointed).
6a. **Runtime files grouped under `app/`** (later review): single-implementation
   workflows sparse-checkout `workflows/<name>/app` (scripts + support files) so runs
   stop materializing `yamls/`, `thumbnails/`, and READMEs; multi-implementation
   workflows already had this property via their impl subdirs. Build tooling (defs,
   `build-container.sh`) and docs stay outside `app/`.
6. **Session pattern dropped entirely**: `workflows/vncserver`, `workflows/langflow-host`,
   and `workflows/session_runner` were removed — legacy, no `pw` endpoints (they
   registered platform tunnel sessions). They remain in `parallelworks/interactive_session`
   until converted to the endpoint pattern. Every workflow in this repo is now
   endpoint-pattern, and `script_submitter` is the only shared subworkflow.

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
| `<variant>_v{4,5}.yaml` | `yamls/<variant>.yaml` |

**Branch choice:** the empty `parallelworks/workflows` repo advertises `canary` as its
default branch, so all runtime references target `@canary`. A later rename to `main`
is a mechanical find/replace (`@canary`→`@main`, `branch: canary`→`branch: main`).

## Per-workflow map (interactive_session)

Variant YAMLs land at `workflows/<new>/yamls/`, scripts at `workflows/<new>/`
(implementation subdirs where a runtime input selects them).

| New directory | YAMLs (from `workflow/yamls/<src>/`) | Scripts (from) | Notes |
|---|---|---|---|
| `workflows/jupyter` | jupyter-host: general_v5, noaa_v5 | `jupyter-host/` v4 pair → unsuffixed | conda-env YAMLs (`notebook*.yaml`) at dir root |
| `workflows/jupyterlab` | jupyterlab-host: general_v5, hsp_v5, noaa_v5, general_k8s_v5 | `jupyterlab-host/` v4 pair → unsuffixed | + `yamls/k8s.yaml`/`k8s-readme.md` from `workflow/k8s/jupyter/` |
| `workflows/openvscode` | openvscode: all five _v5 | `openvscode/` v4 pair → unsuffixed | + `yamls/k8s.yaml`/`k8s-readme.md` from `workflow/k8s/vscode/` |
| `workflows/webshell` | webshell: general_v5, noaa_v5 | `webshell/` v4 pair → unsuffixed | controller keeps its `interactive_session@legacy` clone for the noVNC/ttyd tarball (see "downloads") |
| `workflows/vncserver` | vncserver: all 14 _v4 | `vncserver/` v3 pair → unsuffixed (its only/latest generation; session pattern) | readme from typo dir `workflow/readmes/vnserver/`; **removed later** (review change 6) |
| `workflows/kasmvnc` | kasmvnc-container: general/hsp/noaa/noaa_rstudio/general_k8s _v5 | impl subdir `kasmvnc-singularity/` (v4 pair → unsuffixed) + GPU build helpers | + `yamls/k8s.yaml`/`k8s-readme.md` from `workflow/k8s/kasmvnc/`; `yamls/general_rstudio.yaml` added post-migration — the endpoint-pattern replacement for the legacy `general-rstudio.yaml` (general.yaml mechanics + noaa_rstudio's rstudio form); `yamls/emed.yaml` converted 2026-09-02 from the legacy session-pattern `kasmvnc-container/emed.yaml` — a **path-based** endpoint (`--no-subdomain`; the emed platform has no session subdomains), verified live on `cluster.einsteinmed.edu` |
| `workflows/n8n` | n8n: general/hsp/noaa _v5 | impl subdirs `n8n-docker/`, `n8n-singularity/` (v4 pairs → unsuffixed) | runtime input values = subdir names |
| `workflows/librechat` | librechat-container: general_v5, hsp_v5, general-all_v5, hsp-all_v5 | impl subdir `librechat-singularity/` (v4 pair → unsuffixed + helper scripts) and component `librechat-singularity-manager/` (v4 pair + `server.py`) | the `-all` variants sparse-checkout `workflows/librechat/librechat-singularity-manager` and `workflows/langflow-singularity`; `browser-demo/` migrated |
| `workflows/langflow-host` | langflow-host: general_v4, hsp_v4 | v3 pair → unsuffixed (its only/latest generation; session pattern) | **removed later** (review change 6) |
| `workflows/langflow-singularity` | langflow-singularity: hsp_v5 | v4 pair → unsuffixed + `flows/` + build script | start-template's `flows` path updated to `workflows/langflow-singularity/flows` |
| `workflows/streamlit` | streamlit: general_v5, hsp_v5 | from `streamlit-singularity/` + `demo/`, def, build script | start-template's demo-app path updated |
| `workflows/open-notebook` | open-notebook: general_v5 | from `open-notebook-docker/` | |
| `workflows/ollama` | ollama-gguf: general/hsp/noaa _v5 | impl subdirs `ollama-gguf/`, `ollama-gguf-container/` (v4 pairs → unsuffixed) | dir renamed to avoid `ollama-gguf/ollama-gguf/`; impl names (= input values) unchanged |
| `workflows/agent-orchestrator` | agent-orchestrator: general_v5 | v4 pair → unsuffixed + .py files | sparse `tools/utils` unchanged |
| `workflows/hermes-agent` | hermes-agent: general_v5 | v4 pair (only generation) + proxies | |
| `workflows/lite-agent` | lite-agent: general_v5 | v4 pair → unsuffixed + .py files | |
| `workflows/rag-service` | rag-service: general_v5 | v4 pair → unsuffixed + support files, `fixtures/` | checkout branch `rag-service` was deleted upstream → now `canary` (see "dead branches") |
| `workflows/mlflow` | `workflow/k8s/mlflow/general.yaml` → `yamls/k8s.yaml` | none (self-contained) | k8s-only workflow |
| `workflows/ollama-openwebui` | `workflow/k8s/ollama-openwebui/general.yaml` → `yamls/k8s.yaml` | none (self-contained) | k8s-only workflow |
| `workflows/session_runner/v1.4` | copied + READMEs updated | — | internal `uses`/`$yaml` re-pointed; **removed later** with vncserver + langflow-host, its only consumers (review change 6) |
| `workflows/script_submitter/v3.6` | copied as-is + READMEs | — | fully self-contained |
| `tools/oras`, `tools/utils`, `tools/tests` | `tools/` (repo root, unchanged path) | — | scripts reference `tools/...` relative to the run dir; keeping the root path means zero script edits |
| `workflow/tutorials/{fractal-demo,pw_endpoints,hsp}` | `tutorials/{demo-app,endpoint-workflows,session-workflows-hsp}` | — | their own checkouts/`uses:`/path mentions re-pointed to this repo; `matrix`, `nginx`, `round-robin-failover` left behind (topics covered by course stages 5–7) |

Readmes: each workflow's `workflow/readmes/<src>/` docs moved into its directory
(`general.md` → `README.md`, `cloud.md` for jupyter; `general_k8s.md` → `README_k8s.md`;
per-deployment mds kept only where the variant migrated). Thumbnails: matched by name
from the shared `workflow/thumbnails/` pool (kept their filenames), grouped under
each workflow's `thumbnails/` subdirectory; `r.png` joined `workflows/kasmvnc/thumbnails/`
for the rstudio variants.

## rag-vllm (from activate-rag-vllm)

The runtime tree lives at `workflows/rag-vllm/`, trimmed (round 3 review) to what the
YAMLs reach directly or transitively: `controller.sh`, `start-template.sh`,
`start_service.sh`, the three .py services + `indexer_config.yaml`,
`singularity/{env.sh.example,Singularity.rag,Singularity.vllm,singularity-entrypoint.sh}`
(the defs are copied by `start_service.sh`; the entrypoint is baked in by
`Singularity.rag`), plus READMEs/thumbnails/LICENSE.md/.gitignore as
registration/legal assets. Removed as unreachable from the YAMLs: `lib/` (only the
legacy scripts sourced it), `docker/` + the docker RUNMODE branch inputs (the YAMLs
hardcode RUNMODE=singularity), `docs/`, `scripts/` (SIF build drivers),
`configs/hpc-presets.yaml` (presets are inlined in hsp.yaml), `singularity-compose.yml`,
`run_local.sh`, `clean.sh`, `local.env.example`, and nested duplicate directories from
a non-idempotent copy during the initial migration. YAMLs (latest generation only):
`yamls/general_v5.yaml`→`yamls/general.yaml` (supersedes root `workflow.yaml`),
`yamls/hsp_v5.yaml`→`yamls/hsp.yaml`, `yamls/noaa_v5.yaml`→`yamls/noaa.yaml`.
The wrappers `controller_v5.sh`/`start_service_v5.sh` took the standard names
`controller.sh`/`start-template.sh` (`start_service.sh` is not a version of them —
it is the compose-stack launcher that `start-template.sh` executes in RAG mode).

The old repo cloned **itself** with scripts at the checkout root; that layout shifted,
so beyond the global rules:

- YAMLs: checkout gained `sparse_checkout: [workflows/rag-vllm]`; script existence
  checks and `cat` lines prefixed with `workflows/rag-vllm/`; `service.repository`
  default → this repo; `repository_branch` default → `canary`; RAG run-dir defaults
  `…/activate-rag-vllm` → `…/workflows` (it now holds a clone of this repo).
- `controller.sh`: after cloning `${repository}` into `${rag_rundir}`, the stack root
  is `rag_appdir="${rag_rundir}/workflows/rag-vllm"` — run artifacts, `cache/`, and
  `.run.env` target it, and it is exported in `inputs.sh`.
- `start-template.sh`: launches `start_service.sh` from (and cancels via) `${rag_appdir}`.

## burst-render-demo (from parallelworks/burst-render-demo)

Migrated 2026-09-23 from `parallelworks/burst-render-demo@main` (ae9ad9b), the
multi-site burst demo: a FastAPI dashboard on one resource and Mandelbrot tiles rendered
in parallel on N compute sites, which POST them back through reverse SSH tunnels. The
source served the dashboard through a platform **session** (`sessions:` block +
`parallelworks/update-session`, its own `wait_for_dashboard` poll of coordination
files) and its remote sites cloned the source repo for the scripts. Here it follows the
repository's endpoint pattern end to end: the run **completes** once the tiles are
rendered and the dashboard outlives it behind `burst-render-<run-slug>`.

| Old | New |
|---|---|
| `scripts/*` (runtime) | `workflows/burst-render-demo/app/*` (incl. `templates/index.html`) |
| `scripts/setup.sh` + the dependency install in `scripts/start_dashboard.sh` | `app/controller.sh`: Python check, shared `uv` (`${service_parent_install_dir}/.uv/uv`), dashboard virtualenv at `${service_parent_install_dir}/burst-render-demo/venv`, idempotent, verified by importing the app |
| `scripts/start_dashboard.sh` (port from `pw agent open-port`, `nohup uvicorn`, `HOSTNAME`/`SESSION_PORT`/`job.started` files, keep-alive loop) | `app/start-template.sh`: `pw endpoints run ${pw_endpoints_args} -- ./launch-dashboard.sh`; the launcher publishes the port `pw endpoints run` assigned (`PORT`) as `SESSION_PORT` and execs uvicorn |
| `scripts/setup_tunnel.sh` (unused by the workflow) | dropped |
| `workflow.yaml` (`sessions:`, jobs `checkout`, `start_dashboard`, `wait_for_dashboard`, `update_session`, `configure_dashboard`, `render`, `complete`) | `yamls/general.yaml`, `yamls/hsp.yaml`: `preprocessing` → `session_runner` (`script_submitter/v3.6/<variant>.yaml`, login node) + `wait_for_endpoint` (shared subworkflow) → `render` (configure, dispatch, summary) |
| checkout `parallelworks/burst-render-demo@main`, sparse `scripts` | `parallelworks/workflows@burst-render-demo`, sparse `workflows/burst-render-demo/app` |
| remote site: `git clone --sparse burst-render-demo.git` + `sparse-checkout set scripts` + `bash scripts/setup.sh` into `~/pw/jobs/burst_render_remote` | clone of this repo (`REPO_URL`/`REPO_BRANCH` from the YAML) + `sparse-checkout set workflows/burst-render-demo/app` into `~/pw/jobs/burst_render_remote/<run-slug>/`; a `python3` presence check replaces `setup.sh` (nothing on a render site needs `uv`) |
| `thumbnail.png` | `thumbnails/burst-render-demo.png` |

`renderer.py`, `post_tile.py`, `dashboard.py` and `templates/index.html` are verbatim.
`render_tiles.sh` locates `renderer.py`/`post_tile.py` next to itself instead of under
`${PW_PARENT_JOB_DIR}/scripts`. `dispatch_renders.sh` changes beyond the paths:

- **Local mode.** A site on the dashboard host's own resource renders without a tunnel:
  `render_tiles.sh` on the login node, or under `srun` with the dashboard reached on the
  login node's hostname. The source always dispatched over `ssh -i ~/.ssh/pwcli`, which
  a cloud cluster's login node does not have (only the workspace and `existing`
  resources do; verified on gcpsmall, the workspace and `a30gpuserver`), so the demo
  could not run with a cloud login node as its dashboard host.
- **Remote mode** keeps the reverse tunnel, adds `-o ControlMaster=no -o ControlPath=none`
  (the workspace's ssh config multiplexes connections; a tunnel-carrying connection must
  not be shared, same fix as ray-cluster) and a clear error when `~/.ssh/pwcli` is
  missing on the dashboard host.
- **`#SBATCH` directives reach `srun`.** The form's Additional Directives were parsed
  and never used (the source hid the field); they are now appended to the `srun` command
  as options, which is how `general` takes an account or QoS and `hsp` its
  `--constraint=mla` hint. Commented `##SBATCH` lines and trailing comments are dropped.
- **Failures count.** Every site function ended in `| sed` (prefixing the output), so a
  failed site returned 0 and `FAILED` never incremented; the script runs under
  `pipefail` now, so a failed site fails the `render` job.
- The `pkill -f render_tiles.sh` / `renderer.py` "stale process" sweep on remote sites is
  gone: it would kill a concurrent run's renders on a shared login node. Remote work
  dirs are per run instead.
- `CLUSTER_NAME` is passed to every site (the dashboard labels sites by resource name;
  the `pw cluster list` discovery in `render_tiles.sh` remains as the fallback).

**Form.** The `head` / `targets` / `render_settings` groups are kept (multi-resource form,
same reasoning as ray-cluster judgment call 4); the hidden `render_settings.name`
(`burst-render`) is the endpoint prefix. The `pbs` group and the `is_disabled` markers
are gone: the dispatcher only ever scheduled through `srun`, so a PBS (or any non-SLURM)
site renders on its login node and the **Schedule Job?** toggle only shows for SLURM
resources. `general.yaml` drops the per-site SLURM account/QoS dropdowns (they go in the
directives editor, as in every `general` variant here); `hsp.yaml` keeps them, shown for
`existing` resources like the other hsp forms, and pre-fills the DSRC constraint hint.
The dashboard host has no scheduler option: the sites' tunnels terminate on the host
that dispatches them, so the submitter runs the start script on the login node.

**Cancel.** The `render` job runs the dispatcher in its own process group (`set -m`) and
its step cleanup kills the group, so a cancel during the render stops the local renders,
the `srun` allocation and the site SSH sessions (the remote `bash -s` trees get the
hangup).

**Test results (2026-09-23, `pw://alvaro/gcpsmall`, branch `burst-render-demo`):**
pass = the run completed (its `wait_for_endpoint` saw the endpoint answer, then the
`render` job reported every site `COMPLETED` with 0 tile errors) and
`burst-render-<run-slug>` was listed; teardown = `pw endpoints delete`, after which no
dashboard, endpoint wrapper, dispatcher or render process was left on the resource. Rows
are in `workflows/burst-render-demo/tests/*/*.csv`; 4x4 grids of 128 px tiles.

| Test | Result |
|---|---|
| `general/gcp-dashboard-gcp-login` (dashboard and site on the gcpsmall login node) | PASS `willing-hawk` (cold: `uv` already cached at `~/pw/software/.uv` from ray-cluster, venv built in seconds; 16 tiles OK; endpoint `HTTP 200` after 0 s; 37 s) |
| `general/gcp-dashboard-gcp-compute` (site scheduled: `srun --partition=compute`) | PASS `included-ox` (warm, 38 s): tiles rendered on `gcpsmall-…-1-0001`, posted to the login node's hostname and port |
| `hsp/gcp-dashboard-gcp-login` | PASS `adequate-hen` (warm, 38 s) through `script_submitter/v3.6/hsp.yaml` |
| `hsp/gcp-dashboard-gcp-compute` | PASS `dynamic-dogfish` (warm, 38 s) |
| `general/workspace-dashboard-gcp-compute` (dashboard on the user workspace, site gcpsmall over `pw ssh`) | PASS `pure-boxer` (38 s): SSH probe, reverse tunnel, sparse clone of this branch into `~/pw/jobs/burst_render_remote/pure-boxer/`, TCP proxy on the login node, `srun` on a compute node, 16 tiles OK; the probe ran from the workspace (`host` rendered empty) |

**Cancel mid-render** (`easy-sunfish`, 16x16 grid of 512 px tiles, single worker, login
node): with the dispatcher, `render_tiles.sh`, `xargs` and a `renderer.py` alive in the
dispatcher's process group, `pw workflows runs cancel` left only the dashboard tree
(`pw endpoints run` + uvicorn, released by the skip file as designed), `squeue` empty and
the endpoint listed; the dashboard's `/api/state` held the 2 tiles finished before the
cancel, and `pw endpoints delete` then removed the two remaining processes and the
endpoint. The compute tests carry `"scheduler": true` in `_test` for the runner's
`squeue` check that the ray-cluster branch adds; this branch's runner ignores the key.

Not exercised: a PBS or SSH-mode remote site, multi-node `srun` allocations, a dashboard
host older than Python 3.8 (the `uv python install` path) and a site whose login shell is
tcsh — the remote script transport for those is verbatim upstream.

**Fixes after the first HSP run (2026-09-24, `jean.arl.hpc.mil`).** The merged workflow
failed on jean at *Dispatch Renders* with
`json.decoder.JSONDecodeError: Invalid control character at: line 1 column 357`:

- **JSON must never be pasted into `python -c` source.** The dispatcher built its site
  list with `json.loads('''${SITES_JSON}''')`, so python un-escaped the document before
  json.loads saw it and the `\n` that `json.dumps` had written inside a value became a
  real newline. The trigger is any multi-line form value: on jean that was the hsp
  **SLURM directives default**, which ends in a newline — the form's own default, while
  every gcpsmall test had passed `""` for that field and never saw it. Every `python -c`
  in the script now reads its JSON from the environment and is single-quoted so the
  shell cannot expand into it either; the two compute tests carry multi-line directives
  so the shape stays covered.
- **Remote sites are sent the scripts instead of cloning them.** `REPO_URL`/`REPO_BRANCH`
  were hardcoded in the YAMLs, and the canary merge (#63–#65) flipped the checkout
  `branch:` to canary while leaving `REPO_BRANCH: burst-render-demo`, so a remote site
  would have cloned different code than the dashboard host was running. Deriving the
  branch from the checkout does not work — **`parallelworks/checkout` leaves no `.git` in
  the job directory** (verified on the workspace after run `engaging-eft`, which
  therefore cloned canary while its dashboard host ran the dev branch). So the three
  files a site needs (`render_tiles.sh`, `renderer.py`, `post_tile.py`) are now tarred
  over the SSH connection the dispatcher already opens, into
  `~/pw/jobs/burst_render_remote/<run-slug>/app/`. The site runs exactly what the
  dashboard host checked out, needs no GitHub access (an HPC site's login node may have
  none), and the workflow has one branch reference again — the checkout's.
- **The endpoint name is built once** (tidy-up, not a fix). It was composed from
  `${{ inputs.render_settings.name }}` in three places that had to stay in step. The jean
  request sent `""` for that hidden field, as a rerun built from a past run's INPUTS tab
  does; that turned out to be harmless — **the platform default-fills an empty group
  item** (verified 2026-09-24 on `activate.parallel.works`: a request with
  `"name": ""` produced `export service_name="burst-render"` in `inputs.sh`), so the
  name was never malformed. Preprocessing now publishes `ENDPOINT_NAME`, computed once
  with a `${service_name:-burst-render}` fallback, and the waiter and the summary read
  that output. The hsp login test carries the empty-field request shape.

**Re-tested after the HSP fixes (2026-09-24, `pw://alvaro/gcpsmall`):** all five tests
pass with `cleanup=ok`. The two compute tests now carry multi-line SLURM directives (the
hsp one carries jean's exact values, including the empty walltime), so the parse that
broke there is covered; the hsp login test sends the hidden fields as `""` like a rerun
built from a past run's INPUTS tab.

| Test | Result |
|---|---|
| `hsp/gcp-dashboard-gcp-compute` | PASS `upright-fowl`, re-run `daring-sawfish` after the transfer change: the directives default parsed, and `srun --partition=compute --nodes=1 --ntasks=1` carried neither the commented `##SBATCH` line nor an empty `--time=` |
| `hsp/gcp-dashboard-gcp-login` | PASS `many-hawk`: `"name": ""` and `"parent_install_dir": ""` were default-filled by the platform, endpoint `burst-render-many-hawk`, `HTTP 200` |
| `general/gcp-dashboard-gcp-compute` | PASS `good-monkfish` (3 min: the compute node was powering up) |
| `general/gcp-dashboard-gcp-login` | PASS `oriented-quetzal` |
| `general/workspace-dashboard-gcp-compute` | PASS `engaging-eft`, re-run `giving-tahr` after the transfer change: the scripts were tarred to `~/pw/jobs/burst_render_remote/giving-tahr/app/` over the dispatcher's SSH connection and rendered under `srun` on a compute node |

Three runs failed in between — `communal-wildcat`, `brave-marlin`, `probable-reindeer`,
all `Dispatch Renders ... syntax error near unexpected token` — because the canary merge
left conflict markers in `dispatch_renders.sh` and they were pushed. Their rows are in
the CSVs.

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

**Legacy-generation variants and their dependencies** (round 2: the old and new script
generations are architecturally incompatible — the old ones serve the injected
`${service_port}` for a platform tunnel session, the new ones run `pw endpoints run` —
so these stay in `interactive_session` until converted; the conversion guide is the
skill's `references/session-to-endpoint-upgrade.md`):

- `webshell/hsp_v4.yaml` (the emed variants were all converted 2026-09-02: kasmvnc,
  jupyter-host, jupyterlab-host, n8n, openvscode → `workflows/<name>/yamls/emed.yaml`,
  and the vncserver emed desktop apps → kasmvnc `emed_{rstudio,schrodinger,firefox}.yaml`;
  see the per-workflow map),
  `kasmvnc-container/general-rstudio.yaml`, `kasmvnc-container/northrop.yaml`
  (air-gapped local-copy variant), `langflow-singularity/general_v4.yaml`,
  `librechat-singularity-manager/{general,hsp}.yaml` (the standalone manager
  workflow; its scripts live on here as a librechat `-all` component),
  `activate-rag-vllm/yamls/emed.yaml` (+ the legacy root `controller.sh` it ran)
- all `controller-v3.sh`/`start-template-v3.sh` files, the `kasmvnc-docker/` impl
  (v3-only, selectable only from the removed variants), and support files only the
  legacy scripts used: `jupyter-host/nginx-unprivileged.def`,
  `n8n-docker/docker-compose.yml.template` (no consumer in any generation),
  `jupyterlab-host/dask-extension-jupyterlab-demo.ipynb` (no consumer),
  `activate-rag-vllm/tests/` (asserts against the superseded legacy YAMLs)
- per-deployment readmes of removed variants: `jupyter-host/{emed-onprem,atnorth-onprem,podmt3,workdir}.md`

**Superseded versions** (the original latest-only rule):

- Old YAML versions (87 files under `workflow/yamls/`), `workflow.yaml` +
  `yamls/{hsp,noaa}.yaml` in activate-rag-vllm, `session_runner/v1.3`,
  `script_submitter/v3.5`, and older scripts nothing selected used
  (agent-orchestrator/lite-agent/openvscode/librechat-singularity `-v3` pairs).

**Out of scope / stale:**

- `workflow/batch/` (helios/kestrel hsp batch examples) — not part of this catalog;
  follow-up decision.
- `workflow/tutorials/{matrix,nginx,round-robin-failover}` — dropped at review; the
  matrix/failover/first-start-wins topics are stages 5–7 of the migrated courses.
- 48 unmatched thumbnails — stale pool entries with no migrated workflow.
- `downloads/` binaries — already absent from the sources' `main` (live only in the
  old repo's `legacy` tag). The scripts that need them (`webshell/controller.sh`,
  `vncserver/controller.sh`) intentionally keep cloning `interactive_session@legacy`.
- Old repo docs (`CLAUDE.md`, `DeveloperGuide.md`, `README.md`,
  `AIPromptAddingNewWorkflow.md`) — rewritten fresh for this repo.
- `.claude/settings.json`, `.gitignore`, `.gitattributes`, `workflow/.DS_Store` —
  repo-local config/noise (this repo has its own).

## Judgment calls (review these)

1. **Branch `canary`** for all runtime references (the repo's advertised default).
2. **Directory renames**: `jupyter-host`→`jupyter`, `jupyterlab-host`→`jupyterlab`,
   `kasmvnc-container`→`kasmvnc`, `librechat-container`→`librechat`,
   `ollama-gguf`→`ollama`, `open-notebook`(-docker)→`open-notebook`,
   `streamlit`(-singularity)→`streamlit`, `activate-rag-vllm`→`rag-vllm`.
   Hidden `service.name` **values** were NOT changed, so endpoint/session names are
   identical to before.
3. **Impl subdirectories keep their old names** (`kasmvnc-singularity`,
   `n8n-docker`, `n8n-singularity`, `ollama-gguf`, `ollama-gguf-container`,
   `librechat-singularity`) because form input values select them at runtime.
4. **`tools/` stays at the repo root** so scripts' `tools/...` run-dir-relative
   references work unchanged.
5. **`librechat-singularity-manager` folded into `workflows/librechat/`** as a
   component: its standalone workflow was legacy-generation (left behind), but the
   librechat `-all` variants still execute its scripts.
6. **Thumbnail guesses** (registration data not visible from here): openvscode→`gitpod.png`
   (openvscode-server is Gitpod's project), vncserver→`desktop.png`,
   agent-orchestrator→`python-ai-orchestrator.png`, lite-agent→`python-ai-worker.png`,
   ollama-openwebui→`ollama.png`. rag-service has no plausible thumbnail in the pool.
7. **webshell has no general readme** in the old repo — none was invented; the noaa
   one moved.
8. **AI home**: canonical skill at `.claude/skills/activate-workflows/` (auto-discovered
   by Claude Code in-repo); approach guides + installer at `docs/ai-workflow-development/`;
   references updated for the new layout. `session-to-endpoint-upgrade.md` (renamed
   from the old v4-to-v5 doc) deliberately keeps pre-consolidation names — it guides
   conversions of the variants still living in `interactive_session`.
9. **Latent quirk preserved**: ollama's singularity→native fallback flips
   `service_impl` to `ollama-gguf` even when only `ollama-gguf-container` was
   sparse-checked-out, so the fallback still fails at the controller step exactly as
   before (fail-loud guard). Fixing it (checkout both impls) is a one-line change
   left out to keep this a reorganization.
10. **librechat's Docker option** (`container_runtime: librechat-docker`) was already
    broken on the sources' `main` (no such directory) and remains so — the
    singularity default works.
11. **rag-vllm's `docs/` prose** still describes some pre-consolidation details
    (`workflow.yaml`, emed) — script names were updated, prose left to the owning team.

## Marketplace / platform registrations to re-point (out of scope here)

Platform-side registrations still reference old repo paths. When re-pointing them:

- Every marketplace workflow entry that pins `workflow/yamls/<x>/<variant>_vN.yaml`
  → `workflows/<name>/yamls/<variant>.yaml` in `parallelworks/workflows@canary`.
  Entries for the left-behind legacy variants keep pointing at `interactive_session`.
- Marketplace subworkflow slugs: `marketplace/session_runner/v1.4`,
  `marketplace/script_submitter/v3.5|v3.6` (v3.5 is used by
  `vncserver/yamls/rstudio_k8s.yaml`) — their registrations must move to
  `workflows/{session_runner,script_submitter}/...` in this repo (v3.5 would need to
  stay on the old repo or the yaml bumped to v3.6).
- Readme/thumbnail paths in registrations (`workflow/readmes/...`,
  `workflow/thumbnails/...`) → the files inside each `workflows/<name>/thumbnails/`.

- The burst-render-demo entry pins `parallelworks/burst-render-demo`'s `workflow.yaml` →
  `workflows/burst-render-demo/yamls/<variant>.yaml` here (`hsp` on `activate.hpc.mil`,
  `general` elsewhere; thumbnail `workflows/burst-render-demo/thumbnails/burst-render-demo.png`).
  The YAMLs and the remote-site clone reference branch `burst-render-demo` until the
  branch lands on canary (`branch:` in the checkout and `REPO_BRANCH` in the `render` job).

## Test results (2026-08-31, repo public, canary pushed)

Method: `pw workflows run <abs path to yamls/general.yaml> -i …` from this repo;
pass = the endpoint appears in `pw endpoints list` and serves HTTP 200 (or, for the
session generation, the tunnel session reaches `running`), then the endpoint/run is
torn down and cleanup verified.

| Workflow | Variant | Target | Result |
|---|---|---|---|
| webshell | general | gcpsmall | PASS (endpoint online, HTTP 200, cleanup OK) |
| openvscode | general | gcpsmall | PASS |
| jupyter | general | gcpsmall | PASS (fresh conda install, 2m09s) |
| jupyterlab | general | gcpsmall | PASS (endpoint 143s, HTTP 200) |
| streamlit | general | gcpsmall | PASS |
| n8n | general (n8n-singularity default) | gcpsmall | PASS |
| kasmvnc | general (kasmvnc-singularity) | gcpsmall | PASS |
| kasmvnc | general_rstudio (added post-migration, #11) | gcpsmall | PASS (endpoint online 61s, HTTP 200, RStudio process confirmed running in the container, cleanup OK) |
| open-notebook | general | gcpsmall | PASS (docker) |
| librechat | general (singularity) | gcpsmall | PASS |
| librechat | general-all | gcpsmall (both roles) | PASS with `enable_proxy:false` — all 3 endpoints (librechat, manager component, langflow) online, HTTP 200. The proxy path needs connected platform AI models + pre-staged `langflow_proxy` code (environment; the original was broken outright — dead `librechat-v2` branch) |
| lite-agent | general | gcpsmall | PASS after fix PR #1 (first run exposed the composed-checkout-path bug) |
| agent-orchestrator | general | gcpsmall | PASS |
| hermes-agent | general | gcpsmall | PASS (dashboard build + endpoint) |
| langflow-host | general | gcpsmall | PASS (tunnel session `running`, cleanup on cancel verified) |
| vncserver | general | gcpsmall | Equivalent-to-original: tunnel session registered and noVNC healthy on its port, but session_runner's readiness poll probes `localhost` while websockify binds the primary IP — never flips to `running`. The ORIGINAL `general_v4.yaml` from interactive_session reproduces this identically on gcpsmall → pre-existing, not migration breakage |
| rag-service | general | gcpsmall | FAIL — pre-existing: `ghcr.io/parallelworks/rag-service:1.0` returns 403 anonymously (package private/missing); the original was also unrunnable (checkout of deleted `rag-service` branch) |
| ollama | general (`gpt-oss:20b`) | awsgpu | PASS (endpoint online, run completed, HTTP 200) |
| rag-vllm | general (vllm runtype, `openai/gpt-oss-20b`) | awsgpu | PASS twice: the original run, and a post-trim re-run (2026-09-01) on a freshly restarted awsgpu controller with `openai/gpt-oss-20b` — full SIF + model re-pull and the sandbox fallback (node cannot mount SIFs) both exercised, endpoint confirmed online. The first re-run attempt surfaced ghcr anonymous-pull rate limiting killing runs on the first failed pull; fixed with bounded retries in both pull paths (#9) |

Found and fixed during testing (PR #1, merged to canary): seven scripts composed
checkout paths from variables (`AGENT_DIR`/`SERVICE_DIR`/`SCRIPTS_DIR`/
`MANAGER_SCRIPTS_DIR`/kasmvnc GL probe) and still assumed the old top-level layout.

Full re-test after the `app/` restructure (review change 6a, 2026-09-02): every
runnable workflow re-verified end-to-end — rag-vllm first on awsgpu (vllm runtype,
gpt-oss-20b, endpoint online), then webshell, jupyter, jupyterlab, openvscode,
streamlit, open-notebook, lite-agent, agent-orchestrator, hermes-agent, and
librechat general-all (all three endpoints) on gcpsmall with the new `app/` paths;
kasmvnc general + general_rstudio, n8n, librechat general (unchanged multi-impl), and
ollama on awsgpu as regressions. All PASS with HTTP verified and endpoints torn down.
rag-service still fails at its pre-existing private ghcr package — after the `app/`
controller path resolved and the pull retried 3 times.

Static-only (cannot run from here): all `hsp`/`noaa` variants (the `emed` variants
were all run live on `cluster.einsteinmed.edu`, 2026-09-02: endpoints online, HTTP +
websocket verified through the platform; kasmvnc additionally had delete and cancel
teardowns verified clean),
`langflow-singularity/hsp.yaml` (its scripts were exercised live by general-all),
and, at the time, the k8s variants incl. `mlflow`/`ollama-openwebui` (no kubernetes
cluster attached) — YAML parse + path-existence + reference checks only; all eight
k8s YAMLs ran live on `k3sgpu` on 2026-09-16 (results in
`.claude/skills/activate-workflows/references/k8s-workflows.md` §8). n8n-docker and
ollama-gguf-container implementation paths not separately exercised.

## Open questions

1. Keep `canary` as the long-lived default branch, or rename to `main` after the
   migration lands? (Mechanical find/replace either way.)
2. Migrate `workflow/batch/` in a follow-up? **Partly (2026-09-23):** the standalone
   `parallelworks/activate-batch` repo's hello-world batch submitter joined as
   `workflows/activate-batch/`, re-pointed from `marketplace/job_runner/v4.0` to
   `workflows/script_submitter/v3.6`; the helios/kestrel examples remain open.
3. Thumbnail guesses in judgment call 6 — confirm against the actual registrations.
4. Converting the left-behind legacy variants (emed etc.) to the endpoint pattern so
   they can join this repo — who/when? **emed done (2026-09-02):** kasmvnc (+ the
   rstudio/schrodinger/firefox desktop-app variants replacing the legacy vncserver
   emed YAMLs), jupyter, jupyterlab, n8n, and openvscode all converted to path-based
   endpoints (`--no-subdomain`) and verified live on `cluster.einsteinmed.edu`
   (schrodinger by module/binary check; it is mechanically identical to the other two
   desktop variants). The emed marketplace registrations still point at
   `interactive_session` and must be re-pointed at `workflows/<name>/yamls/emed*.yaml`
   here once this lands on canary. All six vncserver app variants
   (rstudio, matlab, firefox, fsl, schrodinger, vmd) are replaced by kasmvnc
   `emed_<app>.yaml` variants carrying the legacy `load_env`/`bin` form fields; only
   the plain-desktop `vncserver/emed_v4.yaml` is replaced by a clean emed-only
   rewrite at `workflows/vncserver/yamls/emed.yaml` (host kasmvncserver + GNOME
   behind `pw endpoints https`, no noVNC/nginx/sudo; verified live 2026-09-03).
