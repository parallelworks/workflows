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

## ray-cluster (from parallelworks/ray-cluster)

Migrated 2026-09-23 from `parallelworks/ray-cluster@main` (98bb3dd, 2026-07-22), a
multi-site Ray cluster: a Ray head + FastAPI dashboard on one resource, workers
dispatched to SLURM/PBS/SSH sites (same-resource sites via the local scheduler, other
resources over `pw ssh` tunnels). The source served its dashboard through a platform
**session** (`parallelworks/update-session`); it is a `pw` endpoint here (judgment call
1). The source repo checked out its own `scripts/` and the remote worker sites cloned it
again for `setup.sh`.

| Old | New |
|---|---|
| `scripts/*` (runtime) | `workflows/ray-cluster/app/*` (incl. `templates/index.html`) |
| `scripts/diagnose.sh`, `scripts/generate_thumbnail.py` (dev tools) | `workflows/ray-cluster/diagnose.sh`, `generate-thumbnail.py` (outside `app/`; thumbnail now written to `thumbnails/ray-cluster.png`) |
| `workflow.yaml` | `yamls/hsp.yaml` (the form already carried the HSP fields: SLURM account/QoS, `--constraint=mla` hint, PBS account) and `yamls/general.yaml` (those fields dropped; account/QoS go in the directives editor like every other `general` variant) |
| `add_worker.yaml` | `yamls/hsp_add_worker.yaml`, `yamls/general_add_worker.yaml` (same split) |
| `thumbnail.png` | `thumbnails/ray-cluster.png` |
| checkout `parallelworks/ray-cluster@main`, sparse `scripts` | `parallelworks/workflows@canary`, sparse `workflows/ray-cluster/app` |
| `bash scripts/<x>.sh` in the YAMLs; `SCRIPT_DIR="${JOB_DIR}/scripts"` in `start_ray_head.sh`, `dispatch_workers.sh`, `run_benchmark.sh` | `workflows/ray-cluster/app/...` |
| remote worker clone: `git clone --sparse ray-cluster.git` + `sparse-checkout set scripts` + `bash scripts/setup.sh` (3 dispatch modes) | clone of this repo (`REPO_URL`/`REPO_BRANCH`, overridable with `RAY_REPO_URL`/`RAY_REPO_BRANCH`, default `canary`) + `sparse-checkout set workflows/ray-cluster/app` + `bash workflows/ray-cluster/app/setup.sh` |

Everything else in the job graph is verbatim but for the endpoint conversion (judgment
call 1), and the scripts change in three places beyond the paths (the endpoint launch in
`start_ray_head.sh`, judgment call 6, and the log-streamer fix below). YAML-only changes
beyond the paths: banner comments removed, and four fixes to the `add_worker` forms that
the first test exposed (all pre-existing upstream):

- `auto` job-dir detection also accepts the flat `~/pw/jobs/<run-slug>/` directory of a
  CLI file run (registered runs keep their numbered subdirectories).
- A same-resource worker's sbatch script activates the venv named in `RAY_VENV_DIR` of
  the job dir it was submitted from — the add-worker run's, which had none, so the job
  died with `ray: command not found` (SLURM job 4 in the first test). The validate step
  now copies the cluster run's `RAY_VENV_DIR` into the add-worker run's dir.
- A step `cleanup:` block runs after a successful step too (platform semantics, observed
  live), so the dispatch step's cleanup — written for cancellation — ran right after
  attaching the workers; on a remote SLURM site it `scancel`s the job it just added. The
  run block now touches `WORKERS_DISPATCHED` on success and the cleanup exits early when
  the marker exists.
- The cluster run's cancel only `scancel`s the jobs listed in its own `slurm_jobids`, so
  same-resource workers added later were orphaned until walltime. The dispatch step now
  appends its `slurm_jobids` to the cluster run's (job dir published as an output of the
  validate step).
- In fire-and-forget mode `dispatch_workers.sh` disowned every background process,
  including a same-resource site's log streamer (`tail -f` on the worker log), which
  then outlived the add-worker run (three were found on the login node after three
  runs). The script now kills those streamers and disowns only the remote SSH sessions.
- **Adding a remote site never completed** (`blessed-ferret`, 20 min until the runner's
  timeout): the disowned `ssh … | stream_logs.py` pipeline kept writing the remote
  worker's status into the step's stdout, so the step could not end; when the run was
  cancelled the tunnel session died and the worker was orphaned (SLURM job + 14
  login-node proxies), and the cluster run's cleanup would not have found it either
  (it only knows its own `workers` input). Now, in fire-and-forget mode, each remote
  dispatch runs in its own process group (`set -m`) with its own log
  (`logs/dispatch_<site>.out`), the add-worker step appends its `workers` rows to the
  cluster run's `added_workers.jsonl`, and the cluster cleanup merges that file into
  the sites it tears down. Verified: `peaceful-catfish` completed in 80 s, the tunnel
  session and the worker survived it, and cancelling the cluster `scancel`led the added
  job through the merged list.
- The remote SLURM worker script backgrounds a `tail -f` on its SLURM log and never
  killed it; after the job ended the tail held the SSH channel open, so the detached
  pipeline lingered on the head. The remote cleanup trap now kills it.
- `dashboard.py`: the Ray poller dropped a node that had just registered through
  `/api/worker` because Ray's `/nodes` view lags the GCS by seconds; remote workers
  therefore stayed invisible in the topology until their next heartbeat (about two
  minutes), which is what the default configuration (workspace head, remote worker)
  hits first. A node now gets a 60 s grace period before its absence counts as death.

**Judgment calls:**

1. **Converted to the endpoint pattern** (second pass, same day; the first pass had
   kept the session to stay code-neutral). `start_ray_head.sh` still allocates the
   dashboard port with `pw agent open-port` and writes `SESSION_PORT` first — the
   workers reach the dashboard on that port through their tunnels — then wraps the
   dashboard in `pw endpoints run --name <ray_settings.name>-${PW_RUN_SLUG} --port
   <that port>` in the background (the wrapper's PID is `dashboard.pid`, the name is in
   `ENDPOINT_NAME`) and waits for the port to answer before registering the head. The
   `sessions:` block and the `update_session` job are gone; a `wait_for_endpoint` job
   calls the shared subworkflow (`host` = the head's IP, empty for the workspace, no
   skip file: there is no submitter to release), and `complete` prints the endpoint URL.
   Because the run holds the cluster, there is no `script_submitter`; the cancel path
   kills the wrapper and `pw endpoints delete`s the name. The recipe for this "service
   started by a long-lived job" shape is in `references/session-to-endpoint-upgrade.md`.
2. **The run holds the cluster** (like the k8s workflows: cancel = teardown) — the
   `start_ray_head`, `dispatch_workers` and `cluster_ready` jobs loop until cancelled.
   The test runner gained `_test.ready_job` (pass = that job completes while the run is
   still running; teardown = cancel) and `_test.scheduler` for this; documented in
   `tools/tests/README.md`.
3. **`add_worker` as `<variant>_add_worker.yaml` variants** of the same directory (it
   shares `app/`), following `general_rstudio.yaml` / `general-all.yaml`; a marketplace
   entry for it points at those files.
4. **Form input groups kept** (`head`, `workers`, `ray_settings`, `workload_settings`)
   instead of the `cluster`/`service` convention: a multi-resource form, and renaming
   would touch every expression in the job graph. The tests name the resource the
   runner checks through `_test.resource`.
5. Remote-site dispatch needs `~/.ssh/pwcli` on the head (pre-existing); the workspace
   has it, a cloud login node does not, so a cluster login node can head same-resource
   workers but not remote sites.
6. **One script change beyond paths: the worker-site ssh calls in `dispatch_workers.sh`
   pass `-o ControlMaster=no -o ControlPath=none`.** The workspace's `~/.ssh/config`
   sets `ControlMaster auto` with `ControlPath ~/.ssh/control:%h:%p:%r`; with the
   `pw://owner/cluster` target the script uses, the socket path contains slashes and the
   session dies right after authenticating (`unix_listener: cannot bind ... No such file
   or directory`), so remote dispatch failed with "Failed to allocate dashboard tunnel
   port". The unmodified upstream `workflow.yaml` failed identically from the same
   workspace (`unbiased-chigger`), so this is environmental, not a regression; the
   tunnel-carrying connection should not be multiplexed in any case.

**Test results (2026-09-23, `pw://alvaro/gcpsmall`, Ray 2.40.0, branch `ray-cluster`):**
pass = the `complete` job finished while the run still held the cluster (head up,
session `running`, the SLURM worker joined and ran the 208-task benchmark), then
`pw workflows runs cancel` left no Ray/dashboard/dispatcher process, no SLURM job and no
session on the resource. Rows are in `workflows/ray-cluster/tests/*/*.csv`.

| Test | Result |
|---|---|
| `general/gcp-head-gcp-worker` | probe `splendid-bat` (cold: Ray venv built in ~20 s with uv, head + SLURM worker + benchmark + session in 5m50s) then recorded PASS `upright-earwig` (warm, 177 s, cleanup ok). The `evolved-tarpon` fail row is not the workflow: a `pkill -f dispatch_workers.sh` run on the login node to remove orphans from earlier add-worker runs also hit this run's dispatcher (exit 143), which is what added `faulted` to the runner's final statuses |
| `general_add_worker/gcp-worker` | 3 rows: `witty-duckling` passed the runner's criterion but its worker died (`ray: command not found`, the venv-marker bug above); `endless-bluegill` after the venv + cleanup fixes: worker joined, cluster at 2 CPUs, cleanup skipped; `musical-grubworm` after the job-id fix: `slurm_jobids` of the cluster run held both jobs and cancelling it removed both |
| `hsp/gcp-head-gcp-worker` | PASS `good-titmouse` (warm, 53 s: the compute node was still up from the previous run, cleanup ok); `dashing-wahoo` PASS kept as the target of the hsp add-worker test |
| `hsp_add_worker/gcp-worker` | PASS `sure-mite` against `dashing-wahoo` (22 s): second SLURM worker joined (cluster at 2 CPUs), both job ids in the cluster run's `slurm_jobids`, no streamer left behind (`dispatch_workers.sh` in the leftover patterns); cancelling the cluster run then left no job, process or session |

**Correction (2026-09-24):** the "cluster at 2 CPUs" readings above for the same-resource
add-worker tests were most likely stale. gcpsmall's scheduler put the added job on the
node that already ran the cluster's worker, and the local worker script starts with
`ray stop --force` (upstream: one Ray worker per node), which stops that worker's Ray; the
head keeps a vanished node counted for up to 90 s (`RAY_HEALTH_CHECK_*` in
`start_ray_head.sh`), and those readings were taken within that window. The ray-cluster-2
and noaa runs show it plainly (`cool-rabbit`: jobs 26 and 27 on the same node, the added
worker's log "Stopped all 4 Ray processes", `ray status` 1.0 CPU). A same-resource add
therefore only adds capacity when the new job lands on a free node — ask for one with
`#SBATCH --exclusive` in the worker row's directives (not tested here). Upstream
behaviour, left unchanged.
| `general/workspace-head-gcp-worker` (remote dispatch: head on the user workspace, worker on gcpsmall over `pw ssh` tunnels) | `magical-rhino` FAIL at "Failed to allocate dashboard tunnel port" (the ssh ControlPath problem, judgment call 6; the unmodified upstream YAML failed the same way as `unbiased-chigger`), then PASS `sensible-squid` (302 s, cleanup ok on both hosts): the worker site cloned `workflows/ray-cluster/app` from this repo for `setup.sh`, joined through the reverse tunnel and ran the benchmark |

Not exercised: PBS sites, unscheduled remote workers, multi-node sites, GPU
detection and the `fractal` workload — the scripts for those are verbatim upstream.

**Endpoint conversion (second pass, same day):** pass now also requires
`ray-cluster-<run-slug>` in `pw endpoints list`; the workflow's `wait_for_endpoint` job
probed the URL with the run's key and, in addition, the URL was fetched by hand with a
user token during `causal-stallion` (anonymous: `307` to the login page; with the token:
`200`, `<title>Ray Cluster Dashboard</title>`, `/api/state` JSON with the head
registered). Cancelling the run kills the wrapper and the endpoint is gone within a
second (the runner's follow-up `pw endpoints delete` finds no session).

| Test | Result |
|---|---|
| `general/gcp-head-gcp-worker` | PASS `causal-stallion` (warm, 178 s, cleanup ok; endpoint `https://coherent-cod.activate.pw/`) |
| `hsp/gcp-head-gcp-worker` | PASS `fit-rattler` (warm, 53 s, cleanup ok) |
| `hsp/gcp-head-gcp-worker` (kept) + `hsp_add_worker/gcp-worker` | `picked-hyena` PASS kept; `generous-kitten` PASS (21 s): second worker's job registered with the cluster run (`slurm_jobids` 15 16); the endpoint URL fetched with a user token showed the dashboard's `/api/state` (phase `complete`, head `gcpsmall`); cancelling the cluster run removed the endpoint, both jobs and every process |
| `general/workspace-head-gcp-worker` | PASS `wealthy-grizzly` (85 s, cleanup ok on both hosts): with the head on the workspace the subworkflow's `host` rendered empty and the probe ran from the workspace (HTTP 200) |

**Defaults and the user's job path (third pass, same day):**

| Test | Result |
|---|---|
| `general/defaults-workspace-head` — the form's defaults as the UI sends them: workspace head, one gcpsmall worker with the default row (`scheduler` on, no partition, no gres, `01:00:00`), `ray_settings`/`workload_settings` omitted so their defaults apply (`cluster_only`, no user script, Ray 2.40.0) | `funky-emu` PASS kept: omitted groups rendered their defaults (`RAY_VERSION=2.40.0`, endpoint `ray-cluster-<slug>`, workload `cluster_only`), the sbatch script carried only `--nodes=1 --time=01:00:00`, the worker joined (`ray status`: 2 nodes, 1 CPU) and the workflow set phase `cluster_ready` 3.5 min after launch. A job submitted from the head the way the Connect tab shows (`ray job submit --address http://127.0.0.1:8265 --working-dir … -- python fake_job.py`, 12 remote tasks) succeeded with every task on the SLURM compute node. Cancelling removed the endpoint and every process on both hosts |
| `general/head-only-workspace` + `general_add_worker/workspace-head-gcp-remote-worker` (a remote site attached to a running cluster) | `strong-owl` + `blessed-ferret`: FAIL as described above (timeout, orphaned worker); `novel-boa` + `peaceful-catfish` after the fixes: PASS in 80 s, worker attached and still alive a minute after the add-worker run ended (`ray status` 1 CPU, tunnel session alive), Ray lists it under its tunnel IP `127.0.2.1`, the dashboard topology shows it (`site-2`, `gcpsmall`), and cancelling the cluster cancelled the added job (`Cancelling SLURM job 25`) |
| `hsp/defaults-user-script` — hsp form defaults for the worker row (no partition, gres, account or QoS; the `##SBATCH --constraint=mla` hint left in place), `cluster_only` with **Run User Script** on and a script that runs 12 Ray tasks and fails unless they ran off the head | `powerful-albacore` PASS (48 s to `complete`, cleanup ok): the hint rendered as a harmless `##SBATCH` comment, the script ran on the head with `RAY_ADDRESS` set and every task executed on the SLURM compute node |
| final remote check (`becoming-fawn` + `glorious-hog`) | after the streamer-trap and dashboard fixes: add-worker PASS in 84 s, the dashboard listed the tunnel worker (`site-2`, `gcpsmall`) at once and kept it, and 60 s after cancelling the cluster there was no endpoint, no process on the workspace and no SLURM job or remote-worker process on gcpsmall |
### ray-cluster-2: the run exits, the endpoint owns the cluster (2026-09-24)

Branch `ray-cluster-2` (on top of `ray-cluster`) reshapes the workflow into the repo's
standard lifecycle. Before, the head job ran `pw endpoints run` itself and the run stayed
`running` for the cluster's life (cancel = teardown, like the k8s workflows). Now:

- **One start script under `script_submitter`.** `preprocessing` checks out `app/`,
  writes `inputs.sh` (`ray_version`, `endpoint_name`, `head_resource_name`,
  `workload_type`) and `workers.json` (the worker rows), and assembles
  `inputs.sh` + the generic cleanup trap + `app/start-template.sh`. `session_runner`
  submits it through `workflows/script_submitter/v3.6/<variant>.yaml` with
  `scheduler: false` (the head needs `pw ssh` and the pwcli key, so it runs on the login
  node or the workspace) and `skip_cleanups_file`; `wait_for_endpoint` releases it once
  `ray-cluster-<slug>` answers. The submitter's `setsid` makes the start script its own
  process group, so the run's end does not touch it.
- **`start-template.sh` writes `cancel.sh` first**, then runs `start_ray_head.sh`, which
  installs Ray, starts the head, writes the coordination files, runs
  `pw endpoints run --port <allocated port>` around the dashboard, posts the
  `cluster_only` config to the dashboard before any worker can register, launches
  `dispatch_workers.sh` (output to `logs/dispatch.out`, failure recorded in
  `DISPATCH_FAILED`) and watches Ray. It returns when the wrapper is gone — deleted, or
  killed by the Ray health monitor — and exits non-zero unless the endpoint is somehow
  still listed. The trap then runs `cancel.sh`.
- **`cancel.sh` starts `app/teardown.sh` detached (`setsid`)** so the ssh round trips to
  remote sites survive the process-group kill: local SLURM jobs from `slurm_jobids`,
  remote sites from `workers.json` + `added_workers.jsonl`, the dispatcher, Ray, the
  wrapper and the endpoint; a lock directory keeps a second caller (trap and submitter
  cleanup can both run `cancel.sh`) from running it twice; `TEARDOWN_DONE` marks the end.
- **Jobs after the release.** `run_benchmark` (benchmark/fractal) and `cluster_ready`
  (`cluster_only`) run once the endpoint is healthy; the run completes when they finish.
  `cluster_ready` streams `logs/dispatch.out` while waiting up to 10 min for the first
  worker CPU (skipped for a head-only cluster), **fails the run and deletes the endpoint
  when the dispatcher gave up** (`DISPATCH_FAILED`: rejected `sbatch`/`qsub`, unreachable
  site) instead of proceeding with nothing to compute on, then runs the user script; with
  **Keep Cluster Alive** off it deletes the endpoint itself and waits for `TEARDOWN_DONE`
  (a batch job), and a failing script fails the run. `run_benchmark.sh` also stops on
  `DISPATCH_FAILED`. `complete` prints the endpoint URL and the delete command, or says
  the cluster was torn down.
- **add_worker** is unchanged: it reads the same coordination files from the cluster's
  job dir and appends to `slurm_jobids` / `added_workers.jsonl`, which `teardown.sh`
  reads.
- **Tests** use the runner's standard criterion (run completes, endpoint listed, `pw
  endpoints delete` + leftover checks). The runner gained `_test.expect` for failure-path
  tests (`error` = pass when the run fails as designed and nothing is left behind).

- **The teardown cannot use `pw` once the run has completed.** The start script
  inherits the run's `PW_API_KEY` (the step's key overrides the workspace's own, and a
  cloud login node has no stored context at all); the key expires with the run, so
  every `pw` call in the teardown answered "Authentication has expired" (first
  `optimal-reindeer` teardown log). Established `pw ssh` tunnels keep working, so the
  workers are unaffected; only reaching a remote site to cancel it is. Remote sites
  therefore **tear themselves down**: each login-node script (SLURM, PBS and direct-SSH
  modes) finds its session's `sshd` process at start and, in its long-running loop,
  exits through its existing cleanup trap (cancel the job, kill the proxies, stop Ray)
  when that process is gone — a session without a tty gets no signal when the client
  disappears, which is also how upstream orphaned sites when a dispatcher died. The
  teardown kills the dispatcher trees (its own and add_worker's detached sessions,
  recorded as process groups in `added_dispatch_pgids`) and the remote ends follow
  within one loop interval. The `pw ssh` cleanup calls stay as a best effort for the
  cancel-before-ready path, when the key is still valid, and skip the head's own
  resource (its jobs are in `slurm_jobids`; upstream's `scancel --name=ray-worker-*`
  there could hit another cluster of the same user). Verified in isolation first: a
  dispatcher-style `ssh … 'bash -s'` session from the workspace to gcpsmall, its local
  client killed, the remote side ran its trap 2 s later.
- **`cancel.sh` waits for the teardown to detach.** The first test's teardown log was
  empty: the background fork was killed by the trap's `kill -- -$$` before it called
  `setsid()`. `teardown.sh` now touches `.teardown.started` as its first action (it is in
  its own session by then) and `cancel.sh` returns only after seeing it, then waits up
  to 4 min for `TEARDOWN_DONE`.

- **noaa variant** (`yamls/noaa.yaml`, `yamls/noaa_add_worker.yaml`): the general job
  graph with `workflows/script_submitter/v3.6/noaa.yaml`, the worker rows' SLURM
  **Account**/**QoS** shown and passed only for `existing` (on-prem) resources, no DSRC
  constraint hint, and the noaa "Set Up Install Parent Directory" step: when the head has
  a writable `/contrib/pw`, `inputs.sh` gets `RAY_SOFTWARE_DIR=/contrib/pw`, which
  `setup.sh` now honours ahead of its work-directory search (one added line; unset, the
  behaviour is unchanged). Added same-resource workers reuse the head's environment; a
  remote site installs in its own default location.

What is lost, deliberately: the run no longer mirrors the cluster's health after it
completes (a dead head shows up as the endpoint disappearing, with the reason in
`run.<id>.out` and `logs/dashboard.log`), and the dispatcher's output streams into the
run only until the endpoint is up (afterwards: `logs/dispatch.out`, the `cluster_ready`
job's log while it waits, and the dashboard's Logs tab).

Also fixed on this branch (upstream): a rejected same-resource `sbatch`/`qsub` killed the
dispatcher silently under `set -e` (`x=$(sbatch …)` and the job-id `grep` both abort the
script), so neither its error line nor the dashboard's error card ever appeared; both
now reach the dispatcher's error branch (`fail-bad-partition` shows "ERROR: sbatch
failed: … invalid partition specified" in the run log and one `/api/worker/error` post).

**Test results (ray-cluster-2, 2026-09-24, gcpsmall + workspace):** pass = the runner's
standard criterion (run completes, endpoint listed, `pw endpoints delete`, no endpoint
wrapper / Ray / dashboard / dispatcher / start-script process and no SLURM job left),
or, for failure paths, the run ends in `error` with the same leftover checks.

| Test | Result |
|---|---|
| `general/gcp-head-gcp-worker` | `loving-snake` pass with `cleanup=leftover` (the detach race: teardown killed before `setsid()`), then `optimal-reindeer` PASS, teardown 2 s after the delete (`scancel 2`, Ray stopped) |
| `general/defaults-workspace-head` — the form defaults (workspace head, remote gcpsmall worker, `cluster_only`), kept | `enabling-llama`: run completed at 10:20; at 10:29 both Ray nodes alive and a `ray job submit` from the head ran 12 tasks on the compute node; `pw endpoints delete` → workspace clean in 2 s, the remote site noticed its session gone 7 s later and cancelled its SLURM job; nothing left on either host |
| `hsp/gcp-head-gcp-worker` | `huge-stork` PASS (48 s to complete) |
| `general/fail-bad-partition` (`expect: error`) | `lenient-rattler` PASS (run error, cluster torn down, no reason in the log), fix above, `hopeful-lizard` PASS (scheduler's reason shown), `firm-loon` PASS (also the dispatcher's error line and dashboard card) |
| `hsp/fail-user-script` (`expect: error`) | `suitable-halibut` PASS: "User script failed with exit code 3", run error, teardown cancelled the worker |
| `hsp/defaults-user-script` (batch, keep-alive off) | `new-pheasant` PASS: 12 tasks on the worker, the run deleted the endpoint and waited for `TEARDOWN_DONE`, `complete` says the cluster was torn down |
| `general_add_worker/gcp-worker`, `hsp_add_worker/gcp-worker` against kept clusters | `climbing-muskox`, `boss-salmon` PASS on the runner's criterion: added job registered in the cluster's `slurm_jobids`; one endpoint delete cancelled both jobs. Capacity did not grow (`ray status` 1.0 CPU): the added job shared the existing worker's node, see the correction above |
| `general_add_worker/workspace-head-gcp-remote-worker` against `head-only-workspace` | `engaged-tuna` PASS: the add-worker run completed, its detached session recorded in `added_dispatch_pgids`; the endpoint delete closed that session group and the remote site cancelled SLURM job 14 by itself |
| cancel before the endpoint is up (manual; cold Ray 2.39.0 install) | `super-bass`: cancelled with no head, job or skip file yet; the submitter killed the start script, its trap ran the teardown once, nothing left |
| cancel during the benchmark (manual) | `sterling-hornet`: the benchmark step's guard deleted the endpoint, teardown cancelled SLURM job 8, nothing left (`light-humpback`, meant as a before-ready cancel, hit the same after-release path) |
| the Ray head dies after the run completed (manual: `kill -9` of the GCS) | `model-dassie`: three failed checks (~46 s each), FATAL 2 min 18 s after the kill, teardown cancelled SLURM job 16, all processes gone; the endpoint stayed listed as `stopped` (the wrapper cannot deregister with the ended run's key) until `pw endpoints delete`. A first attempt (`together-doberman`) was confounded by the next test starting a second head on the same host: one Ray head per host, as upstream |

**noaa variant (same day, gcpsmall):** `setup.sh` with `RAY_SOFTWARE_DIR` set (a scratch
directory, trailing slash included) installed uv and Ray 2.40.0 there and recorded that
venv, then the directory was removed; gcpsmall has no `/contrib/pw`, so the variant's
step fell back to the default location, like the repo's other noaa variants there.

| Test | Result |
|---|---|
| `noaa/gcp-head-gcp-worker` | `amazing-hedgehog` PASS (48 s to complete; submitted through `script_submitter/v3.6/noaa.yaml`, the install-directory step in preprocessing, benchmark 100/100) |
| `noaa_add_worker/gcp-worker` against a kept `noaa/gcp-head-gcp-worker` (`choice-akita`) | `cool-rabbit` PASS on the runner's criterion; both jobs in the cluster's `slurm_jobids` and cancelled by one endpoint delete; capacity unchanged (same node, see the correction above) |
| `noaa/defaults-workspace-head` (workspace head, remote gcpsmall worker) | `positive-walrus` PASS (80 s); after the delete the remote site noticed its session gone and cancelled SLURM job 28 |

The on-prem account/QoS fields are only shown for `existing` resources, which this
account has no SLURM one of; they are statically checked (dry-run) only.

Not exercised on this branch either: PBS sites, unscheduled (SSH-mode) remote workers,
multi-node sites, GPUs and the fractal workload; the PBS and SSH-mode remote scripts got
the same session watch as the SLURM one (rendered and syntax-checked, not run).

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
- The ray-cluster entries (cluster + add-worker) pin `parallelworks/ray-cluster`'s
  `workflow.yaml` / `add_worker.yaml` → `workflows/ray-cluster/yamls/<variant>.yaml` /
  `<variant>_add_worker.yaml` here (`hsp` on `activate.hpc.mil`, `general` elsewhere).

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
5. **ray-cluster marketplace entries** (2026-09-23): the workflow joined on the
   endpoint pattern (its run still holds the cluster; cancel = teardown).
   Its marketplace entries (the multi-site cluster and "Add Worker") still point at
   `parallelworks/ray-cluster`'s `workflow.yaml`/`add_worker.yaml` and must be re-pointed
   at `workflows/ray-cluster/yamls/{hsp,general}.yaml` and `{hsp,general}_add_worker.yaml`
   here (thumbnail `workflows/ray-cluster/thumbnails/ray-cluster.png`).
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
