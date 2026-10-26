# Shape: an endpoint service

The jobs after preprocessing for a workflow that serves a web app through a `pw`
endpoint, the shape most workflows here take. The run ends when the service answers
its URL; the service outlives the run until `pw endpoints delete <name>`. Copy
`workflows/webshell/yamls/general.yaml` (the smallest) or
`workflows/jupyterlab/yamls/general.yaml` (an install plus support files). The common
part (preprocessing, paths, form, code delivery) is SKILL.md Step 2; the platform facts
are [../activate-platform.md](../activate-platform.md) §5 (`script_submitter`) and §10
(endpoints).

## The jobs

1. **preprocessing** also assembles the start script (`inputs.sh` + the generic cleanup
   trap + `start-template.sh`) and publishes its path and the `SKIP_CLEANUP` path as
   outputs (`SCRIPT_PATH`, `SKIP_CLEANUP_PATH`).
2. **session_runner** (the submitter job's name in every endpoint YAML here): the
   `script_submitter` subworkflow submits the start script, with the whole `with:`
   block copied from the matching variant (`resource`, `use_existing_script` +
   `script_path`, `define_cleanup_script: true` + `cleanup_script_path: ./cancel.sh`,
   `scheduler`, `slurm`/`pbs`, `skip_cleanups_file`). The two steps after it
   (`cancel-jobs` on the waiter, `exit 1`) only run when the script returns before the
   endpoint came up: that is the failure path (reference §5).
3. **wait_for_endpoint**: the `wait_for_endpoint` subworkflow
   (`workflows/wait_for_endpoint/README.md`) polls `pw endpoints list` for
   `<service.name>-${PW_RUN_SLUG}`, probes the URL with
   `Authorization: Bearer ${PW_API_KEY}` until the status matches `healthy` within
   `budget`, touches the `SKIP_CLEANUP` file so the service outlives the run, and the
   job cancels the submitter. If the service never answers, the job fails without the
   marker and the submitter's cleanup tears the job down. **The workflow owns this
   health check.** Set the inputs per service: `healthy` (`2*|3*` for a web UI; a
   `path` to a health route for an API server), `budget` (seconds for a Python server,
   minutes for a container or a model load); read the wait job's log once to confirm the
   choice. The key matters: an anonymous request only ever sees the platform's `307`
   login redirect; with the key the service's own status comes back, `503` while
   nothing listens behind the tunnel yet.

The form's `service` group holds the app's fields. Its hidden `service.name` input is
the **endpoint name prefix**: keep it stable, because renaming it changes the endpoint
names users see. Endpoint names are lowercase `[a-z0-9-]`; fold a name that comes from
a form input before it reaches `pw endpoints`, and make the wait job look for the same
folded name (`workflows/ollama/yamls/general.yaml`, input `endpoint_name`).

## The two contract scripts

Both source `inputs.sh`:

- **`controller.sh`**: idempotent setup on the login node (it has internet). Check
  before installing; often it only verifies prerequisites.
- **`start-template.sh`**: launches the service **in the foreground** under
  `pw endpoints run ${pw_endpoints_args} -- <cmd with {port}>`, the literal `{port}`
  token (the shell would expand `${port}` to nothing). `pw endpoints run` blocks for
  the service's life, so the script needs no `sleep inf`; a server started in the
  background does. Write `cancel.sh` first, for anything the endpoint's process-tree
  kill will not reach (a `screen` session, a docker container, a daemonizing app). Fail
  loud: when `pw endpoints run` exits without the endpoint registered, exit non-zero
  (copy the tail of `workflows/webshell/app/start-template.sh`), and never cancel the
  run from inside the start script.

The service binds `0.0.0.0` on the port the endpoint assigned. Apps that build
absolute URLs read `PW_ENDPOINT_URL`, exported by `pw endpoints run` to the wrapped
command (also `PORT`, `PW_ENDPOINT_HOST`, `PW_ENDPOINT_PATH`); since these are unknown
before launch, generate a small launcher script and run
`pw endpoints run ${pw_endpoints_args} -- ./launch.sh`.

## Base paths

Subdomain endpoints serve at the URL root, so most apps need no base-URL setting and no
proxy; `--slug` adds a landing path or query string. A path-based endpoint
(`--no-subdomain`, required on emed) forwards the full prefix: give the app the
`{path}` token as its base path, or `--strip-path` (reference §10). An app with a host
guard (a DNS-rebinding check, an allowed-hosts list) needs `--rewrite-host` or the
`{host}` token; the anonymous `307` check does not catch this, a
`curl -H "Host: <public host>" localhost:<port>` does.

## Kubernetes

The same endpoint, registered by a `pw-cli` sidecar inside the pod; no submitter, no
login node, nothing checked out, and the run stays alive until it is cancelled. Copy
`workflows/mlflow/yamls/k8s.yaml` (k8s-only) or
`workflows/openvscode/yamls/general_k8s.yaml` (hybrid); everything else is in
[../k8s-workflows.md](../k8s-workflows.md).

## What "done" and "clean" mean here

- The run completes once `wait_for_endpoint` saw the endpoint listed and its URL
  answer. The test runner's pass is `completed` plus an endpoint named `*-<run-slug>`
  in `pw endpoints list` (`tools/tests/README.md`); it never probes the URL itself.
- Teardown is `pw endpoints delete <name>`: it kills the remote process tree. A
  daemonizing app that re-parented to PID 1 can survive it, which is what `cancel.sh`
  is for.
- The service outlives the run; the run's `PW_API_KEY` does not. A service that only
  serves needs nothing more; one that calls `pw` after the run completes takes a
  credential that outlives it (reference §11, "The key belongs to the run").
- Cancel mid-flight (`pw workflows runs cancel <slug>` while the service is starting
  or serving) must leave nothing: no service process, no scheduler job, no container
  instance, no listener, no `stopped` record in `pw endpoints list` (a cancel while
  the service starts can leave one; delete it).
- The failure path: an `exit 1` before `pw endpoints run` must end the run in `error`
  (the submitter job's tail cancels the waiter). The success path never exercises it.
- A fixed endpoint name (`hpc_status`, `app-testbed`) has to be freed in preprocessing
  before the waiter looks it up, or the wait finds the previous instance answering;
  re-running `pw endpoints run --name` takes the name over.
