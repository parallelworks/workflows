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
| `workflows/mlflow` | `workflow/k8s/mlflow/general.yaml` → `yamls/k8s.yaml` | none (self-contained) | k8s-only workflow at the time; the compute-cluster variants followed on 2026-10-07 (see "mlflow on compute clusters") |
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

## ray-cluster (from parallelworks/ray-cluster)

Migrated 2026-09-23/24 from `parallelworks/ray-cluster@main` (98bb3dd): a Ray head and
FastAPI dashboard on one resource, workers dispatched to SLURM/PBS/SSH sites. The source
served the dashboard through a platform **session** and kept its run alive for the
cluster's life. Here one start script runs under `script_submitter`, the run completes once
the workload step is done, and `pw endpoints delete` tears the whole cluster down. How that
works: the workflow README (behaviour, limits) and the ray-cluster section of
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md` (the recipe).

| Old | New |
|---|---|
| `scripts/*` | `workflows/ray-cluster/app/*`, plus `start-template.sh` and `teardown.sh` |
| `scripts/diagnose.sh`, `scripts/generate_thumbnail.py` | `workflows/ray-cluster/diagnose.sh`, `generate-thumbnail.py` (dev tools, outside `app/`) |
| `workflow.yaml` | `yamls/hsp.yaml` (the source form already had the HSP fields), `yamls/general.yaml`, `yamls/noaa.yaml` |
| `add_worker.yaml` | `yamls/{general,hsp,noaa}_add_worker.yaml` |
| `thumbnail.png` | `thumbnails/ray-cluster.png` |
| checkout `ray-cluster@main`, sparse `scripts` | `workflows@canary`, sparse `workflows/ray-cluster/app` |
| remote sites clone `ray-cluster.git` (`scripts`) | remote sites clone this repo (`workflows/ray-cluster/app`; `RAY_REPO_URL`/`RAY_REPO_BRANCH`, default `canary`) |

**Code changes beyond the paths**, each found by a test:

- **`start-template.sh` and `teardown.sh`** (new) and `start_ray_head.sh` implement that
  recipe; the remote worker scripts in `dispatch_workers.sh` now exit through their cleanup
  trap when their ssh session closes (upstream orphaned them whenever a dispatcher died).
- **add_worker** copies the cluster's `RAY_VENV_DIR` (added workers died with
  `ray: command not found`), stops tearing its workers down after a successful dispatch,
  registers its SLURM jobs and remote sessions with the cluster's teardown, and detaches
  remote dispatches (`set -m`, own log) so its run can complete.
- **Dispatcher:** `-o ControlMaster=no -o ControlPath=none` on the site connections (the
  workspace's `ControlPath` broke on `pw://` host names), no leaked `tail -f` streamers,
  and a rejected `sbatch`/`qsub` reports the scheduler's message instead of ending the
  script under `set -e`.
- **Dashboard:** a node that just registered gets 60 s before the Ray poller may drop it
  (remote workers were hidden for minutes).
- **`setup.sh`** honours `RAY_SOFTWARE_DIR`; `noaa.yaml` sets it to `/contrib/pw` when that
  is writable.

**Judgment calls:**

1. The endpoint pattern replaces the source's session.
2. The test runner gained `_test.scheduler` and `_test.expect` (`tools/tests/README.md`).
3. add_worker ships as `<variant>_add_worker.yaml` in the same directory (it shares `app/`).
4. The form keeps its own groups (`head`, `workers`, `ray_settings`, `workload_settings`)
   instead of `cluster`/`service`: a multi-resource form, and renaming would touch every
   expression in the job graph.

**Tests** (2026-09-23/24, `pw://alvaro/gcpsmall` and the workspace; rows in
`workflows/ray-cluster/tests/*/*.csv`): general, hsp and noaa with a same-resource
worker running the benchmark; the form defaults (workspace head, remote gcpsmall worker:
the cluster still served 8 min after its run completed, and a `ray job submit` ran on the
worker); the user-script batch mode; add_worker same-resource (all variants) and remote;
failure paths (rejected partition, failing user script). Manual: cancel before the
endpoint is up, cancel during the benchmark, `kill -9` of the head's GCS after the run
(torn down 2.3 min later). Each ended with no endpoint, process or SLURM job left. Not
exercised: PBS and SSH-mode remote sites, multi-node sites, GPUs, the fractal workload,
and the noaa `/contrib/pw` and `existing`-only branches (no such resource here).

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

**`noaa.yaml` (added 2026-09-24, no counterpart in the source repository).** The general
form plus the three things a NOAA variant carries here: the `noaa` script submitter, the
per-site SLURM **Account** and **QoS** dropdowns shown for `existing` resources (as in
`hsp.yaml`), and a **Set Up Install Parent Directory** step. That step picks the install
tree at run time because NOAA home quotas are small and this workflow builds a virtualenv
there (and downloads a standalone python when the system one predates FastAPI's minimum):
`/contrib/pw` on Hera, Mercury and Ursa, `/usw/rdhpcs/software/pw` on Gaea, `${HOME}/pw/software`
on PPAN, cloud clusters and anything unrecognised. Unlike the staged-tarball workflows
(`webshell`), which let a non-privileged account reuse a shared copy read-only, this one
**must** be able to write to the tree it uses — the controller rebuilds the virtualenv
whenever it fails to import — so the shared directory is taken only when a `mkdir` probe
succeeds. `render_settings.parent_install_dir` therefore carries no default here; an
explicit value still wins.

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
`squeue` check (added with ray-cluster).

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

**noaa tests, 2026-09-24 (`pw://alvaro/gcpsmall`):** PASS `engaging-sunfish` (login node,
37 s) and PASS `humble-robin` (`srun` on a compute node, 170 s), both `cleanup=ok`. As for
the other `noaa` variants here, a cloud cluster exercises the form, the `noaa` submitter and
the fallback branch of the install-directory step (`/home/alvaro/pw/software`); the
per-cluster shared-directory branches and the `existing`-only account/QoS fields are
static-only until the variant runs on a NOAA system.

## hpc_status (from parallelworks/hpc_status)

Migrated 2026-09-29 from `parallelworks/hpc_status@main` (30ce200), the HPC Status
Monitor: a Python dashboard that sweeps every cluster `pw` reaches (plus the HPCMP status
pages or the NOAA docs) and serves fleet, topology, queue, quota, storage and insight
pages. The source already served through `pw endpoints run`, but from one workflow step
that cloned the repository into `~/pw/src/hpc_status` and exec'd `scripts/serve-endpoint.sh`,
which detached the endpoint under `setsid nohup` with a fixed name (`hpc-status`), a
pidfile and its own readiness polling. Here it follows the repository's endpoint pattern
end to end: the run completes once `wait_for_endpoint` saw the dashboard answer, and the
dashboard outlives it behind the same fixed name, `hpc-status`.

| Old | New |
|---|---|
| `src/`, `web/`, `configs/` | `app/src/`, `app/web/`, `app/configs/`, verbatim but for one log line in `src/server/main.py` that pointed at `scripts/run.sh` |
| `scripts/run.sh` (uv by `curl \| sh` into `~/.local/bin`, venv `~/.venvs/hpc-status` with an editable install, port selection, server command) | kept for running by hand, from `app/` with `app/requirements.txt` instead of the editable install (its port tests came back with it); in a run, `app/controller.sh`: shared `uv` (`${service_parent_install_dir}/.uv/uv`), venv `${service_parent_install_dir}/hpc_status/venv` from `app/requirements.txt`, Python 3.12 through uv when the system one predates 3.10, idempotent, verified by importing the server; the server command is the `launch-dashboard.sh` the start template writes |
| `scripts/serve-endpoint.sh` | `app/start-template.sh`: configuration, durable credential, subdomain, restart, subdomain fallback — the same behaviours, in the start-template contract; `scripts/serve-endpoint.sh` stays as a wrapper that runs `controller.sh` and `start-template.sh` by hand |
| `scripts/stop-endpoint.sh`, `scripts/test.sh` | dropped: `pw endpoints delete` is the teardown, as everywhere here (the pidfile it also used existed only in detached mode); tests run with `cd dev && python -m pytest` |
| `workflow.yaml`, `yamls/hsp.yaml`, `yamls/rdhpcs.yaml` | `yamls/general.yaml`, `yamls/hsp.yaml`, `yamls/noaa.yaml` |
| `tests/` | `dev/tests/` (`dev/pytest.ini` puts `../app` on the path) |
| `schemas/`, `scripts/build_openapi.py`, `scripts/build_basemap.py` | same paths (briefly `dev/schemas/`, `dev/scripts/`; moved back so the verbatim README's links and commands work) |
| `docs/{api,configuration,glossary,rdhpcs-cluster-marketplace}.md`, `examples/` | `docs/`, `docs/examples/`; configuration.md's environment-variable tables described `run.sh` and now map the form to server arguments |
| `docs/images/thumbnail-{general,hpcmp,noaa}.png` | `thumbnails/{hpc-status,hpcmp-status,rdhpcs-status}.png` |
| `README.md`, `docs/deployment.md` | `README.md` verbatim (what the marketplace listings show; every variant's registration uses it); `docs/deployment.md` rewritten for the workflow: jobs, inputs, variants, stopping, debugging, development |
| `REFACTOR.md`, `pyproject.toml`, `.gitignore` | left behind: a planning log; packaging for an editable install nothing does any more (dependencies in `app/requirements.txt`, pytest options in `dev/pytest.ini`); repo-local |
| `LICENSE` | `LICENSE`, the same Apache License 2.0 as this repository's; the README links it |

**Behaviour, source → here.** The jobs follow the pattern; what a user sees does not
change: the same form (labels, defaults, the collapsed **Settings** group), the same
endpoint name and address, the same restart, fallback and stop behaviour.

- **Lifecycle.** **Keep Serving After The Run Ends** (`service.detach`, default on) keeps
  both modes. On: the run completes once `wait_for_endpoint` saw the dashboard answer (the
  source: once the URL was announced and the port connected) and the dashboard outlives it.
  Off: `wait_for_endpoint` marks a file the submitter does not read and the submitter is
  not cancelled, so the run stays open while the dashboard serves and cancelling it is the
  teardown (the submitter's cleanup kills the process group); a dashboard stopped by
  deleting its session ends the run `completed`.
- **Endpoint name.** `hpc-status` (`rdhpcs-status` on NOAA), the visible **Endpoint Name**
  (`service.name`), as in the source; folded to `[a-z0-9-]` before it reaches `pw`.
  "Starting again restarts": `controller.sh` deletes the endpoint with this name wherever
  it runs (the source's `stop-endpoint.sh`) and waits until it is unlisted. That has to
  happen in preprocessing: `wait_for_endpoint` looks the endpoint up by name, and would
  otherwise find the previous dashboard answering and release the run on it. The start
  script then deletes endpoints at `https://<subdomain>.` named `<name>-*` (dashboards
  launched while the name carried the run slug, 2026-09-29 to 2026-10-02) and leaves
  anything else there alone; the launch then falls back to an assigned address, as the
  source did.
- **Host.** `settings.host`, an optional `compute-resources` picker (blank = workspace), →
  `cluster.resource`, `compute-clusters` with `include-workspace: true` and
  `default: workspace` (as agent-orchestrator), labelled **Where To Run** in its own
  collapsed group after Settings, so the form still opens on Platform and two collapsed
  groups. `compute-resources` does not hydrate from the CLI and lists Kubernetes clusters,
  where this cannot run. The submitter never schedules: the dashboard needs `pw`, its
  credentials and internet access for as long as it serves, and an allocation would end at
  its walltime.
- **Health.** The source grepped its log for `Endpoint live at`, then waited for a TCP
  connect to the port. Here `wait_for_endpoint` probes `/` through the platform with the
  run's key, with a 900 s budget: a first start has no cached fleet and answers only after
  one full sweep (`pw ssh` to every cluster, or the HPCMP pages).
- **Inputs.** `platform` stays top level; `settings.*` → `service.*` (same keys and
  labels), `settings.host` → `cluster.resource`. **Local Port** (`service.port`) is passed
  to `pw endpoints run --port` when non-zero. Dropped: `repo_url`/`repo_branch` — the
  dashboard comes from this repository's checkout now, and the subworkflow references are
  fixed at `canary`. The `number` inputs are `integer` (the server parses them with
  `int()`), the interval with `min: 60` (the server clamps to 60 anyway).
- **Credentials:** the same order and effect as `serve-endpoint.sh` — the workspace key
  from `/etc/profile.d/parallelworks-env.sh` when it works, then saved credentials when they
  authenticate on their own — plus a warning in the run log when neither exists (the source
  said nothing and the fleet went coreless after the run). `PW_PLATFORM_HOST` from
  `inputs.sh` keeps saved credentials for another platform from qualifying.
- **noaa:** `PW_CONTEXT: noaa` in the step's `env:` → the hidden `service.pw_context`,
  exported by the start script; plus the **Set Up Install Parent Directory** step the other
  noaa variants carry. With a key in the environment `pw` ignores both `PW_CONTEXT` and
  `--context` (verified), so the pin only decides which saved identity qualifies.

**Code changes beyond the paths:** the `run.sh` hint in `_create_server`'s busy-port
message. The pytest suite lost `test_workflows.py` (67 tests pinning the three source
YAMLs and the serve/stop scripts) and `TestLauncherPrefersDurableAuth` (3,
`serve-endpoint.sh`), kept `TestRunScriptPortHandling` (7, `scripts/run.sh`), and gained
`test_start_template.py` (32), which runs the new start script, and `serve-endpoint.sh`
around it, against a fake `pw` for the same behaviours, `test_controller.py` (3, the
restart by name) and `test_variants.py` (8: no run slug in the name, `canary`
everywhere, the three forms aligned): 596 pass.

**User experience restored (2026-10-02, branch `status-monitor`).** The move first
shipped with the endpoint renamed `hpc-status-<run-slug>` (a new name every run, which
users noticed), `detach`, `port` and a visible `name` dropped, the host picker promoted
to a top group, Platform moved into the settings, an address held by another endpoint
failing the run instead of falling back, and `general.yaml`/`noaa.yaml` still fetching
from the deleted `hpc_status` branch. All of it is back to the source's behaviour above,
inside the endpoint pattern.

**Judgment calls:**

1. The directory is `hpc_status` as requested (underscored like `script_submitter`), the
   branch too.
2. The development kit (pytest suite, OpenAPI and basemap builders, schemas, reference
   docs) came along, outside `app/`, because development of the dashboard continues here.
3. A launch deletes the user's own previous dashboard (by name, and `<name>-*` at its
   address), where openvscode fails when its subdomain is taken: that is the source's
   documented behaviour, and a dashboard has no unsaved state to lose.
4. The server binds `127.0.0.1`, not `0.0.0.0`: only the tunnel on the same host reaches it,
   and it has no login of its own to protect the allocation data on a shared login node.
5. No `cancel.sh` (`define_cleanup_script: false`, as burst-render-demo): everything the
   dashboard starts stays in the start script's process group.
6. The test runner accepts `workspace` as a resource (`tools/tests/README.md`), so the
   form's default is a recorded test; it was skipped as inactive before.

**Test results (2026-09-29, `activate.parallel.works`, branch `hpc_status`):** pass = the
run completed (its `wait_for_endpoint` got `HTTP 200` from `/` through the platform) and
`<prefix>-<run-slug>` was listed at `https://status-alvaro.activate.pw/`; teardown =
`pw endpoints delete`, after which no dashboard or `pw endpoints run` process was left.
Rows are in `workflows/hpc_status/tests/*/*.csv`.

| Test | Result |
|---|---|
| `general/workspace` (the form's defaults) | PASS `crisp-shepherd` (cold, 22 s: uv installed Python 3.12 because the step's `python3` is 3.9, venv built, first sweep of 2 clusters in 4 s, healthy on the first probe; the workspace key adopted) |
| `general/workspace`, kept | PASS `safe-lab`: the dashboard collected both clusters again at 16:38 and 16:40, 2 and 4 minutes after its run completed, with queue and node data — the run key would have been revoked by then |
| `general/gcp-login` (gcpsmall login node, dark theme, 300 s interval, 3 at once), kept | PASS `natural-midge` (cold on gcpsmall, 37 s: uv itself installed from GitHub): the saved `pw` credentials on the login node adopted, the flags reached the server, and `safe-lab`'s dashboard on the *workspace* was deleted first — its tree shut itself down (`Endpoint ... was deleted; shutting down`), no process left there. Deleted by hand afterwards, nothing left |
| `hsp/workspace`, `hsp/gcp-login` | PASS `refined-mantis`, `just-arachnid` through `script_submitter/v3.6/hsp.yaml`, `config.hpcmp.yaml` loaded |
| `noaa/workspace`, `noaa/gcp-login` | PASS `better-gannet`, `wondrous-escargot` through `script_submitter/v3.6/noaa.yaml`, `config.noaa.yaml` loaded, install directory `${HOME}/pw/software` (the fallback branch). On gcpsmall the saved credentials belong to the activate identity, not `noaa`, so they did not qualify and the run warned that collection would stop after it — the pin working as intended off-platform |

Manual: **cancel during start-up** (`immense-lynx`, gcpsmall, cancelled while the
dashboard ran its first sweep): run `canceled`, no process, no endpoint, no skip file.
**Address held by something else** (`pleasant-shad`, a throwaway endpoint serving an empty
directory at `status-alvaro-probe`): the run ended in `error` with the start script's
explanation, the other endpoint untouched, nothing left on the workspace. (Since
2026-10-02 the run falls back to an assigned address instead, as the source did; these
results predate the fixed name and need re-running on `status-monitor`.)

Not exercised: the `activate.hpc.mil` and `noaa.parallel.works` platforms themselves (the
HPCMP scrape, the NOAA identity with saved credentials, the shared install trees and their
`existing`-only paths), a platform that refuses the subdomain (covered by
`test_start_template.py`), and a fleet large enough to test the 900 s budget.

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
- The ray-cluster entries (cluster and Add Worker) pin `parallelworks/ray-cluster`'s
  `workflow.yaml` / `add_worker.yaml` → `workflows/ray-cluster/yamls/<variant>.yaml` /
  `<variant>_add_worker.yaml` here (`hsp` on `activate.hpc.mil`, `noaa` on
  `noaa.parallel.works`, `general` elsewhere; thumbnail `workflows/ray-cluster/thumbnails/ray-cluster.png`).

- The burst-render-demo entry pins `parallelworks/burst-render-demo`'s `workflow.yaml` →
  `workflows/burst-render-demo/yamls/<variant>.yaml` here (`hsp` on `activate.hpc.mil`,
  `general` elsewhere; thumbnail `workflows/burst-render-demo/thumbnails/burst-render-demo.png`).
  The YAMLs and the remote-site clone reference branch `burst-render-demo` until the
  branch lands on canary (`branch:` in the checkout and `REPO_BRANCH` in the `render` job).

- The HPC Status entries (the source's deployment guide names `hpcmp_status`) pin
  `parallelworks/hpc_status`'s `workflow.yaml`, `yamls/hsp.yaml` or `yamls/rdhpcs.yaml` →
  `workflows/hpc_status/yamls/{general,hsp,noaa}.yaml` here (`hsp` on `activate.hpc.mil`,
  `noaa` on `noaa.parallel.works`, `general` elsewhere; thumbnails
  `workflows/hpc_status/thumbnails/{hpc-status,hpcmp-status,rdhpcs-status}.png`).

- The marketplace item `app-testbed` (v1.0, `marketplace.app-testbed.v1.0` in accounts) pins
  `parallelworks/activate-app-testbed`'s `workflow.yaml`, `README.md` and `thumbnail.png` →
  `workflows/app-testbed/yamls/general.yaml`, `README.md` and `thumbnails/app-testbed.png`
  here (one variant for every platform).

- Any registration of `parallelworks/monte-carlo-pricing` (its `workflow.yaml`,
  `README.md`, `thumbnail.png`) → `workflows/monte-carlo-pricing/yamls/general.yaml`,
  `README.md` and `thumbnails/monte-carlo-pricing.png` here (one variant).

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

## 3dcs (2026-09-30)

`workflows/3dcs/` is the port of `parallelworks/dcs-workflow` (`honda-japan.yaml` at
`v4-dev`, registered on the platform as `3dcsv4`): the same job graph (workspace
balance check, login-node preprocessing, a 40-wide guarded worker matrix through
`script_submitter`, merge, end-time estimate, usage metering), with the runtime files
under `app/`, the `inputs.sh`/`controller.sh` contract, and `cluster`/`service` input
groups. The behavior changes made in the port are listed in
[workflows/3dcs/README.md](workflows/3dcs/README.md) ("Provenance"). Left behind in
`dcs-workflow`: `honda-us.yaml` (the pre-v4 `main.sh` design for the `honda-us` metering
user) and `plot-usage/` (the usage-plotting workflow that runs on the metering server).

## probe (2026-10-05, from parallelworks/workflow-tester-tool)

`workflows/probe/` is PROBE, moved from `parallelworks/workflow-tester-tool@dev`
(a9a474d), renamed `parallelworks/probe-tests-activate-parallel-works` right after the move.
That repository keeps only the test definitions for `activate.parallel.works`
(`tests/<platform>/<user>/<workflow_name>/<name>.json`) and the two GitHub actions that
deploy these YAMLs from here; the runner, the dashboards and the workflows live here.

| workflow-tester-tool | here |
|---|---|
| `workflow/workflow.yaml` (the dashboards) | `workflows/probe/yamls/general.yaml` |
| `workflow/run-tests.yaml` | `workflows/probe/yamls/general_run_tests.yaml` |
| `probe/`, `web/` | `workflows/probe/app/probe/`, `workflows/probe/app/web/` (the sparse-checkout subtree) |
| `selftest/` | `workflows/probe/selftest/` (`PYTHONPATH=app`) |
| `tools/import_workflow_tests.py` | `workflows/probe/scripts/import_workflow_tests.py` |
| `thumbnail.png` | `workflows/probe/thumbnails/probe.png` |
| `README.md`, `DEVELOPER.md` | `workflows/probe/README.md`, `workflows/probe/DEVELOPER.md` |
| `tests/`, `.github/workflows/` | stay in workflow-tester-tool, now probe-tests-activate-parallel-works |

Changes made in the move: the YAMLs check out `workflows/probe/app` from this repository
at `canary` like every other workflow (the `code` input group that chose the code's
repository and branch is gone); the host input moved from `resource` to
`cluster.resource`; the `tests` and `results` inputs get their defaults applied in the
steps, since a CLI run leaves omitted inputs `undefined`. The end-to-end tests of PROBE's
own YAMLs are under `workflows/probe/tests/`; the dashboards test fills its API key from
the environment through the runner's new `_test.secrets` key.

## marimo and h2o (2026-10-06, from interactive_session's legacy generation)

`workflows/marimo/` and `workflows/h2o/` are the endpoint-pattern ports of the
session-generation `marimo-host/` and `h2o-3/` of `interactive_session` (their v3
scripts and `workflow/yamls/<name>/{general,hsp,noaa}.yaml`), converted per
`.claude/skills/activate-workflows/references/session-to-endpoint-upgrade.md`. The
`-host`/`-3` suffixes are dropped like the other renames; the endpoint names are
`marimo-<run-slug>` and `h2o-<run-slug>`.

| interactive_session | here |
|---|---|
| `marimo-host/controller-v3.sh`, `start-template-v3.sh` | `workflows/marimo/app/controller.sh`, `start-template.sh` (Miniforge + conda-forge through `tools/utils/miniforge.sh` instead of Miniconda; `marimo edit`/`run` under `pw endpoints run` on the loopback with `--headless --no-token`) |
| `marimo-host/nov2025.yaml` | replaced by `workflows/marimo/app/marimo0.25.1-python3.14.7.yaml`, the export of the first tested install, bootstrapped with the Miniforge release it came from (`MINIFORGE_URL`, new in `tools/utils/miniforge.sh`) |
| `marimo-host/kill-template.sh`, `transfer_files.sh`, Juice blocks | left behind (the generic cleanup trap, `parallelworks/checkout`, and nothing selected Juice) |
| `h2o-3/controller-v3.sh`, `start-template-v3.sh` | `workflows/h2o/app/controller.sh`, `start-template.sh` (the zip is unpacked wherever its `h2o.jar` is; a Temurin 17 JRE is downloaded when no `java` is on the PATH; H2O binds `-ip`/`-web_ip` to the loopback with a per-run cloud name; `--slug flow/index.html`) |
| `workflow/yamls/{marimo-host,h2o-3}/*.yaml` | `workflows/{marimo,h2o}/yamls/{general,hsp,noaa}.yaml`: the `cluster`/`service` groups of the jupyterlab variants; h2o noaa resolves the shared per-cluster install directory like webshell/openvscode noaa |

Form changes: marimo's `script` also accepts a directory (marimo's home page there) or
a new `.py`; the default marimo installation is the pinned environment, `latest` and a
pasted YAML stay; the noaa form keeps jupyterlab's `use_conda`/`install_command` route
(`pip install marimo` with the system `python` module) for the on-premise clusters. h2o
gained optional `jvm_args` and `load_env` (e.g. `module load java`) inputs and defaults
to the latest stable release (3.46.0.12). Tests: `workflows/{marimo,h2o}/tests/`, all
variants exercised on `pw://alvaro/gcpsmall` (the `existing`-only form fields of hsp and
noaa cannot be exercised from a cloud cluster).

## benchmarks (from parallelworks/benchmarks)

Migrated 2026-10-06 from `parallelworks/benchmarks@main` (2d90518), the cluster
benchmark demo: one of six benchmarks (`ibm-mpi1-all-to-all`, `ping-pong`,
`ior-standard`, `ior-minimal`, `mdtest-standard`, `mdtest-minimal`) run as a SLURM
job, with the output streamed back to the user container. The source predated the
shared submitter: a `workflow-utils` resource wrapper produced the SLURM header, the
YAML's own jobs ran `sbatch`, polled `squeue`/`sacct` and tailed a log the benchmark
scripts pushed over ssh to `usercontainer`. Here it is the repository's batch shape
(`activate-batch`, `openfoam-naca`): preprocessing → `script_submitter` → a results
job.

| Old | New |
|---|---|
| `workflow.yaml` (jobs `validate_resource`, `submit_benchmark`, `wait_job`, `stream`) | `yamls/general.yaml` (`preprocessing`, `benchmark` = `script_submitter/v3.6/general.yaml`, `results`) |
| `benchmarks/<name>/main.sh` × 6 (header + inputs + script concatenated per run, rsynced to the cluster) | `app/run-template.sh`, one script with the benchmark as a `case`; `app/install-mpi.sh`, `app/install-benchmark.sh` for the one-time setup on the login node |
| `benchmarks/utils/plot-imb-mpi-benchmark.py` (pandas + plotly HTML, shown through a v2 `/me/3001/api/v1/display/` iframe) | `app/summarize.py` (standard library): CSV tables, `::notice` headline, `KEY=value` outputs |
| form: `benchmark` dropdown of six, `pwrl_host` group with `_sch__dd_*` directive fields, `benchmark_root_dir`, `with_lustre`, `spack_install_intel_mpi`, `load_mpi` | `cluster` (resource, scheduler, `nodes`, `ntasks_per_node`, slurm, pbs), `benchmark` (`name` of four, `imb_args`, `preset` standard/minimal/custom, `ior_args`, `mdtest_args`, `io_dir`), `software` (`mpi` auto/conda-forge/commands, `mpi_load`, `install_dir`) |
| `apirun/` (a `run_workflow.py` API client for a different demo) | left behind |
| `benchmark.png` (a 120 px plotly screenshot) | replaced: `thumbnails/benchmarks.svg` (the drawing: a bandwidth curve over two nodes exchanging a ping-pong) rendered to `thumbnails/benchmarks.png` at 120 px like the other thumbnails |

**Code changes beyond the paths:**

- **The MPI.** Every run cloned Spack into its job directory and installed
  `intel-oneapi-mpi intel-oneapi-compilers` (30+ minutes, never reused), unless the user
  typed a load command. Now `install-mpi.sh` takes the MPI already on PATH, else a system
  module (`mpi/openmpi-x86_64`, `mpi/mpich-x86_64`, `openmpi`, `mpich`), else installs
  Open MPI from conda-forge once under `<install dir>/benchmarks/miniforge`; the form can
  force the conda-forge install or give commands. The choice is a `::notice` and the job
  log's `MPI :` line.
- **The builds are cached per MPI** under `<install dir>/benchmarks/<mpi>/` (the MPI's
  directory with `/`→`_`), with `MPI.txt` recording the compiler and MPI, under a lock.
  IMB-MPI1 is built from source (the source relied on Intel MPI shipping the binary;
  `-DOMPI_SKIP_MPICXX`, and `-Wno-error=template-id-cdtor` for GCC ≥ 14, against the
  Makefile's `-Werror`); an `IMB-MPI1` on PATH is used instead. IOR 4.0.0 comes from the
  release tarball (`configure` included: no `./bootstrap`, no `sudo yum install
  automake`), with `-std=gnu17` for GCC 15; `--with-lustre` is auto-detected rather than
  a form toggle whose default `true` fails `configure` without the Lustre headers.
- **Rank layout from the allocation.** The source ran `mpirun -ppn $SLURM_CPUS_ON_NODE`
  (an Intel MPI flag) and the form's `--ntasks-per-node`/`--nodes` directive fields.
  The form asks for `nodes` and `ntasks_per_node`, written ahead of the user's directives
  (so a repeated directive wins), and the script takes `SLURM_NTASKS`/`SLURM_JOB_NUM_NODES`
  (PBS: the node file) to launch `mpirun -np N`; `MPIRUN` in the environment commands
  replaces the launcher; Open MPI under PBS gets `--hostfile $PBS_NODEFILE`.
- **PingPong across nodes.** With 2+ nodes IMB-MPI1 gets `-map <ppn>x<nodes>`, which
  numbers the ranks so that the pair sits on two nodes; the source measured whatever two
  ranks came first (both on the first node).
- **Presets.** `ior-minimal`/`ior-standard`/`mdtest-minimal`/`mdtest-standard` became
  the `minimal`/`standard` presets of `ior` and `mdtest`, plus `custom` arguments; IOR
  reads back as well as writes (`-w -r`); `-o`/`-d` point into `<io_dir>/<run slug>`
  (default `io/` under the job directory), removed afterwards and by `cancel.sh` on a
  cancel; the source left `${benchmark_root_dir}/pw/jobs/<workflow>/<n>/` behind.
- **Exit status and results.** The submitter does not forward the script's status, so
  `benchmark.sh` records it in `benchmark.exit` and the results job fails the run with
  the tail of the output when it is not `0` (the source's `wait_job` ended `completed`
  whatever the job did). `summarize.py` writes `results/<benchmark>.csv` and the
  headline figures as outputs (`latency_usec`, `bandwidth_mbytes_per_sec`,
  `write_mib_per_sec_mean`, `file_creation_ops_per_sec_mean`, …).

**Judgment calls:** the form's groups are `cluster`, `benchmark`, `software`
(`benchmark` where the other workflows have `service`, since it is the benchmark); the
`--with-lustre` toggle is gone rather than kept default-off; the plotly HTML page is
gone rather than ported (no display route for it; the CSV is the plottable artifact);
`scheduler` defaults to **Yes**, unlike the other workflows, because the compute nodes
are what a benchmark measures; the `apirun/` API-client example is not migrated (it
drove a different demo workflow). The shared `tools/utils/prepare-env.sh` notice now
names the installer it runs instead of saying "conda-forge install".

**Tests (2026-10-06, `pw://alvaro/gcpsmall`, branch `benchmarks`; rows in
`workflows/benchmarks/tests/general/*.csv`):** all five pass with `cleanup=ok`.

| Test | Result |
|---|---|
| `gcpsmall-pingpong-login` (login node, 2 ranks, `auto` MPI) | PASS `saving-boxer` (cold: the system module `mpi/openmpi-x86_64` was picked and IMB-MPI1 built, 38 s), re-run `liberal-mutt` (warm, 32 s): 0.18 µs, 9.4 GB/s on one node |
| `gcpsmall-pingpong-2nodes` (2 nodes × 2 ranks) | PASS `informed-hedgehog` (3 min, nodes powering up): `-map 2x2` put the pair on two nodes, 20.9 µs and 2.6 GB/s |
| `gcpsmall-ior-minimal` (1 node × 4 ranks, `io/` under the job directory) | PASS `national-pelican` (cold: IOR built, 47 s), re-run `cuddly-crawdad` (31 s); the I/O directory was removed |
| `gcpsmall-mdtest-custom` (custom arguments, `io_dir` `${HOME}/pw/benchmarks-io`) | PASS `ready-goldfish` (63 s) |
| `gcpsmall-alltoall-conda` (`conda-forge` MPI, 2 nodes × 4 ranks, `-npmin 8`) | PASS `daring-clam` (78 s cold: Miniforge + Open MPI 5.0.11 + compilers installed and IMB-MPI1 built with GCC 15 in about a minute; 8 ranks across the two nodes) |

**Cancel mid-benchmark** (`unbiased-vervet`, then `square-egret` after the fix; IOR
`standard`, 1 node × 4 ranks): `pw workflows runs cancel` while `ior` ran on the compute
node left `squeue` empty (job `CANCELLED`), no `ior`/`mpirun` process on the node and no
I/O directory. The first attempt recorded `benchmark.exit` = `0`: bash ran the exit trap
with the status of the last command completed before the killed pipeline. The script now
traps HUP/INT/TERM (`exit 129/130/143`) and removes the I/O directory from the exit trap,
with `cancel.sh` as the fallback for a SIGKILL; `square-egret` recorded `143`
(`references/pitfalls.md`). Not exercised: PBS, `MPIRUN` overrides, an Intel MPI with
its own `IMB-MPI1`, the `commands` MPI mode (its path is `prepare-env.sh`'s, shared with
`openfoam-naca`).

**Variants and failure paths (2026-10-07).** `yamls/hsp.yaml` and `yamls/noaa.yaml`
follow `openfoam-naca`'s: the resource is the top-level input and the job goes through
the `hsp`/`noaa` submitter with their `account`/`qos` (and hsp's `node_type`, `pbs.account`)
fields, shown for `existing` resources. The layout differs per submitter: `hsp` writes
`--nodes` (and `--cpus-per-task=1`) before the form's directives, so the workflow's
`--nodes`/`--ntasks-per-node` directives still win; `noaa` writes `--ntasks`/`--nodes`
after them on `existing` resources, so the layout also goes through its `ntasks`
(`nodes * ntasks_per_node`, an expression) and `nodes` inputs. `hsp.yaml` passes
`define_cleanup_script`/`cleanup_script_path` although that form does not declare them
(an undeclared input reaches the submitter's expressions as passed); on a SLURM job there
the cleanup cannot reach the node anyway because that submitter writes `HOSTNAME` after
the script, so a cancelled hsp job cleans up through `benchmark.sh`'s exit trap. `noaa.yaml`
takes the install directory from the cluster's shared software tree when none is given and
the account can write there (`/contrib/pw`, `/usw/rdhpcs/software/pw`), like `openfoam-naca`.
The failure-path tests (`_test.expect: error`): `fail-mpi-commands` (the `commands` MPI
mode with a module that does not exist fails in `prepare-env.sh` before any build),
`fail-ior-bad-args` (IOR rejects `--no-such-option`, exit 1, the run fails with the
status and the output tail; also under `hsp/` and `noaa/`) and `fail-bad-ranks`
(`ntasks_per_node: 0` fails the input check). A first attempt at an "empty custom
arguments" test could not fail: the platform default-fills an explicit `""` for a group
item (`references/pitfalls.md`), so that check is unreachable from the API and the test was
dropped. The README no longer says the workflow registers no endpoint (reviewer feedback).

**Tests of the variants and failure paths (2026-10-07, `pw://alvaro/gcpsmall`, which had
been recreated overnight, so every build started cold again):**

| Test | Result |
|---|---|
| `hsp/gcpsmall-pingpong-login` | PASS `unique-grubworm` (cold, IMB rebuilt, 2 min) |
| `hsp/gcpsmall-ior-minimal` | PASS `amused-leech` (27 min: the reused cloud node sat `NOT_RESPONDING+POWERING_UP` for 25 min before SLURM got it back; IOR itself took 12 s) |
| `hsp/fail-ior-bad-args` | PASS `wired-boar` (run `error` in 38 s: "exited with status 1" and IOR's usage in the tail) |
| `noaa/gcpsmall-pingpong-login` | PASS `knowing-serval` (48 s) |
| `noaa/gcpsmall-ior-minimal` | PASS `assuring-sole` (32 s); `ntasks: nodes * ntasks_per_node` verified separately with a throwaway workflow (`2 * 4` rendered `8`, run `on-crappie`) because the job directory no longer keeps rendered step scripts |
| `noaa/fail-ior-bad-args` | PASS `major-bat` (run `error` in 32 s) |
| `general/fail-mpi-commands` | PASS `full-osprey` (run `error` in 43 s at *Prepare the MPI Environment*: "does not provide mpicc mpirun", with the module error in the annotation) |
| `general/fail-ior-bad-args` | PASS `pro-opossum` (run `error` in 6 min, cold node) |
| `general/fail-bad-ranks` | PASS `summary-bluegill` (run `error` in 16 s at *Create Inputs*) |
| `general/fail-custom-empty` (withdrawn) | FAIL `obliging-sheep`: the run completed, see above |

**Cancel, revisited.** The hsp cancel test (`helped-grub`) showed that the signal traps alone
did not hold: `benchmark.exit` was never written and 4.4 GB of IOR files stayed behind.
IOR's output had the ranks finishing their write phase 54 s after the cancel, past
SLURM's 30 s `KillWait`: bash defers a trap until the foreground pipeline ends, so SIGKILL
took it before any trap ran. Three changes, each checked with another cancel:
`open-labrador` (the pipeline now runs in the background under `wait`, where bash runs the
trap at once: exit `143` recorded, but `rm -rf` raced ranks still creating files),
`alert-cow` (the trap also killed the benchmark's process group: still racing, the job
lived 52 s, because `mpirun` gives each local rank a process group of its own, verified
with `ps -o pid,pgid`), `ruling-fox` (the trap kills the process tree captured before the
first signal: the ranks died at once, the job ended in 20 s, exit `143`; one killed rank
stayed a zombie for two minutes draining 1.1 GB of dirty NFS pages, its file an `.nfs…`
placeholder, so the directory removal now retries for up to two minutes and the README
says a cancel on NFS can leave the empty per-run directory). The general variant's cancel
test with the final script, `proper-jaguar`, ended clean: exit `143`, no SLURM job, no
I/O directory (the retries outlasted the drain), after a 5-minute hang of the submitter's
cleanup whose `ssh` to the fresh node 0002 was being refused (`Connection closed by … port
22`, the node's sshd, not the workflow). On hsp the submitter's cleanup cannot run
`cancel.sh` on the node (`HOSTNAME` is written after the script), so the trap is the only
cleanup there; on general the cleanup ran it, racing the same ranks. With the final
script, `general/gcpsmall-ior-minimal` (`literate-sheep`) and `general/fail-ior-bad-args`
(`direct-rhino`) pass again: the success path through `wait` and the failure path's exit
status from the subshell. The checkouts of the three YAMLs point at `canary` for the merge.

## mlflow on compute clusters (2026-10-07, from interactive_session's legacy generation)

`workflows/mlflow/` was k8s-only (above); the compute-cluster side is the
endpoint-pattern port of `interactive_session`'s `mlflow/start-template-v3.sh` and
`workflow/yamls/mlflow/{general,general_k8s}.yaml`, rewritten on the marimo port's
shape rather than converted line by line. The endpoint name stays `mlflow-<run-slug>`
on both paths.

| interactive_session | here |
|---|---|
| `mlflow/start-template-v3.sh` (`eval` of a pip install or load command, then `mlflow server --port ${service_port} --host ${HOSTNAME} ${additional_flags}` with `./mlruns` wherever the job ran) | `workflows/mlflow/app/controller.sh` (Miniforge + conda-forge `mlflow` through `tools/utils/miniforge.sh`, pinned in `app/mlflow3.16.1-python3.14.7.yaml` and bootstrapped with the Miniforge release it was exported from; `latest`, a pasted YAML, a load command, or noaa's `install_command`) and `start-template.sh` (`mlflow server` behind `pw endpoints run` with `--backend-store-uri`, `--artifacts-destination` and `--serve-artifacts` from the form, local stores created when missing) |
| form: `install_mlflow`, `mlflow_install_cmd`/`mlflow_load_cmd`, `port` (required, default 5000), `additional_flags` | `service`: `backend_store_uri` (default `sqlite:///${HOME}/mlflow/mlflow.db`), `artifacts_destination` (default `${HOME}/mlflow/artifacts`), optional `port`, `additional_flags`, and the marimo/jupyterlab installation group (`conda_install`, `install_instructions`, `load_env`, ...) |
| `workflow/yamls/mlflow/general_k8s.yaml` (`targetType` dropdown: compute cluster or Kubernetes, `k8s.cluster` input) | `yamls/general_k8s.yaml`: the jupyterlab hybrid shape (`resource: compute-resources`, every job gated on `inputs.resource.type`) |

The server binds every interface (the legacy `--host ${HOSTNAME}`) because jobs on the
cluster log to it directly; `pw endpoints run` still picks the local port unless the
form fixes one, so the launcher records `http://<node>:<port>` in the job directory's
`tracking_uri` file. The Kubernetes path (`k8s.yaml` and the hybrid) now runs
`mlflow server` with the sqlite store and the artifacts on the PVC mount instead of
`mlflow ui` in the container's working directory, and defaults to the official
`ghcr.io/mlflow/mlflow:v3.17.0` image (the `ubuntu/mlflow:2.1.1_1.0-22.04` default
dated from January 2023; MLflow 3 clients need a MLflow 3 server for traces and logged
models). Two MLflow 3 behaviours shaped the launch: the server rejects a `Host` header
or an `Origin` outside its allow-lists with 403 (the proxied endpoint host is outside
them), so the cluster launcher composes `--allowed-hosts`/`--cors-allowed-origins` from
`PW_ENDPOINT_HOST` and the node's names and the containers open both lists; and its
defaults, four 250 MB uvicorn workers plus a seven-process job runner (2.5 GB PSS
measured), were `OOMKilled` at the k8s forms' 1Gi limit, so server-side job execution
(GenAI evaluation jobs) is a form option that is off by default on every variant and the
Kubernetes form adds a worker count (2) with 1Gi/2Gi memory defaults. Tests:
`workflows/mlflow/tests/`, the compute-cluster variants on `pw://alvaro/gcpsmall` (login
node and SLURM job; the `existing`-only form fields of hsp and noaa cannot be exercised
from a cloud cluster), the Kubernetes lanes on `k3sgpu`.

## filebrowser (2026-10-07, from parallelworks/filebrowser_workflow)

`workflows/filebrowser/` is the endpoint-pattern port of `parallelworks/filebrowser_workflow@canary`
(61d70c2): [File Browser](https://filebrowser.org) (`filebrowser/filebrowser:v2.50.0`) with
Docker Compose. The source served it through a platform session (`sessions:` block,
`pw agent open-port`, `parallelworks/update-session`, the run alive on `docker compose up`).

| Old | New |
|---|---|
| `workflow.yaml` (jobs `prep`, `filebrowser`, `create_session`; inputs `resource`, `rundir`) | `yamls/general.yaml` (preprocessing → `script_submitter` → `wait_for_endpoint`; `open-notebook`'s `cluster`/`service` groups) |
| compose file and `docker compose up` inline in the YAML | `app/controller.sh` (mounted directories), `app/start-template.sh` (Docker detection and pull as `open-notebook`, database bootstrap, compose stack behind `pw endpoints run`, `cancel.sh` = `compose down`) |
| `README.md` | rewritten: the source's text described the PHP "FileBrowser", a different project |
| `thumbnail.png` | `thumbnails/filebrowser.png` |

Changes beyond the paths:

- `FB_BASE_URL` is `PW_ENDPOINT_PATH` without its trailing slash: empty on a subdomain
  endpoint, the `/me/session/<user>/<name>` prefix on a path-based one.
- The container runs as the workflow user (`user: <uid>:<gid>`) instead of uid 1000; the
  source's `chown 1000:1000` needed root.
- Authentication is a form choice applied on every start: *Platform login only*
  (`noauth`, default) or *File Browser users* (`json`) with an optional admin password.
  `--noauth`/`--password` only act when the database is created, so the launcher uses
  the CLI (`config init`/`users add` the first time, `config set`/`users update`
  afterwards).
- The served directory (`<rundir>/data` in the source) is the visible **Root Directory**
  with the same default; the image is an input.

`general` only, as `open-notebook` (no Docker on the HPCMP and NOAA systems). No
`restart:` policy: a File Browser that dies ends `compose logs -f`, the wrapper and the job.

**Tests (2026-10-07, `pw://alvaro/gcpsmall`, branch `filebrowser`; rows in
`workflows/filebrowser/tests/general/*.csv`):**

| Test | Result |
|---|---|
| `gcp-controller` (login node, form defaults) | PASS `real-oyster` (cold, 37 s; recorded `leftover:proc:filebrowser` because the test's `leftover_commands` snippet contained the pattern verbatim, see `tools/tests/README.md`), `amusing-badger` (warm, 37 s, `cleanup=ok`) |
| `gcp-controller-users` (File Browser users with a password, root `${HOME}`) | PASS `crack-duckling` (38 s: existing database switched to `json`, password updated; its log showed the password once, from a test under xtrace, fixed), `profound-mako` (32 s, kept for the manual checks) |
| `gcp-compute` (SLURM job, `compute` partition) | PASS `distinct-cardinal` (163 s, node powering up) |

Manual on `profound-mako`: anonymous GET → `307`; with the platform token `/` → `200`,
`POST /api/login` → `200`/`403` with the right/wrong password, `/api/resources/` → `401`
without File Browser's token and `200` with it; `pw endpoints delete` removed container
and network, no process left. Cancel 11 s after launch (`novel-bass`, endpoint just
registered): run `canceled`, endpoint deleted by the submitter's cleanup, container and
network removed, no skip file. Not exercised: PBS, a path-based endpoint, a host without
`sudo`. The checkout points at `canary` for the merge.

## metabase (2026-10-07, from interactive_session's legacy generation)

`workflows/metabase/` is the endpoint-pattern port of `interactive_session`'s
`workflow/yamls/metabase/general_k8s.yaml` (hybrid: `targetType` dropdown, compute cluster
or Kubernetes) and `metabase/start-template-v3.sh`, rewritten on the filebrowser (Docker
Compose) and mlflow (hybrid k8s) shapes. The endpoint is `metabase-<run-slug>` on both paths.

| interactive_session | here |
|---|---|
| `metabase/start-template-v3.sh`: the nginx-docker wrapper on `service_port` proxying `127.0.0.1:3000`, then `docker run --network=host` of `${service_image}` named `metabase` with `~/metabase-data:/metabase-data` (one instance per node) | `app/start-template.sh`: the image in a Docker Compose project named after the run, port `${PORT}:3000` behind `pw endpoints run`, data directory from the form, `MUID`/`MGID` set to the workflow user, optional `MB_*` variables from an editor input (`env_file`); `app/controller.sh` creates the data directory |
| k8s Deployment with code-server's `args` (`--auth password --bind-addr 0.0.0.0:8080`), `containerPort: 80`, a `-lb` Service and `parallelworks/update-session` | the mlflow hybrid's k8s jobs: `MB_JETTY_PORT`/`MB_DB_FILE`/`MB_PLUGINS_DIR` on the PVC mount, `JAVA_OPTS=-XX:MaxRAMPercentage=75`, the `pw-endpoint` sidecar, no Service |
| form: `pwrl_host`, `service.image` (`metabase/metabase`), `k8s`, `service_k8s.image` | `resource`/`cluster`/`service` (`data_dir`, `image` pinned to `metabase/metabase:v0.64.1`, `env`) and `k8s`/`service_k8s` (`image`, `image_port` 3000); memory defaults 1Gi/2Gi (were 512Mi/1Gi) |
| `workflow/readmes/metabase/general_k8s.md`, `workflow/thumbnails/metabase.png` | `README.md` (rewritten), `thumbnails/metabase.png` |

`general.yaml` (compute cluster only) is the hybrid's compute path on the standard
`cluster.resource` form, as every other workflow here offers. The health probe is
`/api/health` with a 600 s budget and `healthy: 2*|3*|500`: Metabase (v0.64.1 and
v0.63.19.3 alike, before and after its setup wizard) answers HTTP 500 `Assert failed:
(m/validate ProviderSetup config)` to any request carrying an `Authorization: Bearer`
header, on every route, and the probe carries the run's key. It does so from the second
its log says `Metabase Initialization COMPLETE` and answers 503 before (verified on both
lanes), so 500 is the ready signal; the tunnel has no option to strip the header.
Metabase has no URL-prefix mode, so only subdomain endpoints work.

**Tests (2026-10-07, branch `metabase`; rows in `workflows/metabase/tests/*/*.csv`):**

| Test | Result |
|---|---|
| `general/gcp-controller` (login node of `pw://alvaro/gcpsmall`, form defaults) | FAIL `credible-wildcat` with the plain `2*\|3*` probe (500 on `/api/health` for the whole 600 s budget; the submitter's cleanup removed the container, no skip file), then PASS `usable-tahr` (68 s, `cleanup=ok`) with `healthy: 2*\|3*\|500` |
| `general_k8s/gcp-controller` (the hybrid's compute lane, same node) | PASS `present-stinkbug` (69 s) |
| `general/gcp-compute` (SLURM job, `compute` partition) | PASS `legal-feline` (242 s, node powering up) |
| `general_k8s/k3sgpu` (Kubernetes lane, namespace `alvarok8s`) | FAIL `wealthy-ibex` with the plain probe (same 500; the Deployment, Secret and PVC were deleted by the cleanups), then PASS `driven-mongrel` (34 s to the endpoint answering; cancel removed every object within the runner's wait) |

Cancel 24 s after launch (`liberal-cricket`, endpoint registered, Metabase still
initializing): run `canceled`, endpoint deleted by the submitter's cleanup, container and
network removed by `cancel.sh` (`compose down`), no skip file, no process left. Not
exercised: PBS, an existing PVC, a host without `sudo`. The checkout points at `canary`
for the merge.

## app-testbed (2026-10-07, from parallelworks/activate-app-testbed)

`workflows/app-testbed/` is the multi-site client-server testbed from
`parallelworks/activate-app-testbed@main` (9100bf7): a placeholder server behind an
endpoint at a fixed address, workers dispatched to other resources over `pw ssh` through
SSH tunnels, on login nodes or as SLURM/PBS jobs. The form and the run's behaviour are
unchanged; the source was one self-contained YAML with the Python embedded in heredocs.

| Old | New |
|---|---|
| `workflow.yaml` (jobs `setup`, `start_server`, `expose_session`, `dispatch_workers`) | `yamls/general.yaml` (`preprocessing`, `start_server`, `wait_for_endpoint`, `dispatch_workers`); the form is verbatim |
| `server.py`/`worker.py` embedded in heredocs, re-embedded by `scripts/sync-app.py` | `app/server.py`, `app/worker.py` checked out; the dispatcher ships `worker.py` to each site with the bootstrap (base64 over `pw ssh`), so sites still need no GitHub access; no sync script |
| `setup` job | `app/controller.sh` (workdir, plus a check for `python3`, `curl`, `setsid`, `pw`) |
| bare `server.py` + `pw endpoints http PORT --subdomain S --name S` + a `session-watch` loop | `app/start-server.sh`: one detached `pw endpoints run --port PORT --subdomain S --name S -- sh -c "exec python3 server.py {port} >> server.log"`; deleting the endpoint takes the server down, as the watcher did. Restart deletes the endpoint (and kills a bare server, `pw endpoints http` or watcher left by the old generation) |
| URL grep in `expose_session` | the shared `wait_for_endpoint` (fixed name, probe with the run's key) + a `Publish URL` step with the same `URL` output |
| the inline dispatch step and its `BOOT_B64` bootstrap heredoc | `app/dispatch_workers.sh`, `app/worker-bootstrap.sh`, verbatim apart from their heads (`inputs.sh`, `workers.json`, files from `app/`) |
| `scripts/programmatic/`, `scripts/manual/` (+ two READMEs) | `scripts/{launch-worker.py,run-worker.sh,worker-inputs.json}`; the READMEs folded into the workflow README |
| `thumbnail.png` | `thumbnails/app-testbed.png` |

**Judgment calls:** no script submitter (the server only runs on the login node and must
outlive the run, as `dakota-openfoam`'s Pareto server; `wait_for_endpoint` without a skip
file); the fixed name `apptest` is kept and a running instance is reused, only **Restart
server** frees it (`hpc_status` frees its name every run); no `!completed` handler, since
the source left the server up after a failed or cancelled run and workers-only runs rely
on it; the form keeps its own groups (`server`, `services`, `app`, `workers`), which the
launcher scripts and saved inputs address; one `general.yaml` (the form carries the
account/QoS and PBS fields; there is no submitter variant to pick).

**Tests (2026-10-07, `pw://alvaro/gcpsmall`, branch `activate-app-testbed`; rows in
`workflows/app-testbed/tests/general/*.csv`).** Every test sets `_test.endpoint_name:
apptest`; pass = the run completed (`wait_for_endpoint` saw `HTTP 200`, the workers
connected) and `apptest` was listed; teardown = `pw endpoints delete apptest`, after which
the server was gone at once and each worker exited at its next keep-alive ping (~30 s).

| Test | Result |
|---|---|
| `gcp-server-gcp-login-worker` (server and worker on the gcpsmall login node) | PASS `witty-honeybee` (37 s). PASS `smart-flounder` (22 s) against a kept server: `server already running ... behind endpoint apptest`, `worker already running and connected` |
| `gcp-server-remote-login-worker` (port 8097, **Restart server** on; worker on the `a30gpuserver` login node) | PASS `awake-krill` (27 s, row lost with its session): the restart deleted the kept endpoint and started on 8097; the site opened `ssh -i ~/.ssh/pwcli -o ProxyCommand="pw ssh --proxy-command %h" -N -L 8097:localhost:8097` and connected. PASS `popular-cat` (53 s), reusing that tunnel |
| `remote-server-gcp-slurm-worker` (server on `a30gpuserver`, SLURM worker on gcpsmall, `compute`) | FAIL `composed-kite` on port 8097: the previous test's tunnel held that port on `a30gpuserver` (`Address already in use`); the test moved to 8098 and `start-server.sh` now fails within seconds when the wrapper is gone. PASS `precise-lobster` (178 s): tunnel bound to the login node's `10.128.0.19:8098`, job 67 `CONFIGURING` → `RUNNING`, the compute node connected; after the delete the job ended within two minutes |

A workers-only run (`wired-baboon`, `deploy_server: false` against a kept server)
skipped `start_server` and `wait_for_endpoint` and found the worker connected. Not
exercised: PBS, `pw-forward`/`ssh` set explicitly, key adoption from the server host, a
scheduled worker on the server host's own cluster (the placeholder binds loopback), and
the launcher scripts. The tunnels the tests left were removed by hand.

## monte-carlo-pricing (2026-10-09, from parallelworks/monte-carlo-pricing)

`workflows/monte-carlo-pricing/` is the multi-site Monte Carlo option pricing demo from
`parallelworks/monte-carlo-pricing@main` (47d2df6): a FastAPI dashboard on one resource,
and geometric Brownian motion paths simulated in batches on N compute sites, which POST
each batch's mean, variance and payoff histogram back (through reverse SSH tunnels for
other resources); the dashboard merges them live. The source is a fork of the
burst-render-demo skeleton — `start_dashboard.sh` is byte-identical, and the dispatcher,
the jobs and the form groups are the same with tiles swapped for batches — so it is
migrated by the burst-render-demo recipe above, including the fixes the first HSP run
taught (JSON read from the environment, scripts shipped to remote sites instead of
cloned, the endpoint name built once). This section records what differs.

| Old | New |
|---|---|
| `scripts/dashboard.py`, `scripts/simulator.py`, `scripts/templates/index.html` | `app/…`, verbatim |
| `scripts/start_dashboard.sh`, install half | `app/controller.sh`: burst-render-demo's (shared `uv`, virtualenv at `${service_parent_install_dir}/monte-carlo-pricing/venv`, verified by importing the app), with `fastapi uvicorn websockets numpy` and a 3.9 minimum Python |
| `scripts/start_dashboard.sh`, launch half | `app/start-template.sh` (`pw endpoints run` + the `SESSION_PORT` launcher) |
| `scripts/setup.sh` (numpy via `pip --user`, else a venv in the job dir) | `app/setup_site.sh`, run on remote sites only |
| `scripts/dispatch_simulations.sh` | `app/dispatch_simulations.sh`: burst-render-demo's dispatcher (local mode for sites on the dashboard host's resource, `#SBATCH` directives to `srun`, `pipefail`, no `pkill` sweep, per-run remote work dir `~/pw/jobs/monte_carlo_remote/<run-slug>/`) with the simulation parameters |
| `scripts/run_simulation.sh` | `app/run_simulation.sh` (see below) |
| `workflow.yaml` (`sessions:`, jobs `checkout`, `start_dashboard`, `wait_for_dashboard`, `update_session`, `configure_simulation`, `dispatch_simulations`, `complete`) | `yamls/general.yaml`: `preprocessing` → `session_runner` (`script_submitter/v3.6/general.yaml`, login node) + `wait_for_endpoint` → `simulate` (configure, dispatch, summary) |
| checkout `parallelworks/monte-carlo-pricing@main`, sparse `scripts`; remote sites `git clone` it | `parallelworks/workflows@canary`, sparse `workflows/monte-carlo-pricing/app`; remote sites get `run_simulation.sh`, `simulator.py`, `setup_site.sh` tarred over the dispatcher's SSH connection |
| `scripts/generate_thumbnail.py`, `thumbnail.png` | `generate_thumbnail.py` (now writes `thumbnails/monte-carlo-pricing.png`; it regenerates the source thumbnail byte for byte), `thumbnails/monte-carlo-pricing.png` |

**What differs from burst-render-demo:**

- **numpy.** The renderer needs only the standard library; the simulator wants numpy
  (its pure Python fallback is ~20× slower: 1.7 s against 80 ms per 10,000-path batch
  on gcpsmall's login node). The dashboard's
  virtualenv carries numpy, and sites on the dashboard host's own resource run the
  simulator with it (`LOCAL_PYTHON`; compute nodes see it through the shared home). A
  remote site runs `setup_site.sh`, which takes the site's `python3` when it imports
  numpy and otherwise builds `~/pw/software/monte-carlo-pricing/site-venv` once (built
  beside the final path and renamed into place, so concurrent runs never see half an
  install); when numpy cannot be installed it warns and the fallback runs.
- **Python 3.9 on the dashboard host.** `dashboard.py` annotates a module-level
  `list[WebSocket]`, which Python 3.8 cannot evaluate, so the controller's minimum (below
  which `uv` installs 3.12) is 3.9 rather than burst-render-demo's 3.8.
  `python-multipart` is not installed: `/api/config` takes JSON, not a form.
- **Source bugs fixed.** A multi-node `srun` ran `run_simulation.sh` once per task on the
  same batch range, so every batch was simulated and posted once per node (same seeds,
  double-counted paths); the tasks now split the range by `SLURM_PROCID`, as
  burst-render-demo's tiles do. `setup.sh` fell back to a venv when `pip --user` failed
  but the simulator kept running the system `python3`, so that numpy was never used;
  `run_simulation.sh` now takes its interpreter from the dispatcher (`PYTHON_CMD`). A
  batch that never reached the dashboard was counted and ignored; it now fails its site.
- **The run checks its result.** The summary reads `/api/state`, prints the price, its
  standard error and 95% interval (plus the Black-Scholes reference and the distance to
  it for European options) and fails the run if the dashboard holds a different number
  of batches than planned. Sites that would get no batch (more sites than batches) are
  skipped instead of allocated.

**Form.** `simulation_settings` keeps every source field verbatim and gains the hidden
`name` (`monte-carlo`, the endpoint prefix) and `parent_install_dir`; `head` and
`targets` are burst-render-demo's `general` form (no `pbs` group or `is_disabled`
markers, **Schedule Job?** only for SLURM resources, account/QoS through the directives
editor). One variant: the source had a single `workflow.yaml`; `hsp`/`noaa` variants
can be derived the way burst-render-demo's were if the demo is offered there.

**Tests (2026-10-09, `pw://alvaro/gcpsmall`, branch `monte-carlo-pricing`; rows in
`workflows/monte-carlo-pricing/tests/general/*.csv`).** Pass = the run completed (its
`wait_for_endpoint` saw the endpoint answer, every site reported `COMPLETED` with 0
batch errors and the summary found all planned batches on the dashboard) and
`monte-carlo-<run-slug>` was listed; teardown = `pw endpoints delete`, after which no
dashboard, endpoint wrapper, dispatcher or simulator process and no SLURM job was left.

| Test | Result |
|---|---|
| `gcp-dashboard-gcp-login` (dashboard and one site on the gcpsmall login node, Asian call) | PASS `great-marmoset` (cold, 37 s: `uv` and the virtualenv with numpy built in ~15 s); 10 of 10 batches, 4 workers, price 5.7650 ± 0.0253 |
| `gcp-dashboard-gcp-login-gcp-compute` (two sites: the login node and a 2-node `srun --partition=compute`, multi-line directives, European call) | PASS `proven-seagull` (255 s, compute nodes powering up): `srun ... --nodes=2 --ntasks=2 --comment=monte-carlo-regression` (the `##SBATCH --exclusive` line dropped); task 0 on `-1-0001` ran batches 10–14, task 1 on `-1-0002` 15–19; 20 of 20 batches; price 10.4850 ± 0.0467 against Black-Scholes 10.4506 (0.7 standard errors) |
| `workspace-dashboard-gcp-compute` (dashboard on the user workspace, site gcpsmall over `pw ssh`, barrier at 130) | PASS `touched-jay` (53 s): SSH probe, reverse tunnel, scripts shipped to `~/pw/jobs/monte_carlo_remote/touched-jay/app/`, `site-venv` built with numpy 2.0.2, TCP proxy on the login node, `srun` on a compute node; 10 of 10 batches, price 3.5407 ± 0.0201 |

**Cancel mid-simulation** (`alert-humpback`, two sites as in the second test, 10M paths
in 2000 batches, one worker): with the dispatcher, the login-node `run_simulation.sh`,
both `srun` processes and a `simulator.py` alive in the dispatcher's process group and
SLURM job 24 running, `pw workflows runs cancel` left only the dashboard tree
(`pw endpoints run` + uvicorn, released by the skip file as designed), `squeue` empty
and the endpoint listed; `/api/state` held the 351 batches finished before the cancel,
and `pw endpoints delete` removed the rest.

Observed, not changed: **Worker Threads: Auto** counts the CPUs SLURM gives a task, one
by default, so a scheduled site runs one simulator per node unless the directives carry
`#SBATCH --cpus-per-task=<N>` (`nproc` under `srun` on gcpsmall: 1 by default, 4 with
`--cpus-per-task=4`, still 1 with `--exclusive`); the README says so. The dashboard merges
each batch's 50-bin payoff histogram by bin index while every batch picks its own bin
edges, so the histogram is approximate (the price and its interval are exact merges).
Not exercised: a PBS or SSH-mode remote site, a site without numpy access (the pure
Python fallback ran only in a local test), a dashboard host older than Python 3.9, and a
site whose login shell is tcsh.
