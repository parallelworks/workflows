# Activate (Parallel Works) platform reference

Dense, copy-paste-ready facts for building workflows on the Activate platform, verified
on live runs against the workflows in this repo (one directory per workflow under
`workflows/`, tutorials under `tutorials/`, no version suffixes: git tags version the
repo). Facts carry the date or CLI version they were checked with; the CLI was
`v7.105.0` on 2026-10-12.

## Official documentation (authoritative — consult when in doubt)

This skill is a snapshot and **the platform docs are the source of truth**. They are
updated over time, so they may describe newer behavior than what is captured here. If
anything below conflicts with the docs, or a CLI flag / YAML field doesn't behave as
documented here, **trust the docs and fix this file** (Step 5 of the methodology):

- Building workflows — <https://parallelworks.com/docs/run/workflows/building-workflows>
  (subpages: [YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
  [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions))
- Endpoint sessions — <https://parallelworks.com/docs/run/sessions/endpoints>
- `pw endpoints` CLI — <https://parallelworks.com/docs/cli/pw/endpoints>
- `pw` CLI — <https://parallelworks.com/docs/cli>

## Contents

1. Mental model: workflow, job, endpoint, subworkflow; where a job runs is where you debug
2. Resources: the resource object, passing one from the CLI, the workspace
3. Workflow YAML schema: top-level keys, jobs and steps, subworkflow calls, inputs, expressions, DAG and outputs, matrix, retries
4. Choosing the deployment variant (`general` / `emed` / `hsp` / `noaa`)
5. `script_submitter`: submission modes, inputs, scheduled-job behavior, failure path
6. `pw` CLI reference: workflows, runs, endpoints, kube, ssh, forward
7. Job directory layout
8. Where to look for working patterns (the repo's workflows and tutorials)
9. Getting your workflow code onto the node (`parallelworks/checkout`)
10. Endpoints: `pw endpoints run`, tokens, naming, lifecycle, probing, path-based endpoints
11. AI agents and LLM-backed services: the platform LLM endpoint, `PW_API_KEY` (pw-auth.md), `--openai`, Ollama

---

## 1. Mental model

- A **workflow** is a YAML file. It defines an input **form** (`on.execute.inputs`),
  one or more **jobs**.
- Jobs run **on a resource**, reached over SSH (`ssh.remoteHost`). Steps are shell
  (`run:`) or reusable **actions** (`uses:`). Jobs form a DAG via `needs:`.
- A web service is exposed as a **`pw` endpoint**: the service side runs
  `pw endpoints run`, which dials out, registers a reverse tunnel, and gets a
  subdomain URL (§10). Every workflow in this repo uses this pattern (converting an
  older one: [session-to-endpoint-upgrade.md](session-to-endpoint-upgrade.md)).
- **Subworkflows** are workflows invoked from a step with `uses:` + `$yaml:` (§3):
  `script_submitter` and `wait_for_endpoint` under every endpoint workflow, and any
  standalone workflow a composed one calls (`doe-openfoam` calls `doe`,
  `openfoam-naca` and `design-explorer`).

### Where jobs run = where you debug (IMPORTANT)
`ssh: remoteHost: ${{ inputs.resource.ip }}` runs that job's steps on the **login
node** of the selected resource. The job directory and any service process live on
**that** node, not necessarily the box you launched `pw` from.
- When this shell runs on a cluster login node (common when the agent works from a
  session on the cluster; compare `hostname` with the resource), choosing that resource
  puts the job dir and process **local**, inspectable with `ls ~/pw/jobs/...` and `ps -x`.
- Otherwise (a laptop, or the `workspace` resource, whose jobs run on the workspace
  node) reach the node with `pw ssh <resource>`, or read the logs through the API
  (`pw workflows runs logs`, §6).

---

## 2. Resources

List with `pw cluster ls` (`-o json` for fields). Status `active` = usable now.

A `compute-clusters` form input resolves to an object with these fields (inside the
workflow, via `${{ inputs.<name>.* }}`):

| field | example | notes |
|-------|---------|-------|
| `id` | `685193ec1bba202cb3341fb7` | |
| `ip` | `34.132.29.251` | login-node IP; **empty for workspace** → step runs locally |
| `name` | `<cluster>` | |
| `type` / `provider` | `google-slurm` | `existing` for a cluster the ACTIVATE agent connects, `managed-cluster` for a managed one, `<cloud>-slurm` for a cloud cluster; both fields carry it in form expressions (`pw cluster ls -o json` fills only `type`). The workspace matches neither: test `name == 'user-workspace'` (or `ip == ''`) |
| `schedulerType` | `slurm` / `pbs` / `''` | `''` when no scheduler (e.g. `existing`, workspace) |
| `namespace`, `user` | `<user>` | |

**Passing a resource via the CLI:** give the **bare name string** and the platform
resolves the full object. Do NOT hand-build the object or hardcode `ip` (login IPs
change when a cluster restarts):
```bash
pw workflows run my-session -i '{"resource":"<cluster>","scheduler":false}'
```
`pw cluster ls -o json` field names differ from the resolved object (`ipAddress` vs
`ip`); rely on name resolution, not the raw cluster JSON.

> **⚠ `compute-resources` inputs do NOT hydrate from the CLI (verified).** Bare-name
> resolution is a `compute-clusters` feature. A `compute-resources` input (the picker
> that also lists kubernetes clusters, used by `*_k8s_*.yaml`) passed as `"<cluster>"`
> or `"pw://<user>/<cluster>"` reaches the workflow as a **raw string** — `.ip`/`.type`
> resolve empty and `ssh.remoteHost` steps **silently run on the workspace exec node**.
> From the UI the picker sends a full object, so this bites CLI testing only. Pass the
> object yourself in `-i`:
> - Cluster: `{"$type":"computeResource","id":"<id>","ip":"<ip>","name":"<cluster>","namespace":"<user>","provider":"google-slurm","schedulerType":"slurm","type":"google-slurm","uri":"pw://<user>/<cluster>","user":"<user>"}`
>   (fresh `id`/`ip` from `pw cluster ls -o json`, mapping `ipAddress`→`ip`).
> - With `$type: computeResource` the server validates `id` against **clusters** — a
>   kubernetes cluster id fails with `Compute resource not found`. Omit `$type` and the
>   object passes through **verbatim, unvalidated**: for a kubernetes cluster send
>   `{"id":"<pw kube ls id>","name":"<k8s-cluster>","type":"kubernetes","uri":"pw://<k8s-cluster>"}`
>   (set the fields the workflow reads: `name` for `pw kube auth`, `type` for the guards).
>   The test runner builds both objects, so a test JSON keeps the portable form: its
>   k8s lane completes `{"name":…,"type":"kubernetes"}` from `pw kube ls -o json`, and
>   its cluster lane expands a `pw://` string into the cluster object above from
>   `pw cluster ls -o json` whenever the YAML declares `compute-resources`.
>   A `kubernetes-clusters` input (standalone `k8s.yaml`,
>   `k8s.cluster`) takes the **bare cluster name**; `kubernetes-namespaces` a string.

**The workspace as a resource:** `include-workspace: true` on a `compute-clusters`
input makes the user workspace selectable. Pass `"workspace"` (aliases:
`user-workspace`). It resolves to `id=user-workspace`, `type=computeResource`,
**empty `ip`** → SSH steps run locally on the workspace node.

---

## 3. Workflow YAML schema

Top of file (enables editor autocomplete; harmless at runtime):
```yaml
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
```

### Top-level keys
| key | purpose |
|-----|---------|
| `permissions` | `['*']` lets the workflow and its subworkflows run any `pw` command the launching user can; needed for every `pw` call but `pw agent open-port`. |
| `jobs` | the job DAG |
| `env` | workflow-level environment variables injected into every job/step's runtime env. The platform puts `PW_API_KEY` there on its own; an `env:` block carries a key the user hands the workflow ([pw-auth.md](pw-auth.md)). **⚠ Do NOT also name an input *group* `env`** if this block references `${{ inputs.env.* }}`: the shared `env` name makes the expression engine recurse → `400 Expression Parser Error: max recursion exceeded`, which fails **both `--dry-run` and `pw workflows run`** (the web UI may still submit it). Name the group e.g. `env_vars`. |
| `'on'.execute.inputs` | the input form (note the quoted `'on'` to avoid YAML's bool) |
| `configurations` | named sets of saved inputs (`configurations.<name>.inputs.<input>: value`), loadable with `pw workflows run --saved-inputs <name>` |
| `timeout` | workflow-level timeout (`30m`, `2h`, `1d`); also per job and per step, and every level applies |
| `needs.organizationVariables` | org variables the workflow refuses to run without. Account variables a repository workflow declares (`variables:`) are granted on its first run (`--trust` on the CLI; `pw workflows permissions ls\|revoke` reviews them) |

### `jobs.<name>`
```yaml
jobs:
  myjob:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}   # run steps on this host (empty ⇒ local)
    working-directory: ${{ inputs.service.rundir }}   # optional; default = job dir
    needs: [otherjob]                          # DAG edges
    if: ${{ inputs.resource.type != 'kubernetes' }}   # conditional execution
    steps:
      - name: A shell step
        run: |
          echo hello
        cleanup: |                              # runs when the JOB ends, success included, in reverse step order
          echo cleaning up
      - name: A reusable action
        uses: parallelworks/checkout
        early-cancel: any-job-failed            # cancel this STEP if any job fails before it finishes
        with: { ... }
      - name: A step with its own target and tolerance
        ssh: { remoteHost: ${{ needs.agent.outputs.remoteHost }} }   # step-level ssh overrides the job's; `ssh: null` = the workspace
        ignore-errors: true                     # a non-zero exit does not fail the job
        timeout: 10m                            # also at job and workflow level; every level applies
        run: ...
```

### Steps: `run` vs `uses`
- `run:` — shell. `set -x` for tracing. Emit annotations with
  `echo "::notice::msg"`, `::warning::`, `::error title=Error::msg`, `::group::`/`::endgroup::`
  (`::debug::` stays hidden until *Show Debug*; at most 50 per step). An `::error::` line
  reports a problem but does **not** fail the step — `exit 1` does; `pw workflows runs
  errors` lists them and exits non-zero when any exist.
- Export step outputs: `echo "KEY=value" | tee -a $OUTPUTS`, then read with
  `${{ needs.<job>.outputs.KEY }}` or `${{ needs.<job>.steps.<id>.outputs.KEY }}`. The
  docs plan to stop publishing step outputs to the job level automatically; the
  forward-compatible form gives the step an `id:` and maps it in a job-level `outputs:`
  block (`outputs: { KEY: ${{ needs.<job>.steps.<id>.outputs.KEY }} }`). The repo's
  `tee -a $OUTPUTS` idiom still works (verified 2026-10-12).
- `uses:` — an action. Common ones seen in the repo:
  - `parallelworks/checkout` — clone a git repo **into the job dir** (`PW_PARENT_JOB_DIR`).
    `with: { repo, branch, sparse_checkout: [paths...], path }` (`repo` and `branch` are
    required, `path` defaults to the run dir, list items may be templated).
    Verified: `sparse_checkout: [workflows/<name>/app]` materializes
    `${PW_PARENT_JOB_DIR}/workflows/<name>/app`, visible to later `needs:`-dependent jobs.
    This is **the** way to get code onto the node — see §9. Every real workflow YAML in
    the repo (e.g. `workflows/webshell/yamls/general.yaml`) starts preprocessing with a
    `parallelworks/checkout` of `parallelworks/workflows` + a `sparse_checkout` of `workflows/<name>/app` (or an impl subdir).
  - `parallelworks/cancel-jobs` — cancel sibling jobs (`with: { jobs: [...] }`, default
    all; inside a subworkflow pass no `slug`/`workflow`, so it cancels the subworkflow's
    own jobs, not the caller's)
  - `parallelworks/scheduler-agent`, `parallelworks/wait-for-agent` — provision a compute
    node (`scheduler-type`, `scheduler-flags`, `script-headers`; outputs `agentId`,
    `remoteHost`, `sshPort`) and wait for it (`agentId`, optional `schedulerJobId` to fail
    early); `script_submitter`'s `use_scheduler_agent` wraps them
  - `github/parallelworks/workflows@canary` + `$yaml:` — call a subworkflow (below)

### Calling a subworkflow
```yaml
- uses: github/parallelworks/workflows@canary
  with:
    $yaml: workflows/script_submitter/v3.6/general.yaml   # path within this repo
    ...subworkflow inputs...
# or a marketplace slug:
- uses: marketplace/script_submitter/v3.6
  with: { ... }
```
- `with:` carries the called workflow's form inputs by name; a nested group passes as
  a nested map (`cluster: {resource: …, slurm: {…}}`), never as dotted keys. `$yaml`
  goes inside `with:` and picks the file; the docs only describe
  `github/<owner>/<repo>@<ref>` running the repo's root `workflow.yaml`.
- Data crosses the call as files: pass the paths the subworkflow reads and writes
  (under the caller's `${PW_PARENT_JOB_DIR}`) and read what it leaves there. No
  workflow here reads a subworkflow step's outputs; `doe-openfoam` reads the sampler's
  `doe.env` from the `cases_dir` it passed in. A matrix slot hands per-slot data the
  same way, through paths built from `matrix.job_id` (pitfalls).
- A workflow may never call itself, even indirectly, and calls nest at most 5 deep
  (docs); `dakota-openfoam` → its iteration YAML → `openfoam-naca` →
  `script_submitter` is already a chain of four.

### Inputs (`on.execute.inputs`)
Each input has a `type`. Groups nest via `items`. Visibility via `hidden`/`ignore`
expressions (`ignore: ${{ .hidden }}` mirrors the hidden flag).

| type | renders / resolves to |
|------|----------------------|
| `string`, `number`, `boolean` | scalar (`number` takes `min`/`max`/`step`/`slider`; give a whole-number input `step: 1`). There is **no `integer` type**: the launch form renders nothing for a type it doesn't know but still submits the default, so the input can't be changed from the form, while `pw workflows run -i` still passes a value and hides the problem. Verified 2026-09-16 through `-i`, with an input then typed `integer`: a number renders as bare digits in the shell (`$(( n + 1 ))` works) and compares numerically in expressions (`inputs.n == 5`, `inputs.n > 3` true; a JSON `"7"` in `-i` behaves like `7`); an **optional input left unset renders empty** — guard with `${v:-default}` — and `inputs.m == ''` is *false* for it; an explicit `""` for a top-level input is default-filled |
| `editor` | multi-line text box (e.g. scheduler directives) |
| `dropdown` | `options: [{label, value}]` |
| `group` | container with `items:` (values at `inputs.<group>.<item>`) |
| `list` | repeater the user adds rows to; each row has the fields under `template:`. At runtime `${{ inputs.<name> }}` is a **JSON array** — parse with `python3`, don't slice in shell. Items can themselves be `compute-clusters` (pass `[{"resource":"<name>"}]` in `-i`). See `tutorials/endpoint-workflows/07-failover.yaml`. |
| `compute-clusters` | resource picker → resource object (§2); `include-workspace: true/false` |
| `slurm-partitions` | partition dropdown; needs `resource: ${{ inputs.resource }}` |
| `password`, `multi-dropdown`, `header` | masked string; multi-select (`options`); a label-only row (`text`) |
| `slurm-accounts`, `slurm-qos` | dropdowns fed from the resource (`resource`, `account`, `partition`) |
| `kubernetes-clusters`, `kubernetes-namespaces`, `kubernetes-*` | Kubernetes pickers (`clusterName`, `namespace`); [k8s-workflows.md](k8s-workflows.md) |

Common attributes: `label`, `default`, `tooltip`, `description` (always visible),
`optional: true`, `disabled`, `hidden: <expr>`, `ignore: <expr>`, `collapsed: true`. An
input whose `ignore` is true at launch is neither sent nor required, so it needs no
`optional: true` (the condition itself: pitfalls, "Inputs and expressions"). A
`string`'s `default` fills the form only with `prefillDefault: true` (otherwise it applies
when the run has no value); a `dropdown` whose `options` are keyed by another input
(`option-key: ${{ inputs.x }}`) is dynamic. Expressions read other inputs, `org.<VAR>`
(organization variables set by admins, e.g. `${{ org.JUICE_TOKEN }}`), `var.<NAME>`
(your own variables, `pw variables`, secret by default) and `${{ .hidden }}`.

The form renders `description` under the label, always, and `tooltip` behind a ?; an
input without `label` shows its key name capitalized (`Scheduler_directives`). The
copy rules (sentence case, statements for booleans, a description for what the user
must know before submitting, `step: 1` on counts, the walltime format): AGENTS.md,
"Form text".

### Expressions & env
- `${{ ... }}` — platform templating, evaluated **before** the shell sees the line
  (inputs, `needs.*.outputs`, `org.*`, comparisons). The parser is whitespace-sensitive
  (`${{ 1 + 1 }}` is 2, `${{ 1+1 }}` the string `1+1`; only `!` goes unspaced) and never
  throws: a malformed expression renders as some string, so check rendered values in
  `step.out`. `==` is loose (`1 == true`), `===` strict; `??` gives a fallback; `get`
  indexes lists and maps.
- `${VAR}` / `$VAR` — ordinary shell, evaluated at runtime on the node. Only expands
  inside something a shell actually runs: `run:`, `cleanup:`, or a `with:` value that
  ends up in the subworkflow's `run:`.
- `working-directory` is resolved by the platform, not a shell: `${PW_PARENT_JOB_DIR}/x`
  there creates a directory literally called `${PW_PARENT_JOB_DIR}`. Same for a `with:`
  value that ends up as one (`script_submitter`'s `rundir`). Use
  `${{ env.PW_PARENT_JOB_DIR }}/x` instead.
- Useful runtime env vars: `PW_PARENT_JOB_DIR` (parent run's job dir — use for all
  shared paths), `PW_JOB_DIR`, `PW_JOB_ID`, `PW_RUN_SLUG` (the run's slug — the argument
  `pw workflows runs cancel` takes), `PW_USER`, plus all `PW_*`. The
  `inputs.sh` convention captures these with `env | grep '^PW_'`.

### Multi-job orchestration (DAG, outputs, fan-out — all verified)
Not every workflow needs a subworkflow — plain job orchestration is a first-class
use. The job graph gives you sequencing, data flow, conditionals, and parallelism:

- **Sequencing & sharing:** `needs: [a, b]` makes a job wait for `a` and `b`. All
  jobs in a run share `${PW_PARENT_JOB_DIR}`, so a file one job writes there is
  readable by later jobs (`cd ${PW_PARENT_JOB_DIR}` at the top of multi-step jobs).
- **Data flow via `$OUTPUTS`:** in a step, either `echo "KEY=value" | tee -a $OUTPUTS`,
  or pipe a program whose stdout is already `KEY=value` lines:
  `python3 analyze.py | tee -a $OUTPUTS`. Consume downstream as
  `${{ needs.<job>.outputs.KEY }}` (or `${{ needs.<job>.steps.<id>.outputs.KEY }}`).
- **Conditional steps/jobs:** `if: ${{ needs.analyze.outputs.good_fit == 'true' }}`.
  String equality is reliable; compute booleans **upstream** (e.g. in Python) and
  emit them, rather than doing numeric comparisons inside the expression. `if:` also
  calls **status functions** — `success()`, `failure()`, `cancelled()` (also
  `canceled()`) and `always()`, negated with `!` — that look at the job's earlier
  steps (on a step) or at the jobs in `needs` (on a job). No `if:`, or an `if:` that
  calls none of them, also requires `success()`; calling one replaces that check.
  They combine with expressions (`if: ${{ failure() && inputs.fallback }}`; quote a
  ternary). The keywords ACTIVATE v7.69 added (`completed`, `error`, `canceled`,
  `never`, their `!` forms, and `success`, `failure`, `cancelled` without parentheses)
  were removed in v7.112: a bare word is now a non-empty string, which is true
  (`${{ !completed }}` is always false; pitfalls). The exception is the word `always`
  alone, the older spelling of `always()`, which still works; write `always()`.
  `if: ${{ always() }}` steps run in order and, like `cleanup:` steps, keep running
  through a cancel. See `tutorials/if-conditions/`.
- **Fan-out / fan-in:** sibling jobs that share a common `needs` but don't depend on
  each other **run concurrently**; a downstream job with `needs: [w1, w2, w3]` joins
  them. (Verified: 3 workers logged the same finish second.) For N identical workers,
  use a **matrix strategy** (`strategy.matrix`) rather than hand-copying jobs — see
  `tutorials/endpoint-workflows/05-matrix.yaml`. `strategy.fail-fast` defaults to
  **true** (one failing worker cancels the rest; set `fail-fast: false` for a sweep that
  should finish the others), `max-parallel` caps concurrency, `matrix.include`/`exclude`
  adjust the combinations.
- **Matrix expansion is STATIC (verified 2026-09-28):** the platform expands
  `strategy.matrix` at submission, so it only iterates values concrete then — form
  inputs or literals. A runtime-computed list fails **both dry-run and the real run**
  with `Could not expand matrix jobs`, whether it reaches the matrix as a
  `needs.*.outputs` value or as a subworkflow `list` input fed from `with:`. To fan
  out over a computed set, use a **guarded static matrix**
  (`parallelworks/dcs-workflow@v4` honda-japan.yaml `workers` job): a matrix list
  concrete at submission (`job_id: ${{ 1 range inputs.n + 1 }}`, or a literal `[1..N]`) plus a job-level
  `if: ${{ matrix.job_id <= <width> }}` guard, optionally `max-parallel`. The guard's
  width can be a form input (honda) **or a runtime output** —
  `if: ${{ matrix.job_id <= needs.gen.outputs.N_CASES }}` compares numerically and
  skips the excess workers (verified live 2026-09-28: 2 of 4 ran; a downstream
  `if: ${{ always() }}` job, then spelled `always`, joined the partially-skipped matrix
  cleanly, and a per-case `rundir: ${{ needs.gen.outputs.ITER_DIR }}/case_${{ matrix.job_id }}`
  composed fine into script_submitter's `with:`). Worked, tested example:
  `tutorials/optimization/iteration.yaml` (`workers` job — computed case set from an
  optimizer, all of the above in one place). **A form input is concrete at submission,
  so a matrix can be sized by one:** `job_id: ${{ 1 range inputs.batch_size + 1 }}`
  expands to `[1, ..., batch_size]` (`range inputs.n` alone is `[0, ..., n-1]`), so the
  run shows exactly `batch_size` workers, capped only by the form's `max:` (256 there,
  inside the platform's 1000-reference budget per run: pitfalls); it also works on a
  subworkflow input fed from the parent's `with:` (verified 2026-10-13, that tutorial,
  `workflows/dakota-openfoam` and `workflows/doe-openfoam`; before `range` reached the
  platform the same was done by slicing a literal list, `[1, ..., 8] get
  0:(inputs.batch_size)`). Keep the runtime guard for the count actually produced.
  Fallback when the matrix must live in a
  separate workflow: a step can submit it as a **fresh run** with the in-run client —
  `pw workflows run <abs yaml> -i '<json>'` (or `-i <file>`) under
  `permissions: ['*']` — and poll `pw workflows runs view <slug>`; the inner run's
  matrix expands normally, `PW_MATRIX_INDEX` set per worker (verified live).
- **`PW_MATRIX_INDEX` carries the matrix worker's index** (verified): `0`, `1`, … in a
  matrix job's steps AND inside the jobs of a subworkflow invoked from a matrix job;
  unset outside a matrix, so read it as `${PW_MATRIX_INDEX:-}`. Use it whenever
  per-worker names must be unique and two workers may target the same resource — see
  the endpoint naming in `tutorials/endpoint-workflows/04-subworkflow.yaml`. Do NOT
  parse `PW_JOB_DIR` for it: at the matrix job's own level the path has no worker
  component at all. (`PW_PARENT_JOB_DIR` stays the top-level run dir at every nesting
  depth.)
- **A step that fails skips the rest of its job's steps** (verified: run status `error`,
  later steps never run) — same when the job is canceled. So steps placed AFTER a
  blocking `uses:` step are a "it returned cleanly" handler, reached only when the
  subworkflow comes back without failing. The production endpoint workflows
  build their failure tail on exactly this: happy path = the waiter cancels the
  submitter job (tail skipped); service died early = the submitter step returns, and
  the tail cancels the waiter + exits 1 with an `::error` annotation; submitter fails
  hard = the tail is skipped and the waiter's `early-cancel: any-job-failed` ends the
  run. See `tutorials/endpoint-workflows/04-subworkflow.yaml` and
  `workflows/*/general.yaml` (v5 endpoint pattern).
- See `tutorials/endpoint-workflows/` (jobs, `needs`, `$OUTPUTS`, conditional `if:`,
  endpoints — staged README) and its `05-matrix.yaml` (fan-out workers via a matrix
  strategy — the pattern to copy for a parameter sweep).

### Step retries & attempt-aware logic (verified — see `tutorials/endpoint-workflows/07-failover.yaml`)
A step can declare a `retry` block; it re-runs the step while it exits **non-zero**:
```yaml
- name: Probe
  retry:
    max-retries: 2     # EXTRA attempts after the first (so 3 total); may be an expression; 10 when omitted inside a retry block
    interval: 2s       # wait between attempts (default 5s)
    timeout: 60s       # cap on ONE attempt; default 30s, which kills a slow subworkflow attempt (pitfalls) — size it for the whole attempt
  run: |
    ssh "${TARGET_IP}" nvidia-smi   # exit code drives the retry
```
- **`exit <code>` drives it:** zero = success (stop), non-zero = retry. A step that
  exhausts its retries ends the run as **error**, and a later `if: ${{ always() }}`
  step that exits 0 does not change that (verified 2026-10-16 with the older spelling
  `always`, probe run settling-hedgehog: the step failed after its retries, the
  `if: always` step ran and exited 0, the job and the run ended `error`). Use that
  step to report what happened, never to turn the run green.
- **Per-attempt env vars:** `PW_WORKFLOW_STEP_CURRENT_RETRY` (0 on the first try) and
  `PW_WORKFLOW_STEP_MAX_RETRIES` are exported each attempt. `index % N` over a list turns
  the retry counter into a **round-robin selector** (fail over to the next resource).
- **Per-attempt failover into a subworkflow `with:` block now works (re-verified July
  2026 — an earlier platform version rejected it).** The shape:
  `${{ inputs.workers get env.PW_WORKFLOW_STEP_CURRENT_RETRY get resource get ip }}`
  resolves inside a `uses:` step's `with:`, advancing with the retry counter — verified
  live with a dead first resource failing over to a healthy second
  (`tutorials/endpoint-workflows/07-failover.yaml`). Two caveats still apply:
  (1) a list item picked with `get` does **not** pass through `with:` as one object —
  rebuild the resource **field by field** (`id`, `ip`, `name`, `namespace`, `provider`,
  `schedulerType`, `type`, `uri`, `user`); (2) a resource passed as a **URI string does
  not re-hydrate** through `with:`. A retried `uses:` step surfaces only the **last**
  attempt's logs via `pw workflows runs logs`; evidence of earlier attempts is the wall
  clock and whatever per-attempt output you emit yourself. (`subworkflows/<job>/step_N`
  in the job-dir path is the **step index within the job**, not the attempt number —
  retried attempts reuse the same directory.) Per-attempt SSH failover on a plain `ssh:`/`run:` step is
  shown in `tutorials/endpoint-workflows/07-failover.yaml`; for a matrix-style
  per-item resource, `matrix.worker.resource` passes as a native object.
- **Retry-as-loop with depth-3 subworkflow nesting works (verified 2026-09-28):** a
  retried `uses:` step → subworkflow → subworkflow → script_submitter ran 3 full
  iterations. The inner workflow's deliberate `exit 1` fails the parent step → retry
  = next loop iteration; `exit 0` ends the loop. State kept in files under the top
  job's own working dir (paths passed down as inputs, published via `$OUTPUTS`)
  persists across attempts. Remember attempt ≠ iteration: keep the true iteration
  counter in a state file, and let a trailing `if: ${{ always() }}` step map a status
  file (CONVERGED/CONTINUE/FAILED) to the run's final exit. The full pattern —
  retry-as-loop + guarded static matrix + results-file protocol, tested end-to-end
  (run dear-crow, 2026-09-28) — is `tutorials/optimization/` (staged README);
  `retry.max-retries: ${{ inputs.<group>.<n> }}` from a form input also verified there.
- **`ignore-errors: true` works on a `uses:` step** (verified 2026-10-16, run finer-bunny:
  a subworkflow ending in error, the next step ran, the job and the run completed). It is
  one way to give a retried call a verdict of its own when the callee cannot be
  changed: a thin attempt workflow calls it with `ignore-errors`, then a step reads the
  files it left and exits 0 (over) or 1 (retry). When the callee is yours, a hidden
  input is simpler and saves the nesting level: `openfoam-naca`'s `restart.attempt`
  makes its results step exit 0 on a case that failed on its own (final) and 1 on an
  interrupted one, so `yamls/general-restart.yaml` retries `general.yaml` directly. A retried
  step that fails is retried whatever a later `if: always()` step in the same job
  returns, so the verdict must be the status of the first failing step, not of a step
  after it.
- **`max-retries` can be computed:** `max-retries: ${{ needs.<job>.outputs.N - 1 }}` —
  arithmetic is evaluated in the expression layer. An upstream step writing `N` to
  `$OUTPUTS` lets a later step in the **same job** size its own retries
  (`needs.<this-job>.outputs.N`; outputs written earlier in a job are visible later in it).
- **Per-step targets:** a step-level `ssh:` block overrides the job's (`ssh: null` runs the
  step on the workspace; `jumpNodeHost` hops through a login node), but it is fixed when
  the step renders. Running `ssh "$HOST" cmd` *inside* a step lets the step change its
  target per attempt — that's how round-robin failover reaches a different resource each try.

---

## 4. Choosing the deployment variant (`general` / `emed` / `hsp` / `noaa`) — IMPORTANT

Not every workflow has variants: golden rule 2 in SKILL.md says when one is needed.
Where they exist, do **not** default to `general`. Pick the variant that matches the
**Activate platform host you are on** (check `pw context list` → the `user@host` /
platform host):

| Platform host | Variant |
|---|---|
| `cluster.einsteinmed.edu` | `emed` |
| `noaa.parallel.works` | `noaa` |
| `activate.hpc.mil` | `hsp` |
| anything else | `general` |
| unclear | **ask the user** |

Write what the variants share once, so the YAMLs differ only where the platform
does and a change lands once. A step body only this workflow runs goes into one
script under `app/`: a one-line step calls it with its inputs as environment
variables, `OUTPUTS` included (`workflows/openfoam-naca/app/read-results.sh`). Logic
many workflows call, or that takes several steps or jobs, is a subworkflow they call
(`workflows/wait_for_endpoint`, `workflows/script_submitter`; §3). A `noaa` variant
resolves the cluster's shared software directory through
`tools/utils/shared-software-dir.sh` (login host in, directory out, nothing for an
unknown host; sparse-checkout `tools/utils`) and decides itself whether to install
there, reuse it read-only or fall back.

The same choice applies to **`script_submitter`** (§5) and to the **resource form
section** of your YAML: the `resource`, `scheduler`, `slurm`, and `pbs` input groups and
the `with:` block you pass differ per variant (e.g. `emed`'s `slurm` has `slurm_options`,
`partition_default`, `cpus_per_task`, `mem`, `gres_gpu_*` instead of `general`'s
`partition`). **Copy the cluster/slurm/pbs form and the `with:` mapping from the matching
`workflows/<name>/yamls/<variant>.yaml`**, not from a `general` example — `--dry-run`
does NOT catch mismatched fields (unknown fields pass silently, verified 2026-09-16),
so the mistake surfaces only at run time.

---

## 5. `script_submitter` subworkflow (run a script on a resource)

Path: `workflows/script_submitter/v3.6/<deployment>.yaml`. Marketplace slug:
`marketplace/script_submitter/v3.6`.
**Pick the deployment variant (`general`/`emed`/`hsp`/`noaa`) by the same host rule as
§4**, and match the `slurm`/`pbs` `with:` block to that variant.

Submission modes (auto-selected from inputs):
- `scheduler:false` → run directly on the login node over SSH.
- `scheduler:true` + `slurm.is_enabled`/`pbs.is_enabled` → `sbatch`/`qsub`, monitored to completion.
- `use_scheduler_agent:true` → provision a compute node via `parallelworks/scheduler-agent` (single-node only; recommended for single-node scheduler jobs).

**Key inputs:** `resource`, `rundir`, then either `script` (inline text, when
`use_existing_script:false`) or `use_existing_script:true` + `script_path`; `shebang`
(default `#!/bin/bash`); `scheduler`, `use_scheduler_agent`; `slurm`/`pbs` groups;
`define_cleanup_script` + `cleanup_script_path` (cleanup runs on cancel, 300s timeout,
on the compute node for scheduled jobs); `skip_cleanups_file` (optional, hidden) — if
the file exists when the job ends, every cleanup is skipped and the script/job is left
running. **Only endpoint workflows use it** (`wait_for_endpoint` touches it so the
service outlives the run); leave it unset for batch jobs. Output → `run.<JOBID>.out` in `rundir`
(JOBID = the run slug, e.g. `run.my-session-00001.out`).

**Invoke it as a subworkflow** (verified — batch compute, no endpoint):
```yaml
run_my_job:
  needs: [preprocessing]
  ssh:
    remoteHost: ${{ inputs.resource.ip }}
  steps:
    - uses: github/parallelworks/workflows@canary
      early-cancel: any-job-failed
      with:
        $yaml: workflows/script_submitter/v3.6/general.yaml
        resource: ${{ inputs.resource }}
        rundir: ${{ env.PW_PARENT_JOB_DIR }}          # platform-resolved: ${PW_PARENT_JOB_DIR} would be literal here
        use_existing_script: true
        script_path: ${PW_PARENT_JOB_DIR}/my/run.sh   # written by preprocessing
        shebang: '#!/bin/bash'
        scheduler: ${{ inputs.scheduler }}             # false ⇒ login node; true ⇒ sbatch/qsub
        use_scheduler_agent: false
        define_cleanup_script: false                   # cleanup_script_path not needed then (hidden+ignored)
        slurm: { is_enabled: ${{ inputs.slurm.is_enabled }}, partition: ..., time: ..., scheduler_directives: ... }
        pbs:   { is_enabled: ${{ inputs.pbs.is_enabled }}, scheduler_directives: ... }
```

> **Subworkflow required-input check (verified 2026-09-16: `pw` dry-runs + a live run
> on a cloud cluster):** `--dry-run` fails with the terse `Could not parse subworkflow` when a
> non-optional subworkflow input with no default is missing from `with:` — the message
> never names the field. The check honors the subworkflow's `hidden`/`ignore` rules
> under the values you pass: `script_submitter` with `define_cleanup_script: false`
> accepts a missing `cleanup_script_path` (dry-run and real run both pass) and rejects
> it once `define_cleanup_script: true`. It also rejects it when `define_cleanup_script`
> is left out, on every variant: the flag's `default: false` does not reach
> `cleanup_script_path`'s `hidden:` test, so always pass the flag, `false` when unused
> (verified 2026-10-20, dry-runs on gcptest). `--dry-run` does NOT flag unknown fields
> (`partition_default` passed to `general`, or `general`'s `slurm.partition` passed to
> `emed`) — they pass silently, and at run time an undeclared field still reaches the
> subworkflow as `inputs.<field>` (verified 2026-10-20: the `hsp` submitter, before it
> declared the cleanup inputs, ran the caller's cleanup script).

> **Best practice — paths inside the submitted script:** `script_submitter` `cd`s
> into `rundir` before running your script, so reference files **relative to rundir**
> (`my/run.sh`, `./out.json`), **not** `${PW_PARENT_JOB_DIR}` — for SLURM/PBS jobs the
> script runs on a *compute node* where `PW_PARENT_JOB_DIR` may not be exported. The
> home/run filesystem is shared (NFS) between login and compute nodes, so relative
> paths resolve there.

**`scheduler:true` behavior (verified on google-slurm):** `sbatch` submits to the
default partition; a cloud-burst node goes `idle~ → CONFIGURING (CF) → RUNNING`
(provisioning a fresh VM is slow — observed **8+ minutes**, and it can stall:
`scontrol show node` shows `POWERING_UP + NOT_RESPONDING` and `sacct` shows the job
`RUNNING` while the VM is still booting and the script hasn't started). Poll with long
intervals; don't assume a hang — but a stuck cloud node is also possible (infra, not
your workflow). When the node responds, your script runs and writes `HOSTNAME` = the
compute node. The login-node path (`scheduler:false`) is the fast, reliable check;
use SLURM when you genuinely need a compute node.

`script_submitter` builds the sbatch script as (verified): shebang → `#SBATCH` headers
(`--job-name`, `--time`, `--chdir=<rundir>`, `-o/-e → run.<slug>.out`, then the form's
`scheduler_directives`, one per line, the `#SBATCH`/`#PBS` prefix added where a line has
none; verified 2026-10-27) → `hostname > HOSTNAME` → your script body. `--chdir` is why
your script's cwd is `rundir` on the compute node (relative paths work). A scheduled
batch run's job dir adds `headers.sh`,
`run.sh` (the sbatch script), and `run.<slug>.out` (job stdout/stderr) alongside your
own files and outputs. Since the workflow exec node is the cluster **login node**, watch it
live there with `squeue` / `sinfo` / `sacct`. On cancel, `script_submitter` runs
`scancel` (and your cleanup script, if any, on the compute node).

**Use it directly** when your task is "run this script/sim on a cluster" with no web
service (batch compute). When you also need a live web UI, keep the same submitter and
wrap the start script in `pw endpoints run` — the endpoint pattern (§10).

---

### Failure path of a submitted script (verified 2026-09-09, openvscode on a cloud cluster)
`script_submitter` does **not** forward the script's exit code: "Wait for Script" only polls
the pid, then "Cancel Streaming" stops the `stream_output` `tail -f` job and the
subworkflow *completes*. A workflow's error handling therefore lives in the parent's
steps after the `uses:` step (`Cancel Wait for Endpoint` + `Exit Workflow with Error`).
**Every job that runs a script (`ssh_job`, `slurm_job`, `pbs_job`, `scheduler_agent_job`)
must end with the `Cancel Streaming` step** — without it a script that exits before its
endpoint registers leaves `tail -f` alive and the run sits in `running` forever (the
success path hides this because `wait_for_endpoint` cancels the whole subworkflow). The
setsid rewrite (#4) had dropped it from `general`/`emed` `ssh_job` and `noaa`
`scheduler_agent_job`; restored on 2026-09-09. Symptom to recognize: error annotation in
`pw workflows runs errors` but the run never leaves `running`, and `ps` on the node shows
`tail -f run.<job>.out` under `subworkflows/<submitter job>/` (§7).

## 6. `pw` CLI reference (verified)

Global flags: `--context`, `--platform-host`, `-v/--verbose`. Assume already
authenticated (`pw context list` shows the current user/org). Access tokens are
short-lived; they renew while the CLI is in use, but an idle shell's lapse: when every
command fails with "Authentication has expired", ask the user to run `pw auth`
(`pw auth --device <host>` prints a code for a headless machine; a `PW_API_KEY`
environment variable takes precedence over the credentials file). The sign-in needs a
human; do not try to mint a token. Where `pw` is already signed in (the workspace, an
existing cluster's login node) and which credential a run's scripts use:
[pw-auth.md](pw-auth.md).

### Workflows
```bash
pw workflows ls [-o list|json]
pw workflows create <name> --yaml file.yaml [--display-name "X"] [--description "Y"]
pw workflows update <name> --yaml file.yaml [--display-name ...] [--description ...]
pw workflows get <name> -o yaml            # fetch the stored YAML
pw workflows delete <name>
pw workflows run <name|file|repo> [-i <json|file>] [--name "label"] [--dry-run] [--saved-inputs <name>] [--trust] [-o json|text]
```
`run` accepts a saved name, a `marketplace/...` slug, a local YAML file (an inline run,
workflow `inline.<slug>`) or a git repository (`github.com/<owner>/<repo>[/path][@ref]`).
Pass a local file as an **absolute path**: the shell's cwd is not guaranteed between tool
calls, and CLIs before v7.105 parsed a relative path as a git host (on v7.105.0 both
`./x.yaml` and `x.yaml` dry-run fine, verified 2026-10-12). `-i` is a JSON string or
path to a JSON file; `--saved-inputs <name>` loads inputs saved on a registered workflow;
`--trust` grants a repository workflow every account variable it declares without
prompting (`pw workflows permissions` reviews and revokes those grants).
`--dry-run` validates YAML+schema and each subworkflow's required inputs server-side
**without executing** (not unknown fields — §5) — run it before every real launch. `-o json` returns the run object (`run.slug`, `run.number`,
`run.status`).

### Runs (debugging)
```bash
pw workflows runs list [--workflow <name>] [--status running|completed|error|canceled] [--search <text>] [--limit N] [-o json|table]
pw workflows runs view  <slug> [-o text|json]
pw workflows runs logs  <slug> [--job <name>] [--step <name|idx>] [--failed] [--tail N] [-f] [--run-level]
pw workflows runs errors <slug> [-o text|json] [--tail N]
pw workflows runs cancel <slug>            # triggers cleanup trap → cancel.sh → stops the service + endpoint
pw workflows runs clean [filters]
```
`runs logs`/`errors` work from any host (pulled via API) — your first stop when the
service node isn't local. `--job <job name>` narrows to one job (the
submitter job's name is in §7). Step logs may 404 for steps that haven't produced
output yet — harmless. A step's log rotates at 10 MiB (one backup, `logs.out.1`);
`--run-level` fetches the executor log when a step died before writing its own.
`runs errors` exits non-zero when any `::error` annotation exists.

### Endpoints (how every workflow here serves)
```bash
pw endpoints run [flags] -- <cmd>   # spawn a command and expose it (§10); http/https expose a port already listening, serve a static directory
pw endpoints list                   # name, status, URL — the pass/fail check for a run
pw endpoints delete <name>          # tears down the whole remote process tree
```
`pw endpoints list` has **no `-o json`** (its only flags are the global ones, v7.105.0);
its lines are tab-separated `name`, `status`, `URL`. An endpoint started with `--keep`
stays listed after its command exits, until `delete`.
Endpoint names are `<service.name>-<run-slug>`. `delete` disconnects the serving
command (the docs' wording) and, verified, kills the `pw endpoints run` wrapper and its
children — but a daemonizing app that re-parented to PID 1 (e.g. RStudio's `rsession`)
can survive; check `ps -x` after teardown. Other flags worth knowing: re-running with
the same `--name` takes over that endpoint; `--pool` joins several processes under one
name; `-p` pins the local port; `http --link` stops the local server when the command
exits.

### Other useful
```bash
pw kube ls [-o json]               # kubernetes clusters: id, name, cpus, memory (no status field)
pw kube auth [--no-context-switch] <cluster>   # kubeconfig context pw#<cluster>; exec plugin = pw kube token (kubectl >= 1.22)
pw cluster ls [-o json] [--status active]   # resources + status
pw ssh <resource> ["cmd"]          # shell on a resource's node, or run "cmd" and exit
pw forward -L [bind:]lport:host:rport <resource>   # local→remote tunnel (auto-reconnects)
```

### Reaching a service on another node/cluster (`pw forward` / `pw ssh`) — verified
`pw forward` opens a **local** listener that tunnels to `host:rport` *as seen from the
`<resource>` login node* (it auto-reconnects — background it with `&` and add the kill to
`cancel.sh`). **Choosing `host` is the subtle part:**
- service on the resource's **login node** (job *not* scheduled) → use **`localhost`**. A
  login-node service answers only on the login node's own loopback — forwarding to its
  *external hostname* does **not** connect.
- service on a **compute node** (scheduled job) → use that node's name from the job's
  **`HOSTNAME` file**; the tunnel hops login→compute. **Rule: `localhost` when not scheduled,
  the `HOSTNAME` value when scheduled.** (Both require the service to bind `0.0.0.0`.)

`pw ssh <resource> "cat <path>"` reads a file off another resource — handy because
`${PW_PARENT_JOB_DIR}` resolves to the **same path on every resource** in a run (same
user/home/run number), so one job can fetch a sibling job's published file (a port it
allocated, its `HOSTNAME`) cross-cluster. **Each cluster has its own filesystem** — code or
data staged on one resource is absent on another; stage it on the resource that uses it.

A Singularity/Apptainer container shares the **host network namespace** by default, so an
in-container service reaches a host-side `pw forward` listener (and host `localhost:<port>`)
with no extra flags.

---

## 7. Job directory layout

Registered-workflow run → `~/pw/jobs/<workflow-name>/<run-number>/` on the
**execution node** (run number **zero-padded to 5 digits**, e.g.
`~/pw/jobs/my-session/00002/`). CLI file (inline) run → `~/pw/jobs/<run-slug>/`
(e.g. `~/pw/jobs/rational-lionfish/`); on the user workspace `/tmp/runs/<run-slug>/`.
All verified live; this path is `${PW_PARENT_JOB_DIR}`, with a trailing slash: join
with `${PW_PARENT_JOB_DIR%/}/<file>` wherever the result is shown or compared.

Contents after an endpoint-pattern launch (all verified on live runs):
```
~/pw/jobs/<run>/
├── inputs.sh                              # exported PW vars + your form values
├── controller-<JOBID>.sh                  # inputs.sh + your controller script (what ran)
├── start-service-<JOBID>.sh               # inputs.sh + cleanup trap + your start script
├── SKIP_CLEANUP                           # touched by wait_for_endpoint → service outlives the run
├── workflows/<name>/app/..., tools/...    # the sparse checkout (runtime subtree only)
├── run.<JOBID>.out                        # service stdout (here, or under subworkflows/…/step_0/
│                                          #   when the YAML does not pass rundir)
├── cancel.sh                              # shutdown script (run on cancel / endpoint delete)
├── logs/<job>/step_N/step.out             # per-step trace: with set -x every command as it
│                                          #   ran, form values expanded; step.exit = exit code
├── logs/<job>/outputs-unstable/           # the $OUTPUTS the job published
└── subworkflows/session_runner/step_0/…   # script_submitter subworkflow logs — every YAML
                                           #   here names its submitter job `session_runner`
```
Debug checklist on the service node: `cat run.<JOBID>.out`, the `step.out` traces,
`ps -x | grep <your-process>`, `pw endpoints list`, then `pw workflows runs errors <slug>`.
When a form value seems ignored, read `inputs.sh` (the values preprocessing wrote) and the
`set -x` lines of `step.out`; the rendered step script older platform versions wrote as
`logs/<job>/step_N/script-unstable.sh` no longer exists (checked 2026-10-12, cloud cluster).

---

**Kubernetes jobs run on the workspace exec node** — job dir, object naming and
debugging in [k8s-workflows.md §6](k8s-workflows.md).

## 8. Where to look for working patterns (use the repo, not invented examples)

Learn from the **real workflows in this repo** and the **tutorials under `tutorials/`**:
they are maintained, reviewed and kept in sync with the platform. Read the one closest
to your task.

| Pattern you need | Look at |
|---|---|
| **Simplest complete endpoint workflow** (preprocessing → `script_submitter` → `wait_for_endpoint`) | `workflows/webshell/yamls/general.yaml` + `workflows/webshell/app/{controller,start-template}.sh` |
| **Endpoint with a real install + support files** (conda env, config) | `workflows/jupyterlab/yamls/general.yaml` + `workflows/jupyterlab/app/` |
| **Singularity/SIF service** (oras pull, `.def` + build script, sandbox fallback) | `workflows/streamlit/` (simple); `workflows/kasmvnc/` (multi-impl, GPU helpers); [software/singularity-sif-containers.md](software/singularity-sif-containers.md) |
| **Endpoint whose `--slug` is a query string** | `workflows/openvscode/yamls/general.yaml` (`--slug ?folder=...`) |
| **Endpoint name from a form input** (folded to `[a-z0-9-]`) | `workflows/ollama/yamls/general.yaml` (`endpoint_name`) |
| **The two shared subworkflows** | `workflows/script_submitter/v3.6/` (`README.md`: submission modes and inputs); `workflows/wait_for_endpoint/` (`README.md`: `endpoint_name`, `host`, `skip_cleanups_file`, `healthy`, `budget`, `path`) |
| **Kubernetes** (k8s-only and hybrid sidecar-endpoint examples) | `workflows/mlflow/yamls/k8s.yaml`, `workflows/openvscode/yamls/general_k8s.yaml`; [k8s-workflows.md](k8s-workflows.md) |
| **Job DAG: `needs`, `$OUTPUTS`, `pw endpoints run`, exiting while the service keeps running** | `tutorials/endpoint-workflows/` (staged `README.md`, stages 1→4) |
| **Fan-out / sweep over N workers** (matrix strategy) | `tutorials/endpoint-workflows/05-matrix.yaml` |
| **Step `retry`, attempt-aware vars, `list` inputs, computed `max-retries`, failover** | `tutorials/endpoint-workflows/{06-first-start-wins,07-failover}.yaml` |
| **Iterative loop over computed cases** (retry-as-loop + guarded static matrix) | `tutorials/optimization/` |
| **Resubmit an interrupted simulation until it completes** (a walltime, a preempted or lost node, a cancel: checkpoints, a run script that resumes, the signal forwarded, retry-as-loop whose callee tells a final failure from an interruption) | `workflows/openfoam-naca/yamls/general-restart.yaml` (+ `hsp-restart`, `noaa-restart`; the README's "Resubmitting an interrupted case" is the walkthrough; the resume logic in `app/restart.sh`) |
| **`if:` status functions on steps and jobs** (`success()`, `failure()`, `cancelled()`, `!success()`, `always()`), and what replaced the removed keywords | `tutorials/if-conditions/` |
| **Compose standalone workflows** (sampler or optimizer → matrix of evaluators → a live page; files as the only coupling) | `workflows/doe-openfoam/`, `workflows/dakota-openfoam/` (READMEs show the wiring); the file contract in [design-parameters.md](design-parameters.md) |
| **A workflow others can call** (form as the interface, paths as inputs, one `general.yaml` for every platform) | `workflows/doe/`, `workflows/design-explorer/`, `workflows/wait_for_endpoint/` |
| **A page the workflow draws itself, in the platform's look** (the vendored theme contract, the component recipes, inline icons, light and dark, a server under the endpoint prefix) | `workflows/probe/app/web/` (+ `app/probe/server.py`); [app-ui.md](app-ui.md); `tools/ui/sync-theme.sh` |
| **Repo conventions and the human how-to** | `AGENTS.md`, `DeveloperGuide.md` |

Conventions every workflow here follows: scripts idempotent; the service binds the port
`pw endpoints run` assigns (the `{port}` token) on `0.0.0.0`; the start script stays in
the foreground for the service's life and writes `cancel.sh` for anything that escapes
the endpoint's process tree; all shared paths under `${PW_PARENT_JOB_DIR}`; form inputs
grouped into a `cluster` group + a `service` group beside the top-level `resource`;
`permissions: ['*']`.

> **Adding a new tutorial requires maintainer approval.** Tutorials must each show
> something new and non-repetitive — do not add one to `tutorials/` without
> sign-off from the repo maintainer (Alvaro). Prefer pointing at an existing tutorial.

---

## 9. Getting your workflow code onto the node

`parallelworks/checkout` clones a git repo into the job dir — that is how every real
workflow YAML delivers its controller / start-template scripts (§3). **Do not
base64-embed files** (the old approach); use one of these two modes.

### Mode A — Claude has write access (recommended)
Ask the user to grant write access via a **deploy key with write permission** on the
repo. Then:
1. Do all work on a **development branch — never push to `canary` directly** (branch
   rules require a pull request).
2. Commit and push your workflow code (scripts, etc.) to that branch.
3. In preprocessing, `parallelworks/checkout` that **branch** (sparse-checkout your
   service dir), exactly like the repo examples but with `branch: <your-dev-branch>`.
4. The user reviews and merges the branch themselves; then flip the `branch:` back to `canary`.

### Mode B — Claude has no write access (cannot push)
`parallelworks/checkout` can't fetch code that isn't pushed yet, so stage it on the
resource and **mimic** checkout with a copy step:
1. Create a directory on the resource (e.g. `~/pw/dev/<workflow>/`) and write your files
   there.
2. Give preprocessing **two steps**:
   - the `parallelworks/checkout` step **commented out**, configured as it will be once
     the branch is merged (`repo`, `branch`, `sparse_checkout`);
   - a **copy step** that stands in for it, materializing the same files in the job dir:
     ```yaml
     # - name: Checkout            # uncomment after the branch is merged...
     #   uses: parallelworks/checkout
     #   with:
     #     repo: https://github.com/parallelworks/workflows.git
     #     branch: <your-dev-branch>
     #     sparse_checkout: [ workflows/<name>/app ]
     - name: Copy staged files (stand-in for checkout)
       run: |
         set -x
         cp -r ~/pw/dev/<workflow>/. .   # mimics what checkout would materialize
     ```
3. Hand the changes to the user: they push & merge, **uncomment the checkout step, and
   delete the copy step.** The two-step layout makes that swap a clean diff.

---

## 10. Endpoints (`pw endpoints`): how every workflow here serves

**Upgrading a v4 workflow to this pattern? Follow the step-by-step playbook in
[session-to-endpoint-upgrade.md](session-to-endpoint-upgrade.md)** (distilled from the
openvscode and jupyterlab conversions). Every workflow in this repo uses
**endpoint sessions**: the service side runs
`pw endpoints run`/`http`, which dials out, registers a reverse tunnel, and gets a
subdomain URL (`https://<random-label>.<sessions domain>/<slug>`, the domain being
`activate.pw` on activate.parallel.works; `--slug` may be a query string like
`?folder=/dir` or a path like `lab`). The docs also describe the older exposure, a
`sessions:` block filled by `parallelworks/update-session` (`detach: true` to outlive
the run); nothing here uses it any more (the appendix of
[session-to-endpoint-upgrade.md](session-to-endpoint-upgrade.md) reads it). Key facts,
all verified on live runs:
- **Endpoints are platform-authenticated by default**: an anonymous request to
  `https://<name>.activate.pw/...` gets `307 → https://<platform-host>/?sessionRedirect=…`.
  A service that leaves authentication to the platform login (e.g. Jupyter with
  `token = ''`) keeps that trust model behind an endpoint; only `--public` (which the
  organization must allow) changes that.
- **The endpoint name is a registry key, not the subdomain**: a random subdomain is
  assigned by default (`-s/--subdomain` pins one). Names are how you *find* endpoints —
  `pw endpoints list | grep -w <name>` — so build them from `${PW_RUN_SLUG}` (plus the
  resource name when several workers share a run). Names must be lowercase `[a-z0-9-]`
  (undocumented; one uppercase letter fails the launch): when a form input feeds the
  name, fold it before it reaches `pw endpoints` and make the wait step look for the
  same folded name (`workflows/ollama/yamls/general.yaml`, input `endpoint_name`).
  Killing the client process (cancel
  the run/step) deregisters the endpoint within seconds; racing/fan-out over a shared
  name prefix is shown in `tutorials/endpoint-workflows/` (verified two-resource
  first-start-wins race).
- **`--subdomain <label>` pins the origin** (`https://<label>.<sessions-domain>/`).
  Needed when the app keeps state in the browser, which is per origin: code-server's
  sign-ins (localStorage `secrets.provider`), disabled extensions and workspace trust
  (IndexedDB `vscode-web-state-db-*`) all vanish under a new random subdomain. Labels
  are platform-wide DNS labels, so derive them from `vscode` + namespace + cluster + `PW_USER`
  (`workflows/openvscode`), and fail loud if `pw endpoints list` already shows an
  endpoint at that host — the name stays `<service>-${PW_RUN_SLUG}`.
- **Base-path apps need no base_url and no nginx on a subdomain endpoint**
  (`workflows/jupyterlab/app/start-template.sh`): subdomain endpoints serve at the root, so
  `pw endpoints run ${pw_endpoints_args} -- jupyter-lab --port {port} --config …` is
  enough — v3's nginx proxy + base-path config is obsolete in v5. For path-based
  endpoints (`--no-subdomain`) set the app's base path to the `{path}` token
  (exported as `PW_ENDPOINT_PATH`) instead.
- **Path-based endpoints (verified on `cluster.einsteinmed.edu`, kasmvnc emed):** the
  emed platform has **no session subdomains**, so `pw endpoints http/run` there needs
  `--no-subdomain`. The URL is `https://<platform-host>/me/session/<PW_USER>/<name>/<slug>`
  and the platform forwards the **full path** to the app (no `--strip-path`), so the
  base path is known before launch: `/me/session/${PW_USER}/<name>` (both vars are in
  the workflow env and reach compute nodes via `inputs.sh`). `pw endpoints list` prints
  the path instead of a URL. Anonymous requests still get the `307` login redirect;
  `Authorization: Bearer <token>` requests (and websocket upgrades) go through.
- **`pw endpoints run` substitutes the `{port}` token** (also exports `PORT`) into the
  wrapped command — shell `${port}` expands to empty *before* `pw` sees it, so the app
  falls back to its default port (code-server → `:80` → `EACCES`, instant exit) while
  the tunnel forwards to the assigned port. Always write `{port}`.
- **The other tokens:** `{host}`, the endpoint's public hostname (exported as
  `PW_ENDPOINT_HOST`; give it to an app with an allowed-hosts check), and `{path}`, the
  base path (exported as `PW_ENDPOINT_PATH`: `/` on a subdomain endpoint,
  `/me/session/<user>/<name>/` on a path-based one). The full public URL is exported as
  `PW_ENDPOINT_URL` (`pw endpoints run --help`, v7.105.0).
- **Lifecycle = the tunnel client.** In v5 the workflow *run* completes once
  `wait_for_endpoint` sees the name in `pw endpoints list` (it touches the
  `skip_cleanups_file` and `parallelworks/cancel-jobs` the submitter) **and the
  `wait_for_endpoint` subworkflow saw the URL answer**; the service outlives the run.
  `pw endpoints delete <name>` tears down the whole remote process tree (verified: the
  `pw endpoints run` child dies with it; rc 0, and rc 1 `Session not found` for a
  name already gone).
- **Probing an endpoint URL (verified 2026-09-21, `pw endpoints list` is
  tab-separated `name status URL`).** An anonymous GET gets `307 →
  https://<platform>/?sessionRedirect=<host>` whether or not anything serves behind
  the tunnel — it proves nothing about the service. With
  `Authorization: Bearer ${PW_API_KEY}` (the run's own key, in every step's
  environment) the proxy forwards the request and returns the service's own
  status: `503` for a registered tunnel whose local port has nothing listening (seen
  for ~5 s while JupyterLab booted on a compute node), the app's `200`/`404`/… once it
  serves. The endpoint is listed as `running` ~2 s after `pw endpoints run` starts,
  before the app listens, which is why the health step retries.
- **Env-var auth for containers/sidecars (v7.79.0):** the CLI authenticates from
  `PW_API_KEY` + `PW_PLATFORM_HOST` env vars with no config file — this is how to run
  it in a pod. `ghcr.io/parallelworks/pw-cli:<ver>` is distroless (entrypoint
  `/usr/local/bin/pw`, nonroot 65532), so pass subcommands via container `args:`.
- **Kubernetes: run the client as a sidecar** — everything k8s is in [k8s-workflows.md](k8s-workflows.md).
- `PW_RUN_SLUG` holds the **run slug** (same in every job) — build the endpoint name as
  `<service>-${PW_RUN_SLUG}` in one job and wait for it in another. (`PW_JOB_ID` carries
  the same value, but prefer `PW_RUN_SLUG` — the name says what it is.) It is also the
  argument `pw workflows runs cancel` takes. Start templates must NOT self-cancel the
  run with it (removed everywhere — it marked failed runs as canceled): on failure they
  exit non-zero, the submitter job fails, and the submitter job's cancel-jobs step
  stops `wait_for_endpoint`. Both vars reach scheduled
  compute nodes via the `inputs.sh` `env | grep '^PW_'` capture.

### Signing users in with ACTIVATE (OIDC)

An app that lets visitors sign in with their ACTIVATE account registers an application
for its exact URL and needs a proxy of its own in front; the recipe, the claims, the
session proxy's constraints and how to test the flow are in
[oidc-sign-in.md](oidc-sign-in.md) (`workflows/openproject` is the worked example).

### Apps that need a base path (path-based endpoints)

Subdomain endpoints serve at the URL root, so most apps need no base-URL config and no
proxy (above). A **path-based** endpoint (`--no-subdomain`; required on emed, above) serves at
`https://<platform-host>/me/session/<PW_USER>/<name>/<slug>` and forwards the full path, so
an app that builds **absolute URLs** (JupyterLab, many SPAs) must know that prefix:

- pass the **`{path}` token** (also exported as `PW_ENDPOINT_PATH`) as the app's base URL in
  the `pw endpoints run` command — it renders `/` on subdomain endpoints, so one start
  template serves both kinds (jupyter/jupyterlab pass it as `--ServerApp.base_url`; n8n
  sets `N8N_PATH` from `PW_ENDPOINT_PATH`);
- or `--strip-path` for an app that serves relative URLs and cannot take a base path
  (code-server).

`--slug` is the path appended after the endpoint URL: `lab` (JupyterLab), a query string
such as `?folder=…` (openvscode), or omitted for an app that serves at the root (`--slug ""`
risks the empty token being eaten by the arg parser).

---

## 11. AI agents & LLM-backed services (verified building `hermes-agent`)

### Platform LLM endpoint — a service's "brain"
OpenAI-compatible at **`https://${PW_PLATFORM_HOST}/api/openai/v1`**; auth
`Authorization: Bearer ${PW_API_KEY}` (the run's key: [pw-auth.md](pw-auth.md)). **Org-provider models (`org:*`,
e.g. `org:glm/glm-5.1`) require an `X-Allocation: <name>` header** — without it you
get `400 "X-Allocation header is required for org provider requests"`. List
allocation names at **`GET https://${PW_PLATFORM_HOST}/api/allocations`** (objects
with `name`/`unit`/`total`/`used`; e.g. `Private LLM Group`). Discover models with
`pw ai models ls [-o json]`; chat from the CLI with `pw ai chats new -p "..."
"<model-id>"`. The connected GLM models support OpenAI tool/function calling, so
you can build tool-using agents straight against the endpoint. (LibreChat points at
the same endpoint — see `workflows/librechat/librechat-singularity/controller.sh`.) `PW_API_KEY` also
authenticates `GET /api/allocations`, so a job can auto-discover an allocation name at
runtime. To send `X-Allocation` from a client that takes default headers, pass it there —
e.g. langchain `ChatOpenAI(base_url=..., api_key=PW_API_KEY, default_headers={"X-Allocation": name})`
(verified) — it then rides on every request, streaming included.

**The `model` you send must be the FULL id from `pw ai models ls` / `GET /v1/models`,
not the short name the Chat model picker shows (verified, lite-agent).** The endpoint
routes by a fully-qualified id: `org:owner/provider` (e.g. `org:glm/glm-5.1`) or — for a
model served by another endpoint (`pw endpoints run --openai`, e.g. a vLLM
endpoint) — `session:<user>:<provider>/<model>` (e.g.
`session:<user>:marketplace.vllmrag.latest_35_session//gpt-oss-20b`; the leading `/` in
the model name yields the `//`). The picker only displays the trailing short name
(`/gpt-oss-20b`); sending that verbatim fails with
`400 "Invalid provider identifier format. Expected 'owner:provider-name'"`, which
surfaces in the built-in chat as a generic **"network error"** (the agent's brain call
500s/aborts the stream). Resolve a short name to its full id by matching it against
`GET /v1/models` (the id whose trailing segment equals the name). Endpoint-served model
ids embed the backing run's number and so change when it relaunches — resolve at runtime,
don't hardcode. `X-Allocation` is required for `org:*` but harmless for endpoint-served
models, which can support tool calling too (gpt-oss-20b does).

### `PW_API_KEY` at runtime
The run's key is in every step's environment and dies with the run; which credential
a service calls `pw` with afterwards, and how a key the user hands the workflow is
carried: [pw-auth.md](pw-auth.md).

### Chat surface: `--openai` endpoints (don't hand-roll a chat UI)
Expose an OpenAI-compatible server (`GET /v1/models`, `POST /v1/chat/completions`) with
`pw endpoints run|http --openai`: every model its `/v1/models` lists registers as a chat
model `session:<user>:<name>/<model-id>` in `pw ai models ls`, and the list is re-polled,
so models added later appear without relaunching (verified, `ollama-gguf` — below). Don't
build a bespoke HTML chat page.

**Serving SSE so the built-in chat doesn't abort it (hard-won — `http.server`):**
the chat sends `stream: true`; if your streamed reply isn't framed the way the
proxy expects it kills the chat with `stream error … INTERNAL_ERROR; received from
peer` (and your server logs a `BrokenPipeError`). Two requirements, both needed:
1. **Reply over HTTP/1.1 with `Transfer-Encoding: chunked`** (set
   `protocol_version = "HTTP/1.1"` on a `BaseHTTPRequestHandler`, add the header,
   write each SSE event as one chunk `b"%x\r\n%s\r\n"`, end with `b"0\r\n\r\n"`).
   An HTTP/1.0 close-delimited body reads as *truncated* to the HTTP/2 proxy.
2. **Keep bytes flowing while you think.** A real LLM streams tokens continuously;
   an agent loop goes silent for seconds during each brain/tool call, and the proxy
   resets an idle stream. Emit a keepalive (an empty-content delta, or an SSE `:`
   comment) ~every second from a background thread until real output is ready.
   (Verified: a 3-second silent gap was enough to get reset.) `--dry-run` and
   non-streaming both pass while streaming fails — only a real chat exercises this.


### `pw ssh` from inside a running service (cross-node transport)
A service process CAN run `pw ssh <cluster> <cmd>` / `pw ssh workspace <cmd>` at
runtime (reuses pw auth; needs `$HOME/pw` on PATH — the `PATH=$HOME/pw:$PATH`
inputs.sh line covers it). Clean, inbound-port-free cross-cluster transport (e.g. an
orchestrator on the workspace → `pw ssh <cluster> curl localhost:<port>`). **stdin
is NOT reliably forwarded** through `pw ssh <c> <cmd>` — base64 the payload INTO the
command instead: `pw ssh c "echo <b64> | base64 -d | curl --data-binary @- http://localhost:P/x"`.

### Serving GGUF models with Ollama behind an endpoint (verified, `ollama-gguf`)
- **The whole pattern is one command** (from `pw endpoints run --help`'s own example):
  `pw endpoints run --openai --rewrite-host=localhost --name <n> -- sh -c 'OLLAMA_HOST=127.0.0.1:{port} ollama serve'`.
  `--openai` registers every model the server lists as a chat model
  `session:<user>:<n>/<model-id>` in `pw ai models ls`; `--rewrite-host` satisfies
  ollama's Host-header guard. Endpoints re-poll `/v1/models` too, so `ollama pull`
  against the live server adds chat models without relaunching (verified).
- **Ollama release assets are `.tar.zst` since ~v0.32** — the old
  `ollama-linux-amd64.tgz` URL 404s. Install per-user with the GitHub release
  `ollama-linux-amd64.tar.zst` + `tar --use-compress-program=unzstd -x` (zstd is
  present on EL9 nodes). No root needed; don't use ollama's install.sh.
- **`ollama pull hf.co/<owner>/<repo>:<QUANT>` pulls any Hugging Face GGUF repo**
  (e.g. `hf.co/mradermacher/gemma-4-31B-it-heretic-GGUF:Q4_K_M`). Pulls need a
  running server: start a temp `ollama serve` on an ephemeral 127.0.0.1 port in the
  controller, pull, kill it — weights land in `$OLLAMA_MODELS` on the shared FS for
  the service node (see `workflows/ollama/ollama-gguf/controller.sh`).
- **`pw ai chats new` is deprecated → redirects to `pw code`, which sends tools on
  every request.** A model whose chat template lacks tool support 400s through the
  platform with `"<model> does not support tools"` (its plain
  `/v1/chat/completions` works fine) — this is the agentic client, not a tunnel
  failure. Verify agentic chat with a tools-capable model (e.g. `qwen3:0.6b`).
