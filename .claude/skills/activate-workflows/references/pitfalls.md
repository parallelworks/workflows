# Pitfalls and lessons from real runs

> The surprises real runs taught, each with the date it was verified. This file is
> the **memory** of the skill: [SKILL.md](../SKILL.md) is the process and
> [activate-platform.md](activate-platform.md) the platform facts. **When a run
> misbehaves, search this file for the symptom text before debugging from scratch**,
> and append what you learn here (SKILL.md Step 5).
>
> "Step N" means SKILL.md's step N; "reference §N" means section N of
> [activate-platform.md](activate-platform.md). Lessons about one piece of software
> (OpenFOAM, Dakota, conda environments, Singularity/SIF images) live in
> [software/](software/), one file per tool — grep both when a symptom is unclear.

## Common pitfalls (learned from real runs)

- **Wrong deployment variant / mismatched resource form:** `general`'s slurm/pbs
  fields passed to an `emed`/`noaa`/`hsp` subworkflow are NOT rejected by `--dry-run`
  (unknown fields pass silently; verified 2026-09-16), so the mismatch surfaces only
  at run time. Match the variant to the host and copy its variant YAML form.
- **Resource passing:** bare name string in `-i` for `compute-clusters`, not a
  hand-built object; login IPs change, so never hardcode `ip`. A **kubernetes**
  resource is the exception: it must be the object described in reference §2.
- **Kubernetes-specific pitfalls** (quota, guards, sidecar lifecycle) are collected in
  [references/k8s-workflows.md §9](k8s-workflows.md).
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
- **A matrix over a computed list fails at submission** (`Could not expand matrix
  jobs`, dry-run and real run alike): matrix expansion is static — form inputs and
  literals only. Fan out over a runtime-computed set with a **guarded static
  matrix**: a literal list of max width + `if: ${{ matrix.job_id <=
  needs.<job>.outputs.N }}` on the matrix job (the dcs-workflow honda-japan pattern;
  guard-vs-output verified). Fallback: submit the matrix workflow as a fresh run
  from a step (`pw workflows run <abs yaml> -i '<json>'`, then poll the slug) —
  reference §3.
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
- **Never paste JSON into a `python -c` source string.** In `json.loads('''${SITES_JSON}''')`
  python un-escapes the document first, so a `\n` inside a value becomes a real newline and
  parsing dies with `Invalid control character` — one multi-line `editor` input is enough
  (the hsp directives default ends in one; burst-render-demo on `jean`, 2026-09-24). Read it
  from the environment (`os.environ["FOO_JSON"]`) or stdin, and single-quote the python
  source. Keep a multi-line directives value in one recorded test so it stays covered.
- **An empty group item is default-filled** (verified 2026-09-24): a hidden input sent as
  `"render_settings": {"name": ""}` reached the workflow as its default, like a top-level
  input; only a **list-template** field keeps `""` (reference §12). Reruns built from a past
  run's INPUTS tab send `""` for every hidden field, so this is the normal path. Still build
  a name several jobs must agree on **once**, published as a preprocessing output
  (`workflows/burst-render-demo`).
- **`parallelworks/checkout` leaves no `.git`** (verified 2026-09-24): it materializes the
  files only, so a script cannot read back which repo or branch the run used. To give another
  machine the same code, send what this one already has
  (`tar -czf - ... | ssh <site> "tar -xzf - -C ..."`) instead of cloning there: one branch
  reference instead of two, and it works where the site has no GitHub access
  (`workflows/burst-render-demo`).
- **Only the workspace and `existing` resources carry the platform SSH key** (`~/.ssh/pwcli`,
  verified 2026-09-23: present on the workspace and `a30gpuserver`, absent on gcpsmall's login
  node, where `pw ssh` outside a run also has no context). A job that opens `ssh -i
  ~/.ssh/pwcli ... -R` tunnels to other resources must run on one of those hosts; a
  same-resource target needs no tunnel at all (see `workflows/burst-render-demo`).
- **A run's `PW_API_KEY` expires when the run ends** (verified 2026-09-24): a service it
  started can no longer call `pw` (`Authentication has expired`). Open `pw endpoints run` and
  `pw ssh` connections keep working, so plan a teardown that needs no `pw` call
  (`workflows/ray-cluster`).
- **`ssh host 'bash -s'` has no tty, so the remote script gets no signal when the client
  dies**; if it is not writing output it runs on, orphaned. Have it watch its `sshd` parent
  and exit through its cleanup trap when that is gone (`workflows/ray-cluster/app/dispatch_workers.sh`).
- **A trap that backgrounds `setsid helper &` and then runs `kill -- -$$` can kill the helper
  before it detaches**: wait for a marker the helper writes first
  (`workflows/ray-cluster/app/start-template.sh`).
- **`faulted`** is the status of a run whose job failed while the others wind down; it never
  completes, so treat it as final.
- **`pgrep -f`/`pkill -f` run over `pw ssh` also match the remote shell carrying the command**
  (the pattern is on its command line): bracket one character, e.g. `dispatch_workers[.]sh`.
- **Cross-cluster filesystems are separate:** a code/data path staged on one resource is
  absent on another — stage it on the resource that runs it. If a required path is missing,
  **fail loud (exit non-zero), don't silently skip**: a silent skip upstream plus a
  downstream job waiting on its output (e.g. a port file) becomes an indefinite hang.
- **`pw ssh <resource>` suddenly answers "Cluster not found or you do not have sufficient
  permissions"** and `pw cluster ls` lists another platform's clusters: the CLI's current
  context changed under you (the user switched it in another shell; `pw context list`
  shows the `*`). Pin every call with `PW_CONTEXT=<context-name>` (or `--context`) instead of
  switching the global context back, which would break their shell (verified 2026-09-30).
- **A directive a workflow injects ahead of the form's `scheduler_directives` stays
  overridable:** sbatch keeps the LAST value of a repeated option (`--ntasks=2` then
  `--ntasks=3` → `NumTasks=3`, verified 2026-09-30 with `sbatch --hold` +
  `scontrol show job`), so compose `<workflow lines>\n${{ inputs.slurm.scheduler_directives }}`
  in the `with:` block (a `|` block scalar with expressions renders fine) and the user's
  line wins when they repeat it (`workflows/dakota-openfoam/yamls/iteration.yaml`).
- **`retry.timeout` defaults to 30 s PER ATTEMPT** (documented in
  building-workflows/yaml-fields; bitten and verified 2026-09-29): a `retry:` block
  without `timeout:` cancels each attempt of that step ~25-30 s in — for a `uses:`
  step that means the WHOLE subworkflow attempt, every job, mid-simulation, however
  deep the nesting. The symptoms mislead badly: the killed jobs exit 143 with no
  error of their own, a submitted SLURM job shows `CANCELLED by <you>` (the
  submitter's cleanup scancel), and it RACES — attempts that finish under ~25 s
  succeed, so fast tests pass while scheduled or slow production cases die
  (a minimal repro: a retried `uses:` step whose subworkflow sleeps 120 s fails;
  add `timeout: 10m` and it completes). Always set `retry.timeout` on a retried
  subworkflow step, sized for the whole attempt (queue + node boot + work):
  `workflows/dakota-openfoam/yamls/general.yaml` exposes it as a form input.
  `tutorials/optimization/general.yaml`'s Iterate step has this latent bug
  (its ~15 s test waves win the race; any real solver loses it).

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
