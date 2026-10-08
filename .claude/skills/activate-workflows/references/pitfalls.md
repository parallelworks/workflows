# Pitfalls and lessons from real runs

> The surprises real runs taught, each with the date it was verified. This file is
> the **memory** of the skill: [SKILL.md](../SKILL.md) is the process and
> [activate-platform.md](activate-platform.md) the platform facts. **When a run
> misbehaves, search this file for the symptom text before debugging from scratch**,
> and append what you learn here (SKILL.md Step 5).
>
> "Step N" means SKILL.md's step N; "reference §N" means section N of
> [activate-platform.md](activate-platform.md). Lessons about one piece of software
> (OpenFOAM, Dakota, ParaView, conda environments, Singularity/SIF images, MPI benchmarks, dask-jobqueue) live in
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
  (`workflows/burst-render-demo`). Corollary (2026-10-07, `workflows/benchmarks`): a
  failure-path test cannot reach an "input is empty" check by sending `""` for an input
  that has a default; send a value the form's `min`/`max` would forbid instead
  (`ntasks_per_node: 0`), which the API passes through unchanged.
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
- **`script_submitter` with `use_existing_script` and `script_path: ./run.sh` wraps its own
  output on a retry** (verified 2026-09-30): the submitter writes its assembled job script
  as `run.sh` in `rundir`, so a step that re-submits the same dir copies the assembled
  script as the template and prepends the headers again (doubled `#SBATCH` lines, the
  `hostname > HOSTNAME` line twice). Name the script you hand it anything else
  (`workflows/openfoam-naca`: `case.sh`; `tutorials/optimization` still has the collision).
- **`tail -8 f1 f2` prints nothing:** coreutils accepts the old `-N` form only with a single
  file; with several it fails with "option used in invalid context" — to stderr, which a
  `2>/dev/null` hides, so a "log tails:" banner comes out empty (verified 2026-09-30, it had
  been silent since the workflow's first version). Always `tail -n N`.
- **A deterministic optimizer replays a failed generation identically**, so "no results
  → re-propose the same points" can never recover from a solver failure: two designs of
  one generation diverged (SIGFPE) on the compute nodes while converging on the login node,
  and the loop ended FAILED after re-proposing them once. Record evidence that a case *ran*
  (`exit_code` written by the case script) and feed ran-and-failed points back as FAIL;
  reserve the re-propose path for generations with no evidence of running at all
  (`workflows/dakota/app/optimizer.py`, verified 2026-09-30).
- **A directive a workflow injects ahead of the form's `scheduler_directives` stays
  overridable:** sbatch keeps the LAST value of a repeated option (`--ntasks=2` then
  `--ntasks=3` → `NumTasks=3`, verified 2026-09-30 with `sbatch --hold` +
  `scontrol show job`), so compose `<workflow lines>\n${{ inputs.slurm.scheduler_directives }}`
  in the `with:` block (a `|` block scalar with expressions renders fine) and the user's
  line wins when they repeat it (`workflows/openfoam-naca/yamls/general.yaml`).
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
  `workflows/dakota-openfoam/yamls/general-naca.yaml` exposes it as a form input.
  `tutorials/optimization/general.yaml`'s Iterate step has this latent bug
  (its ~15 s test waves win the race; any real solver loses it).

- **A batch script killed by `scancel` runs its EXIT trap with `$?` = 0** (verified
  2026-10-06, `workflows/benchmarks`): SIGTERM reaches bash while it waits for the
  benchmark pipeline, bash runs the exit trap on the way out, and `$?` there is the status
  of the last command that *completed*, the `echo` before the pipeline, so a
  `trap 'echo $? > x.exit' EXIT` records `0` for a cancelled job. Trap the signals too
  (`trap 'exit 143' TERM`, `130` INT, `129` HUP) so the exit file says killed, **and run
  the long command in the background with `wait $!`**: bash defers a trap until a
  foreground pipeline ends, and an `mpirun` that got SIGTERM kept its IOR ranks writing
  for 54 s (2026-10-07), past SLURM's `KillWait` (30 s here), so SIGKILL took bash and
  no trap ran at all; in `wait` the trap runs at once. Wrap the pipeline in a subshell
  with `pipefail` so `wait` returns the command's status, not `tee`'s. **Killing the
  job's process group does not end Open MPI ranks**: `mpirun` puts every local rank in
  a process group of its own (verified with `ps -o pid,pgid`: two `ior` ranks each had
  their own pgid while `mpirun` shared the subshell's), so a `kill -- -<pgid>` left the
  ranks writing and the `rm -rf` of their directory failed with "Directory not empty".
  Walk the tree (`pgrep -P`, recursively, captured *before* the first kill, since
  orphans re-parent) and signal the pids, then SIGKILL; the removal is retried while
  ranks on other nodes die with the step. The submitter's
  cleanup script stays the belt and braces (and on `hsp` it cannot reach the node: that
  submitter writes `HOSTNAME` after the script). `activate-batch`'s `commands.exit` has
  the same latent `0`; harmless there because a cancelled run never reads it.

- **A `pw ssh` call that launches a detached script and then keeps working did not
  return** (2026-10-07, twice, `workflows/dask-slurm`'s dev loop): `pw ssh <r> 'setsid
  nohup bash script.sh > out 2>&1 < /dev/null & sleep 25; cat out'` and a `bash -c` whose
  body backgrounds a long-lived python stayed open for minutes, past the tool timeout,
  while `pw ssh <r> 'setsid nohup bash -c "..." > log 2>&1 < /dev/null & echo started'`
  (nothing after the launch, nothing backgrounded inside) returned at once. Stage the
  script with `pw ssh <r> 'cat > remote.sh' < local.sh`, launch it as the last thing in
  its own call, and poll the logs in separate calls. Kill the leftover launcher shells
  (`ps -u $USER -o pid,etime,args`) or their delayed commands run later against a newer
  state: a demo client from the stale launch connected to the next test's scheduler.

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
- **A matrix instance cannot read its own earlier step's outputs** (verified 2026-10-01):
  `${{ needs.workers.outputs.V }}` in step 2 of matrix job `workers`, where step 1 wrote
  `V`, fails the step with `Expression Parser Error: output V from job workers not found`
  (same for `needs.workers.steps.<id>.outputs.V`); the instances are `workers-0`,
  `workers-1`, … and the bare job name resolves to none of them. Nor can a per-slot
  value be looked up in an upstream job's outputs by computed key:
  `${{ needs.gen.outputs get matrix.job_id }}` returns a character of the stringified
  map, not the entry. So a matrix slot that must feed per-slot data into a `uses:` step
  passes **paths built from `matrix.job_id`** and lets the subworkflow read the file
  (`workflows/dakota-openfoam/yamls/iteration-naca.yaml`: `case.params_file`).
- **`needs.<job>.outputs.X` only resolves for jobs listed in `needs:`**, however far
  upstream: a `results` job that `needs: [run_case]` cannot read
  `needs.preprocessing.outputs.CASE_DIR` (`Expression Parser Error: job preprocessing not
  in needs`, the step fails at parse time, 0 s, no `logs/<job>/` dir at all). List every
  job whose outputs a job reads (verified 2026-10-01).
- **Nested input groups pass through `with:` as nested maps**, `compute-clusters` item
  included (`cluster: {resource: ${{ inputs.resource }}, scheduler: …, slurm: {…}}` into
  `workflows/openfoam-naca/yamls/general.yaml`'s `cluster` group; dry-run and live run,
  2026-10-01). Dotted keys (`cluster.resource:`) are rejected with `Could not parse
  subworkflow`. A standalone workflow's full form can therefore be its own subworkflow
  interface — the design of `workflows/dakota-openfoam`.
- **The test runner's variant is the YAML's basename:** `tests/<variant>/<test>.json`
  launches `yamls/<variant>.yaml`, so a workflow whose YAML is `general-naca.yaml` keeps
  its tests under `tests/general-naca/`. With a wrong directory `--emit` prints nothing on
  stdout (the error goes to stderr) and a dry-run fed from it fails with `Missing required
  fields: Compute resource` (verified 2026-10-01).
- **A plain-scalar `tooltip:` with a `: ` inside it is invalid YAML** (`mapping values are
  not allowed here`); the platform reports only `Invalid YAML`, so parse the file locally
  (`python3 -c "import yaml; yaml.safe_load(open(f))"`, the system python has PyYAML on
  gcpsmall) before blaming the schema. Use a `|` block for any prose tooltip.
- **A canceled job publishes no outputs, even for steps that completed** (verified
  2026-10-01): a handler job with `if: ${{ !completed }}` that read
  `needs.preprocessing.outputs.SERVER_PID_FILE` after a run cancel failed at parse time
  with `output SERVER_PID_FILE from job preprocessing not found`, although the step that
  wrote the output had finished. Handlers that must work after a cancel read fixed
  paths (`${PW_PARENT_JOB_DIR}/<file>`) and inputs, never upstream outputs
  (`workflows/dakota-openfoam/yamls/general-naca.yaml`, `stop_server_if_unhealthy`).
- **`if: ${{ !completed }}` jobs do run after `pw workflows runs cancel`** (verified
  2026-10-01): the canceled run showed `preprocessing: canceled`, `wait_for_endpoint:
  skipped-failed` and the handler job executed. That is the hook for "kill what a
  plain step started detached when the run did not get to its health check"; a
  step-level `cleanup:` is not, because cleanups always run at the end of their own
  job (docs: yaml-fields), which would kill a detached server right after launch.
- **A login-node-only service can skip `script_submitter`**: start it with
  `setsid pw endpoints run ... > out 2>&1 < /dev/null &` from a plain step
  (`tutorials/endpoint-workflows/03-exit-workflow.yaml`), keep `wait_for_endpoint` as
  the health check (no `skip_cleanups_file`), and add the `!completed` handler above
  because an endpoint that never registered cannot be removed with `pw endpoints
  delete`. `workflows/dakota-openfoam` serves its Pareto page this way.
- **A matrix can follow a form input** (verified 2026-10-01): `matrix: { job_id: ${{ [1,
  2, 3, 4, 5, 6, 7, 8] get 0:(inputs.batch_size) }} }` slices a literal list at submission,
  in a top-level workflow and in a subworkflow whose `batch_size` arrives through `with:`
  from the parent's form. What a matrix still cannot take is a runtime value
  (`needs.*.outputs`), so the per-slot `if: ${{ matrix.job_id <= needs.<job>.outputs.N }}`
  guard stays for the count the run actually produces. Extend the literal to raise the
  ceiling; the guard step that compares N against it should compare against the input,
  not the literal (`tutorials/optimization/iteration.yaml`).
- **The hsp and noaa submitters write SLURM headers in a different order than
  `general`, which decides what a directive can override** (read from the submitters,
  2026-10-02; the `existing`-only lines cannot be exercised from a cloud cluster):
  `general` emits the fixed headers, `--partition` and then the directives; `hsp` adds,
  for `existing` resources, `--account/--qos/--cpus-per-task/--nodes[/--constraint]`
  *before* the directives, so a `#SBATCH --nodes=...` typed or composed in
  `scheduler_directives` still wins (sbatch keeps the last value of a repeated option);
  `noaa` adds `--account/--qos/--ntasks/--nodes` *after* the directives, so there a job's
  shape must go through the submitter's `ntasks` and `nodes` inputs, not through a
  directive (`workflows/openfoam-naca/yamls/noaa.yaml` passes `ntasks: cores_per_case`,
  `nodes: 1`, and composes the same two directives for every other resource). `hsp`
  also has no `define_cleanup_script` input and guards an empty `slurm.time`.
- **Nested subworkflow job dirs live under the parent run's** (HSP, Nautilus, 2026-10-05):
  the subworkflow a `uses:` step at index k of job J ran has its job dir at
  `<run dir>/subworkflows/J/step_k/`, recursively, with its own `logs/`, `subworkflows/`
  and checkout; matrix instances are `workers-0..N-1` (zero-based). A worker's failing
  step of the Dakota-OpenFOAM loop was
  `.../subworkflows/optimization_loop/step_0/subworkflows/workers-3/step_0/logs/preprocessing/step_1/step.out`.
  Read every failure of a run at once with
  `find <run dir> -name step.out | xargs grep -h '^::error' | sort | uniq -c` — the top-level
  Report step only says what the state files say, never why a worker died.
- **A site module may only point at the software.** `module load openfoam/Intel/v2512` on
  Nautilus loads the Intel compilers and OpenMPI 5.0.1, sets `foamDotFile` and prints
  "Issue the command source $foamDotFile": nothing of OpenFOAM is on PATH until that
  `source`, so the form's environment commands are two lines. `module show <mod>` tells
  in advance (a `setenv foamDotFile`, no `prepend-path PATH`). The check in
  `tools/utils/prepare-env.sh` caught it ("blockMesh not found on PATH") but only inside
  each worker; the loop now makes both checks in its own preprocessing, so a wrong
  snippet fails the run in seconds with the tools' own output instead of after a
  re-proposed generation. The same Tcl modulefile aborts in a shell without `SHELL`
  (`Module ERROR: no such variable ... ::env(SHELL)`, seen under `env -i`).
- **"HPCMP login nodes have no internet" is per system, not a rule:** Nautilus's login
  node reaches GitHub and conda-forge (HTTP 200, 2026-10-05), has no Dakota module, and
  the conda-forge Dakota install worked there. Test with `curl` before telling a user
  to bring a module.
- **Two tests launched in parallel on one resource see each other's `pw endpoints run` as a
  leftover** (verified 2026-10-06, marimo + h2o on gcpsmall): the runner ignores only the
  processes that existed before *its own* launch, and every endpoint workflow's default
  `leftover_patterns` include `pw endpoints run`, so a sibling run's service that started
  later shows up at teardown. The runner waits for it ("waiting for cleanup:
  ['proc:pw endpoints run']") and passes once the sibling is torn down, but a sibling that
  serves longer than the wait turns into a false `leftover:proc:pw endpoints run`. Run the
  tests of one resource sequentially (one `run-workflow-test.py` invocation takes several
  test files and runs them in order).
- **Pin the installer together with an exported conda environment** (`workflows/marimo`,
  2026-10-06): an env file exported from a Miniforge base pins `conda`, `mamba` and
  `python`, so applying it on top of a newer Miniforge means downgrading what the installer
  just shipped. `tools/utils/miniforge.sh` honours `MINIFORGE_URL`; the controller sets it
  to the release the file was exported from (the tag `releases/latest` redirected to at
  export time) before `miniforge_bootstrap`, and leaves it unset for `latest` and pasted
  environments. A `conda install` into base may also bump `conda` itself (26.7.2 → 26.7.3
  seen), so the export can legitimately differ from the installer's own version.
- **MLflow 3 answers 403 behind the endpoint while `/health` says 200** (verified
  2026-10-07, `workflows/mlflow`): since 3.5 the server validates the `Host` header
  against an allow-list (localhost variants and private IP ranges by default; `/health`
  and `/version` are exempt, so a health probe sees nothing wrong) and blocks POST/PUT/
  DELETE API calls whose `Origin` is not allow-listed, which the browser UI sends on every
  same-origin POST. The platform proxy forwards the public endpoint host, so the first
  `GET /` got `403` after the `503`s of startup, and the pod log says `Rejected request
  with invalid Host header: <endpoint host>`. Setting `--allowed-hosts` *replaces* the
  defaults (the node's own FQDN is not in them either; its IP is). On a cluster, compose
  `--allowed-hosts` and `--cors-allowed-origins` in a launcher from `PW_ENDPOINT_HOST`
  (exported by `pw endpoints run`, pw ≥ 7.105) plus `hostname -f`, `hostname -s` and
  `hostname -I`; inside a pod served by the `pw-cli` sidecar the host is unknown when the
  container starts, so set `MLFLOW_SERVER_ALLOWED_HOSTS=*` and
  `MLFLOW_SERVER_CORS_ALLOWED_ORIGINS=*` (the pod has no Service; the tunnel is the only way
  in). `pw endpoints run --rewrite-host` alone is not enough: it rewrites `Host`, not
  `Origin`.
- **A pod that is `OOMKilled` in a restart loop looks like a slow start: the endpoint
  answers `503` for the whole budget** (verified 2026-10-07, `workflows/mlflow` on k3sgpu):
  the sidecar registers at once, the proxy returns `503` while nothing listens, and the
  streamed log shows the server starting again and again; only `kubectl get pod -o
  jsonpath='{.status.containerStatuses[0].lastState}'` (or the `BackOff` event) says
  `OOMKilled/137`. MLflow 3's `mlflow server` defaults are 4 uvicorn workers plus a job
  runner of 7 huey processes, about 250 MB each (PSS 2.5 GB measured on gcpsmall), far over
  the k8s forms' 1Gi limit; with `MLFLOW_SERVER_ENABLE_JOB_EXECUTION=false` and
  `--workers 2` it is 700 MB. Measure a new server's footprint on a login node (`ps -o
  rss`, or PSS from `/proc/<pid>/smaps_rollup`) before trusting the shared 512Mi/1Gi
  defaults, and probe the image in a pod with the same limits first (k8s reference §3).
- **A run cancel can leave the endpoint record in `pw endpoints list` as `stopped`**
  (observed 2026-10-07, `workflows/mlflow` on gcpsmall): `pw workflows runs cancel` while the
  service was starting ran the cleanup trap, MLflow shut down gracefully and no process
  survived, but the listing kept `mlflow-<slug>  stopped` until `pw endpoints delete`; the
  `pw endpoints run` process is killed by the trap's `kill -- -$$` before it finishes
  deregistering. When the submitter's own cleanup does the killing (a failed health check),
  the log shows `Endpoint "<name>" deleted.` instead. A `stopped` record is inert, but a
  cancel-cleanup check should look at `pw endpoints list` too and delete what it finds.
- **`pw endpoints run` substitutes `{port}` inside a longer argument** (verified 2026-10-07,
  `workflows/app-testbed`): `-- sh -c "exec python3 server.py {port} >> server.log 2>&1"`
  works, and `--port N` pins the port when a client must know it (a worker's tunnel).
- **A run can leave `~/.ssh/pwcli` on a cloud login node** (observed 2026-10-07, gcpsmall):
  the key was absent before the first app-testbed run and present after it, so a script
  that branches on the key's presence can take another branch on a node a run has used.
- **A step-level `if:` on a boolean form input works, on `run:` and `uses:` steps alike**
  (verified 2026-10-08, `workflows/doe-openfoam`): `if: ${{ inputs.postprocessing.generate_images
  == true }}` skipped the four Design Explorer steps of preprocessing (the install, the detached
  `pw endpoints run`, the liveness check and the `wait_for_endpoint` call) when the form said
  `false`, and the steps after them ran. That is how a `uses:` step is made optional: a bash
  guard cannot skip a subworkflow call.
- **`strategy.max-parallel` takes a form input** (verified 2026-10-08, `workflows/doe-openfoam`):
  `max-parallel: ${{ inputs.doe.max_parallel }}` with 4 ran four of six matrix workers at once
  and the other two when slots freed. With it the login-node mode has a cap on concurrent
  solvers, which `batch_size` alone does not give a sweep.
- **A heredoc inside a Python patch script fed through a bash heredoc** ends the outer one at
  the first line that matches its terminator (`EOF` inside `<< 'EOF'`): Python then fails to
  parse and bash runs the rest of the file as commands. Write the patch to a file and run it, or
  pick an outer terminator no inner script uses (`PYEOF`).
- **pvpython backend selection and exit hangs** (ParaView 6.1.1 on gcpsmall, 2026-10-08) are in
  [software/paraview.md](software/paraview.md): name the OSMesa window with
  `VTK_DEFAULT_OPENGL_WINDOW`, end the script with `os._exit()`, bound the run with `timeout`
  and judge completeness by a file written last.
- **A matrix can be sized by a ternary over form inputs, but quote the whole value**
  (verified 2026-10-08, `workflows/doe-openfoam`, run holy-worm): `job_id: "${{ [1, ..., 32]
  get 0:(inputs.doe.method == 'csv' ? 32 : inputs.doe.n_cases) }}"` expanded to 32 slots
  when the form said `csv` (5 ran, the rest skipped by the runtime guard). Unquoted, the
  ternary's `: ` makes the line invalid YAML and the platform answers only `Invalid YAML`.
- **An `editor` input keeps tabs**: a table pasted from a spreadsheet reached the run's
  heredoc tab-separated (verified 2026-10-08, same run), so a parser can split on them.
- **Publish step outputs from a file, not from a program's stdout**: `prog | tee -a
  $OUTPUTS` also sends its `::notice::` lines there, and a `set -e` step without
  `pipefail` hides the program's failure behind `tee`'s success. Write `KEY=value` lines
  to a file and `cat` it into `$OUTPUTS` (`workflows/doe-openfoam`, Sample the Designs).
- **Quotes inside `${var:+...}` in an unquoted heredoc are dropped**: a start step wrote
  `${pareto_url:+--link "Pareto front=${pareto_url}"}` into a generated script and the
  script got `--link Pareto front=https://...`, two arguments; the server exited with
  `unrecognized arguments` and the liveness check failed the run (2026-10-08,
  `workflows/dakota-openfoam`, run vocal-magpie). Build the argument before the heredoc
  with `printf -v arg -- '--link %q' "Pareto front=${url}"` and write `${arg}`.
- **`range` and `fromJSON` are not on activate.parallel.works yet** (checked 2026-10-08, CLI
  v7.105.0): core PR #20674, merged into core's canary, adds `range` (`${{ 1 range inputs.n + 1 }}`
  gives 1..n) and `fromJSON`, which would size a matrix straight from a form input. On
  activate.parallel.works a dry-run of `range inputs.count` fails with `Expression Parser Error:
  max recursion exceeded`; a run renders `${{ range(inputs.count) }}` as the text `range3` and
  `${{ fromJSON(inputs.json) }}` as ``fromJSON`[1, 2, 4]` `` (the keyword glued to its argument,
  the old parser), and a matrix over `fromJSON` fails with `Could not expand matrix jobs`. Keep
  the sliced literal list (`[1, ..., N] get 0:(inputs.n)`) until a run renders
  `${{ range(3) }}` as `[0,1,2]`; then `job_id: ${{ 1 range inputs.n + 1 }}` replaces it in
  `workflows/doe-openfoam` and `workflows/dakota-openfoam/yamls/iteration-naca*.yaml`, and
  the n_cases and batch_size caps can go.
