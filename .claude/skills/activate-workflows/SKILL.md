---
name: activate-workflows
description: >-
  Develop, test, and debug workflows on the Activate platform by Parallel Works.
  Use whenever the task involves an Activate / Parallel Works workflow, a service
  exposed as a pw endpoint, the script_submitter subworkflow, or the `pw` CLI
  (workflows create/update/run, endpoints, cluster). Provides a proven
  target-machine-first process plus a reference of platform facts pointing at the
  repo's real workflows and tutorials.
---

# Developing Activate (Parallel Works) workflows

A repeatable process for building a workflow that runs code on a compute resource
and (optionally) exposes a web service as a **`pw` endpoint**. Read
[references/activate-platform.md](references/activate-platform.md) for the YAML
schema, subworkflow interfaces, `pw` CLI, and job-directory layout — this file is
the **process**; that file is the **facts**. Kubernetes targets have their own process
and facts in [references/k8s-workflows.md](references/k8s-workflows.md).

**The platform docs are authoritative and updated over time — this skill is a
snapshot that can fall behind.** When something here conflicts with them, trust the
docs and harden this skill (Step 5):
- Building workflows — <https://parallelworks.com/docs/run/workflows/building-workflows>
  (subpages: [YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
  [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions))
- Endpoint sessions — <https://parallelworks.com/docs/run/sessions/endpoints>
- `pw endpoints` CLI — <https://parallelworks.com/docs/cli/pw/endpoints>
- `pw` CLI — <https://parallelworks.com/docs/cli>

**Assume the `pw` client is already authenticated** — otherwise ask the user to log
in. Confirm context with `pw context list` if unsure. **Set `permissions: ['*']`** in
every workflow: it is what lets the in-workflow
`pw` client authenticate (e.g. `pw endpoints run`).

## Golden rules

- **Reuse the endpoint pattern and `script_submitter`; plain DAGs for the rest.**
  For a web service, copy the repo's endpoint pattern: preprocessing checks out the
  code, `script_submitter` (`v3.6`) submits the start script, the start script runs
  the service under `pw endpoints run`, and a `wait_for_endpoint` job confirms it.
  For "just run a script/sim on a cluster," call `script_submitter` directly. Do
  **not** hand-write job submission, port allocation, or tunnel logic. Pure
  orchestration (multi-job DAG, data flow, fan-out) needs **no** subworkflow — that's
  a first-class use. Learn the patterns from the **repo's own workflows and
  tutorials**, not from invented demos (reference §9): endpoints →
  `workflows/{webshell,jupyterlab,openvscode}/`; **Singularity/SIF services →
  `workflows/streamlit/` (simple) and `workflows/kasmvnc/` (multi-impl)**; job DAG / outputs
  → `tutorials/endpoint-workflows/` (staged README); **fan-out / sweep →
  `tutorials/endpoint-workflows/05-matrix.yaml`**; retry/failover →
  `tutorials/endpoint-workflows/07-failover.yaml`; **Kubernetes** (no script_submitter,
  no login node) → [references/k8s-workflows.md](references/k8s-workflows.md).
- **Pick the deployment variant by platform host — don't default to `general`.**
  `script_submitter` ships as `general` / `emed` / `hsp` / `noaa`, and
  the **resource/scheduler/slurm/pbs form sections differ between them**. Choose:
  `emed` for `cluster.einsteinmed.edu`, `noaa` for `noaa.parallel.works`, `hsp` for
  `activate.hpc.mil`, `general` otherwise — **if unclear, ask the user.** Then copy the
  cluster/slurm/pbs form and `with:` block from the matching
  `workflows/<name>/yamls/<variant>.yaml`. (`pw context list` shows the host.)
- **Pass every required subworkflow input, and `--dry-run` first.** `--dry-run`
  validates the YAML and each subworkflow's required inputs: omit a non-optional input
  with no default and it fails with the terse `Could not parse subworkflow` (the field
  is never named — diff your `with:` block against the subworkflow's form). Inputs the
  form hides and ignores under the values you pass are NOT required
  (`script_submitter` with `define_cleanup_script: false` needs no
  `cleanup_script_path`). Dry-run does NOT flag unknown or wrong-variant fields; they
  pass silently and surface only at run time (verified 2026-09-16).
- **Develop on the target machine before touching YAML.** The YAML is a thin wrapper
  around code that already works there (directly if this shell is the target's login
  node, else via `pw ssh <resource>` — Step 1).
- **Know where your job runs.** `ssh.remoteHost: ${{ inputs.resource.ip }}` runs a
  job on that resource's login node — that's where the job dir and your process
  live. See Step 4.

## Step 1 — Develop the code on the target machine first

Pick the **target resource** before anything else (`pw cluster ls`; it must be
`active`) — developing and testing needs a real machine, and the workflow's jobs will
run on that resource's login node. A **Kubernetes cluster** (`pw kube ls`) has no login
node: follow [references/k8s-workflows.md §3](references/k8s-workflows.md) instead.

- **If this shell IS the target's login node** (common: the agent runs in a session
  on the cluster; compare `hostname` with the resource), work directly — edit files,
  run the program, inspect `~/pw/jobs/…` and `ps -x` locally. This is the fastest loop.
- **Otherwise, drive the target through `pw ssh <resource>`** — stage/edit code in
  the shared home, execute remotely (`pw ssh <resource> "cmd"`), and read job dirs
  the same way. Don't develop against the wrong machine: what runs here may be
  missing there (each cluster has its own filesystem and installed tools).

Then write and test the core program (server, simulation, script) on that machine
until it runs standalone. Do not write any YAML yet.

- For a web service: bind a port from an argument/env var, default to `0.0.0.0`,
  and serve everything the page needs. Prefer the **standard library / preinstalled
  tools** so the controller script has nothing to install. Test every endpoint with
  `curl` and confirm it terminates/looks right.
- Drive it the way the platform will: `python3 server.py --port 8731 …` in the
  background, then `curl localhost:8731/...`.
- Keep each piece a real file (you'll check these into the repo and `checkout` later).

Done when: the program runs from a clean shell on the target machine with no manual
setup and produces correct output.

## Step 2 — Wrap the working code in workflow YAML

Mirror the proven pattern (see `workflows/webshell/yamls/general.yaml`): a
**preprocessing** job (checkout + `inputs.sh` + run `controller.sh` + assemble the
start script), a **script_submitter** job that submits it, and a
**wait_for_endpoint** job that polls `pw endpoints list` for
`<service.name>-${PW_RUN_SLUG}`, then touches the `SKIP_CLEANUP` marker and cancels
the submitter so the service outlives the run.

Provide the two contract scripts:
- **`controller.sh`** — idempotent setup on the login node (has internet). Often
  just verifies prerequisites.
- **`start-template.sh`** — launches the service under
  `pw endpoints run ${pw_endpoints_args} -- <cmd with {port}>`, and **fails loud**:
  if `pw endpoints run` exits without the endpoint registered, exit non-zero so
  the submitter job fails and the submitter job's cancel-jobs step stops
  `wait_for_endpoint` (copy the tail of `workflows/webshell/app/start-template.sh`).
  Do NOT self-cancel the run with `pw workflows runs cancel` from inside a start
  template.

**Path rule (learned the hard way):** only the runtime subtree is checked out —
`workflows/<name>/app` (single-implementation) or `workflows/<name>/<impl>` — and it
materializes at `${PW_PARENT_JOB_DIR}/workflows/<name>/app/…`. Every path a YAML or
script builds to reach repo files (including ones composed from variables like
`"${PW_PARENT_JOB_DIR}/${service_name}"`) must carry that full prefix. Keep
`yamls/`, `thumbnails/`, and READMEs out of `app/` so runs never materialize them.

**Getting the scripts onto the node — use `parallelworks/checkout`. The repo is fetched from GitHub **at runtime**, so nothing you edit
locally takes effect until it is pushed. Two modes depending on whether Claude can
push to the repo:
1. **Write access (recommended):** ask the user to grant a **deploy key with write
   permission**. Work on a **development branch — never `canary` directly** (branch
   rules require PRs) — commit and push, then `parallelworks/checkout` that branch
   (`branch: <dev-branch>`, `sparse_checkout: [workflows/<name>/app]`). Open a PR to
   `canary`; after the merge, flip `branch:` back to `canary`.
2. **No write access:** you can't push, so stage the files on the resource (e.g.
   `~/pw/dev/<workflow>/`) and give preprocessing **two steps** — the
   `parallelworks/checkout` step **commented out** (configured for after the merge) and
   a **copy step** (`cp -r ~/pw/dev/<workflow>/. .`) that mimics it. The user later
   pushes & merges, uncomments checkout, and deletes the copy step.

Pass `script_submitter`'s inputs **from the matching variant's YAML** (`resource`,
`use_existing_script`+`script_path`, `scheduler`, `slurm`/`pbs`, and the
`skip_cleanups_file` wiring — copy the whole `with:` block). `skip_cleanups_file` exists
only for endpoint workflows (it is what lets the service outlive the run); a plain
batch job leaves it unset. Add
`include-workspace: true` on the `compute-clusters` input if the workspace should be
selectable. The hidden `service.name` input is the **endpoint name prefix** — keep it
stable (renaming it changes endpoint names users see).

**Base paths:** subdomain endpoints serve at the URL root, so most apps need no
base-URL config and no nginx (reference §11/§12); `--slug` handles a landing path or
query string.

`integer` inputs render as bare digits in the shell and compare numerically in
expressions (`inputs.n == 5`, `inputs.n > 3` — verified 2026-09-16). An **optional
integer left unset renders empty**, so guard those with `${var:-default}`.

**Kubernetes:** the same endpoint, registered by a `pw-cli` sidecar inside the pod; no
script_submitter, no login node, nothing checked out, and the run stays alive until it
is cancelled. Anatomy, dev loop, inputs, tests and debugging are in
[references/k8s-workflows.md](references/k8s-workflows.md); copy
`workflows/mlflow/yamls/k8s.yaml` (k8s-only) or `workflows/openvscode/yamls/general_k8s.yaml`
(hybrid).

## Step 3 — Test end-to-end and record the test

Every workflow is tested end-to-end at least once, and any end-to-end test is recorded
under `workflows/<name>/tests/<variant>/`. The test layout, the `_test` keys, the pass
criteria and the result columns are documented once, in `tools/tests/README.md`; read
it before writing a test. Start from an existing test, e.g.
`workflows/webshell/tests/<variant>/<test-name>.json`.

**Push first, unless only the YAML changed.** The YAML's checkout and `uses:` steps
fetch the repo from GitHub at run time, so a local edit to anything they fetch (`app/`
scripts, the subworkflow) is invisible until it is on the referenced branch. The YAML
itself is read from the local path, so a YAML-only edit tests without a push.

```bash
python3 tools/tests/run-workflow-test.py workflows/<name>/tests/<variant>/<test>.json
```

Pass = `result=pass` and `cleanup=ok` in the row the runner appends. On failure read
`tests/<variant>/logs/<slug>.txt` and `pw workflows runs errors <slug>`, fix, push,
re-run. Commit the test files and CSV rows with the change; never edit a CSV by hand.

**If the `pw` client is not authenticated** (or cannot reach the platform from this
shell), still write the test JSON under `workflows/<name>/tests/<variant>/`, then
hand the exact runner command above to the user and ask them to run it (after
`pw auth`) and report the appended row. Never skip creating the test because the run
cannot happen here, and never claim a workflow was tested if the row does not exist.

Facts that still matter when running by hand (`pw workflows run /abs/path.yaml -i inputs.json`):
- Pass the resource as its URI (`pw://alvaro/gcpsmall`) or bare name; never an IP.
  It must be `active` in `pw cluster ls`.
- **Kubernetes:** pass = the endpoint is listed and answers while the run is still
  `running`; teardown = `pw workflows runs cancel <slug>`. Inputs and checks:
  [references/k8s-workflows.md §4–§5](references/k8s-workflows.md).
- On a compute cluster the run completes once `wait_for_endpoint` sees the endpoint;
  the service keeps running until `pw endpoints delete <name>`, which kills the remote
  process tree. Daemonizing apps that re-parent to PID 1 (e.g. RStudio's `rsession`)
  can survive it.
- **Verify cleanup on CANCEL — a required test, not an afterthought:** cancel one run
  mid-flight (`pw workflows runs cancel <slug>` while the service is starting or
  serving) and confirm `cancel.sh` actually ran: no service processes (`ps -x`), no
  scheduler job left (`squeue`/`qstat` when `scheduler:true`), no container instances
  (`singularity instance list`, `docker ps`), no stray listeners. If anything
  survives, fix `cancel.sh` (and write it at the very top of the start script so a
  cancel at any moment finds it) before calling the workflow done.

## Step 4 — Debug from the job directory and processes

After every run, inspect artifacts on the **node where the job ran** (the resource's
login node when `scheduler:false`):

```bash
ls -la ~/pw/jobs/<slug-or-name/NNNNN>/            # inline runs: ~/pw/jobs/<run-slug>/
cat   ~/pw/jobs/<run>/run.*.out                   # script_submitter output (service stdout)
cat   ~/pw/jobs/<run>/logs/<job>/step_N/step.out  # per-step trace (+ step.exit)
cat   ~/pw/jobs/<run>/logs/<job>/step_N/script-unstable.sh  # the RENDERED step — every
                                                  # ${{ input }} shown as its literal value:
                                                  # the fastest way to see what the form sent
ps -x | grep <your-process>                       # is the service alive?
pw endpoints list                                 # is the endpoint registered?
```

**The execution node may not be this machine.** It's the login node of the chosen
resource. If files/processes aren't here, you targeted a different resource — either
target the resource whose login node *is* this host, or `pw ssh <resource>` to it.
Logs are always reachable via the API regardless of node:
```bash
pw workflows runs logs   <slug> --job session_runner          # the submitter job (its name in every YAML here)
pw workflows runs errors <slug> -o text                       # just the failures
```

**Kubernetes runs have no job dir on a cluster node** — debug them per
[references/k8s-workflows.md §6](references/k8s-workflows.md).

Diagnose → fix the local code or YAML → push (PR to `canary`, or the dev branch the
checkout points at) → re-run. **Clean up what you started:** `pw endpoints delete`
for live endpoints, `pw workflows runs cancel <slug>` for runs still executing (and for
every Kubernetes run — cancelling is its teardown). A lingering endpoint holds the
service process.

## Step 5 — Harden this skill

Every time you hit a surprise — a wrong YAML field, an unexpected CLI flag, a
misunderstood subworkflow input, a debugging trick that worked — **add it to this
file or the reference** so the next run avoids it. These files are living documents.
Because the **platform docs change**, re-check them when behavior surprises you and
correct this skill toward the docs. **Do not add a new tutorial to
`tutorials/` without maintainer approval** — each must show something new and
non-repetitive; point at an existing tutorial instead.

## Best practices

- **Develop on the target machine first; prefer the standard library** so controller
  scripts have nothing to install.
- **Deliver code with `parallelworks/checkout`, not base64.** Push to a dev branch and
  checkout that branch (write access), or stage on the resource + a commented-out
  checkout beside a stand-in copy step (no write access). See Step 2 / reference §10.
- **Match the deployment variant to the platform host** (`emed`/`noaa`/`hsp`/`general`)
  and copy that variant's resource/slurm/pbs form — don't reuse `general` blindly.
- **Orchestrate with the job graph.** Share files across jobs via `${PW_PARENT_JOB_DIR}`
  (`cd` into it). Pass values with `echo "K=v" | tee -a $OUTPUTS` (or pipe a program
  that prints `K=v` lines) and read `${{ needs.<job>.outputs.K }}`. Drive conditional
  steps with `if: ${{ needs.X.outputs.flag == 'true' }}` — compute the boolean
  upstream. For failure/cancel handlers use the `if:` status keywords (`always`,
  `error`, `canceled`, `!completed`; see `tutorials/if-conditions/`). Fan out with a **matrix strategy** (see `tutorials/endpoint-workflows/05-matrix.yaml`); fan
  in with `needs: [w1,w2,w3]`. For **retry/failover**, attach a `retry` block to a step
  and use `PW_WORKFLOW_STEP_CURRENT_RETRY` to pick a target per attempt — round-robin
  over a `list` input fails over across resources (see
  `tutorials/endpoint-workflows/07-failover.yaml`; reference §3 "Step retries").
- **Make scripts idempotent and traceable:** `set -o pipefail`, `set -x`; check
  before installing; safe to re-run.
- **Stream progress and emit structured results.** Print incremental progress (it
  streams to `run.<JOBID>.out` / the page) and write a machine-readable result
  (JSON) — don't make the user guess whether it's alive or done.
- **Defensive inputs:** an optional input with no default renders **empty** in the
  shell (verified for `integer`) — guard with `${var:-default}`; quote every
  `${{ ... }}` interpolation so empties/spaces don't break the shell.
- **Relative paths inside submitted scripts.** `script_submitter` `cd`s into `rundir`
  first; reference files relative to it, not via `${PW_PARENT_JOB_DIR}` (which may be
  unset on a SLURM/PBS compute node — the home FS is shared, so relative paths work).
- **Pin subworkflow versions** (`v3.6`) so an update can't silently change behavior.
- **Pull ghcr artifacts through `tools/oras/libs.sh:oras_pull_file`** (or copy its
  retry loop): ghcr intermittently rate-limits anonymous pulls (`toomanyrequests`) —
  a single-attempt pull fails a whole run for nothing. And keep the packages
  **public**: verify with an anonymous manifest request before shipping (a private
  package 403s and no retry will save you).
- **Registered ("remote") workflows pin one YAML path** (`remote.yaml` in
  `pw workflows get <name> -o json`, plus `readme`/`thumbnail` paths). The form —
  including defaults — comes from *that* file: a desktop that ignores your
  `startup_command` default usually means the registration points at the wrong
  variant. Point registrations at `workflows/<name>/yamls/<variant>.yaml` and
  thumbnails at `workflows/<name>/thumbnails/…`.
- **Cross-node service reach (multi-resource workflows).** When one job/service must reach
  another resource's service, expose it on localhost with `pw forward -L p:host:p
  <resource>` (`host` = `localhost` if unscheduled, the `HOSTNAME` value if scheduled —
  see Common pitfalls). Read the other job's runtime values (its allocated port, its
  `HOSTNAME`) with `pw ssh <resource> "cat ${PW_PARENT_JOB_DIR}/<file>"` — that path is the
  same on every resource in a run. Reference §6.
- **Gate dependent services without hanging.** If service A needs service B's runtime
  output (e.g. a dynamically-allocated port), have A **wait** for it, but make B **fail loud**
  on any misconfiguration and rely on `early-cancel: any-job-failed` so B's failure cancels
  A — otherwise an indefinite wait hangs forever. Mirror B's values locally in A once read,
  so later steps don't re-query across hosts.
- **Clean up:** provide `cancel.sh`/cleanup scripts, and cancel runs you're done with
  (`pw workflows runs cancel`) so nothing lingers (`sleep inf`, SLURM allocations).

## Common pitfalls (learned from real runs)

- **Wrong deployment variant / mismatched resource form:** `general`'s slurm/pbs
  fields passed to an `emed`/`noaa`/`hsp` subworkflow are NOT rejected by `--dry-run`
  (unknown fields pass silently; verified 2026-09-16), so the mismatch surfaces only
  at run time. Match the variant to the host and copy its variant YAML form.
- **Resource passing:** bare name string in `-i` for `compute-clusters`, not a
  hand-built object; login IPs change, so never hardcode `ip`. A **kubernetes**
  resource is the exception: it must be the object described in reference §2.
- **Kubernetes-specific pitfalls** (quota, guards, sidecar lifecycle) are collected in
  [references/k8s-workflows.md §9](references/k8s-workflows.md).
- **`Could not parse subworkflow` on `--dry-run`:** a non-optional subworkflow input
  with no default is missing from your `with:` block; the message never names it.
  Hidden+ignored inputs don't count — compare your block against the fields the
  subworkflow's form shows for the values you pass.
- **Scheduled jobs run on a compute node** that may lack `${PW_PARENT_JOB_DIR}`; use
  paths relative to `rundir`. Cloud-burst nodes are slow to provision (**6+ min**
  observed; `idle~ → CF → RUNNING`, `POWERING_UP` while booting) — watch with
  `squeue`/`sacct` on the login node and poll with long intervals; it's not a hang.
- **`workspace` resolves with empty `ip`** → its SSH steps run on the workspace node
  (a *different* host than a cluster login node). Match your debugging location to
  the resource you chose.
- **Code-delivery mistakes:** don't base64-embed; if you used the no-write-access
  copy step, remember it must be swapped for the (currently commented) checkout once
  the branch is merged.
- **Base-path apps break on path-based endpoints** if they assume the host root — give
  them the `{path}` token as base URL, or `--strip-path` (reference §11).
- **No session subdomains on emed:** register endpoints with `--no-subdomain` there
  (the platform then serves `/me/session/<PW_USER>/<name>/` and forwards the full
  path — give the app that base path). See `workflows/kasmvnc/yamls/emed.yaml`.
- **Endpoint names must be lowercase `[a-z0-9-]`** (undocumented; one uppercase letter
  fails the launch). `<service>-${PW_RUN_SLUG}` is safe; a name typed into a form is not:
  fold it before it reaches `pw endpoints`, and make the wait step look for the same
  folded name (`workflows/ollama/yamls/general.yaml`, input `endpoint_name`).
- **Browser-side app state dies with a random subdomain:** web IDEs (code-server,
  JupyterLab) keep sign-ins, disabled-extension lists, workspace trust and UI state in
  the browser (localStorage/IndexedDB), keyed by page origin — a new random subdomain
  per run resets all of it (openvscode, 2026-09: Copilot logout, extensions re-enabled,
  folders untrusted every run). Pin the origin with `pw endpoints run --subdomain
  <label>` (a platform-wide DNS label: lowercase `[a-z0-9-]`, ≤63 chars — build it from
  the resource namespace, cluster and `PW_USER`), keep `--name <service>-${PW_RUN_SLUG}` for lookup,
  and check `pw endpoints list` for an endpoint already serving `https://<label>.`
  before launching (see `workflows/openvscode/app/start-template.sh`).
- **Login nodes that block repo.anaconda.com (hsp `jean`) need a prebuilt conda env:**
  a download that runs under `nohup` with its output sent to a file is never checked, so
  the failure surfaces 80 lines later as "command not found". Check every download and
  installer, and ship the fallback as a conda-pack tarball on ghcr
  (`workflows/jupyterlab/build-conda-artifact.sh`, pulled with `oras_pull_file`). Packing
  a Miniconda root prefix works (`--exclude 'pkgs/*' --exclude 'envs/*'`); run the
  generated `conda-unpack` as `<prefix>/bin/python <prefix>/bin/conda-unpack` because its
  `#!/usr/bin/env python` shebang finds no `python` on RHEL 8 (verified in a Rocky 8
  container). Build with `CONDA_OVERRIDE_GLIBC=<target>` and `PIP_ONLY_BINARY=:all:`, and
  whitelist pure-Python sdists (`PIP_NO_BINARY=jupyterlab-slurm`) that publish no wheel.
- **`oras pull` says `denied` for a public package:** a stale ghcr login in the
  user's `~/.docker/config.json` on the cluster is being sent. `tools/oras/libs.sh`
  pulls anonymously first for this reason — reuse it instead of calling oras directly.
- **Container entrypoints that `pkill` by name kill sibling jobs:** singularity shares
  the host PID namespace, so the KasmVNC image's start-up `pkill -u $(id -u) -f Xvnc`
  killed the same user's other desktop starting on that node (verified on emed: two
  concurrent starts killed each other). Run such containers with `--pid` (works
  unprivileged with `--userns`; probe it, some sites disable PID namespaces) and anchor
  every `pkill -f` pattern you write to `cancel.sh` (`"Xvnc :${N}( |$)"`, not `"Xvnc :${N}"`).
  Test with two runs pinned to one node (`#SBATCH --nodelist=<node>`).
- **`pw agent open-port` is a TOCTOU trap for slow-starting services:** the port
  sits unbound while the service boots (a SIF conversion takes ~1 min), and busy
  siblings on the node (MATLAB's dynamic services) steal it from the ephemeral
  range in that window — three retries collided in a row. For services with a
  slow bind, derive ports below the ephemeral window (32768+; e.g. 25900+display)
  from a node-unique value instead (see kasmvnc's start template).
- **A backgrounded startup app inherits a closed stdin:** console-driven GUIs
  (vmd) read stdin, get EOF, and "exit normally" right after starting. Launch
  with stdin on a read-write FIFO (`mkfifo f; cmd 0<> f &`) — never blocks,
  never EOFs (verified with vmd on emed).
- **curl is not a websocket probe:** `curl -H 'Upgrade: websocket' …` returned 404
  from a websockify path that a raw HTTP/1.1 upgrade request (python socket) got 101
  from. Test handshakes with a raw request before blaming the route.
- **Service must bind `0.0.0.0:${service_port}`** (not `127.0.0.1`, not a fixed
  port) or the tunnel can't reach it / the port clashes.
- **Forgot `cancel.sh` or `sleep inf`:** the service is killed immediately or the
  job exits before the endpoint registers.
- **Missing `permissions: ['*']`:** in-workflow `pw` calls fail to authenticate.
- **Test the failure path on purpose:** make the start script `exit 1` before
  `pw endpoints run` and check the run ends in `error` — the success path never
  exercises the error-handling steps.
- **Always `--dry-run`** before a real run; it catches schema/YAML problems cheaply.
- **`pw workflows run ./relative/path.yaml` is parsed as a git host** and fails with
  a bogus DNS/GitLab error — always pass the **absolute path** for local YAML files.
- **`pw` auth expires** (short-term tokens): a day-old shell suddenly failing every
  command with "Authentication has expired" needs the user to run `pw auth` — it
  prompts for a credential; there is nothing the agent can mint itself.
- **Forgetting to push before a run** tests the *old* code: the checkout and `uses:`
  steps fetch from GitHub, not your working tree.
- **Composed checkout paths without the `workflows/` prefix**
  (`"${PW_PARENT_JOB_DIR}/${service_name}"`-style) fail with file-not-found only at
  run time — grep for `PW_PARENT_JOB_DIR` compositions when a script can't find its
  own files.
- **`pw forward` target host (verified):** forward a service to localhost with
  `pw forward -L p:host:p <resource>` — `host=localhost` when the service is on the
  **login node** (unscheduled; its external hostname is NOT reachable), `host=<HOSTNAME
  file value>` when it's on a **compute node** (scheduled). Pick by the scheduler flag.
- **Input group named `env` + a top-level `env:` block** referencing `${{ inputs.env.* }}`
  → `Expression Parser Error: max recursion exceeded`, failing **both `--dry-run` and
  `pw workflows run`** (the web UI may still submit). Rename the group (e.g. `env_vars`).
- **Cross-cluster filesystems are separate:** a code/data path staged on one resource is
  absent on another — stage it on the resource that runs it. If a required path is missing,
  **fail loud (exit non-zero), don't silently skip**: a silent skip upstream plus a
  downstream job waiting on its output (e.g. a port file) becomes an indefinite hang.

## Lessons from LLM-backed & multi-service builds (hermes-agent)

Reusable takeaways from building a multi-agent workflow (an orchestrator on the
workspace + a worker per cluster). Platform mechanics are in **reference §12**.

- **`--dry-run` is necessary but NOT sufficient.** It only validates the YAML and
  required subworkflow inputs.
  "Tested end-to-end" (Step 3/4) means a real run, the endpoint online in
  `pw endpoints list`, exercising the *live* service, and debugging from `~/pw/jobs`. Don't
  call a workflow tested on a dry-run alone.
- **Test through the real client path, not a stand-in.** Reach the service the way
  the user will — through the platform proxy, endpoint URL or chat — not just a local `curl`.
  Proxy-only failures (SSE streaming resets, base-path rewrites, ~60s timeouts) pass
  a localhost curl and a non-streaming call, then fail in the actual UI. When a
  service works locally but fails through the platform, read its **own stdout/stderr
  log in the job dir** — the traceback there pinpoints the cause fast.
- **Prove the risky/novel mechanism on real infra early**, before the full workflow
  is wired. For a distributed piece (e.g. cross-node `pw ssh` calls), stage the
  script on the target node and exercise it directly, then wrap it in YAML.
- **Reuse the platform's native surfaces — don't hand-roll UI.** For a chat-style
  service, make it OpenAI-compatible and expose it with `pw endpoints run --openai` so it
  joins the built-in chat; every model its `/v1/models` lists becomes a chat model and the
  list is re-polled. If an agentic/streaming service is flaky in the chat, serve its own
  web UI as a plain endpoint instead. SSE must be framed for the proxy. (Reference §12.)
- **LLM "brain" = the platform endpoint + runtime `PW_API_KEY`** (+ `X-Allocation`
  for `org:*` models) — no external key or org secret. To use the key in workflow
  code, expose it with a top-level `env:` block (`PW_API_KEY: ${PW_API_KEY}`); keep
  it out of `inputs.sh` (the `grep -v PW_API_KEY` convention) and read it from the
  runtime env. (Reference §12.)
- **`pw workflows run` uses the STORED def — `pw workflows update` after every YAML
  edit**, or the run silently uses the old form.
