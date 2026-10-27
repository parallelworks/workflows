# `pw` inside a workflow: which credential it runs on

Read this when a workflow's scripts call `pw` or the platform API, and above all when
they keep doing so after the run completes.

## Where `pw` is signed in on its own

- **The user workspace and the login node of an existing cluster** (resource
  `type: existing`, connected through the ACTIVATE agent): `pw` is signed in as the
  user; the agent keeps the credential there (agent v7.102.0 or later). Verified
  2026-10-26 on `a30gpuserver` (agent v7.127.0): `pw auth whoami` answers after
  `unset PW_API_KEY`.
- **A cloud cluster**: nothing is signed in; the same step on `gcpsmall` got
  `no context configured; use 'pw auth'`. The user signs the CLI in on the login node
  (`pw auth`, again when that session expires) or the workflow is handed a key (below).

`pw auth --help` says the same: pre-authenticated for user workspaces and existing
clusters, authenticate for a cloud cluster or a local CLI. A `PW_API_KEY` environment
variable takes precedence over the saved credential.

## The run's key

Expose it once with a top-level `env:` block and the platform injects it into every
job and step:
```yaml
env:
  PW_API_KEY: ${PW_API_KEY}
```
(`hermes-agent`, `wait_for_endpoint`, every Kubernetes YAML). A submitted script and
the service it starts inherit it (verified via `/proc/<pid>/environ`), so a service can
use it as the platform bearer with no org secret. Keep it out of `inputs.sh`
(preprocessing writes `env | grep '^PW_' | grep -v 'PW_API_KEY'`) and read it from the
runtime env.

**It belongs to the run.** It is rejected as soon as the run ends (verified 2026-09-24):
a scheduler job or a service that inherited it keeps serving the endpoint it registered
(the tunnel runs on its own key), but every new call made with it afterwards, a `pw`
command or a request with it as the bearer, fails with `Authentication has expired`.
On `activate.hpc.mil` a key lasts at most 30 days in any case. A service that only
serves needs nothing more.

## A service that calls `pw` after the run completes

A collector, a page that launches runs, a teardown: it needs a credential that outlives
the run. The platform injects `PW_API_KEY` itself, so the job script, not the YAML,
swaps it:

1. **Existing cluster**: drop the inherited key before calling `pw`; the login node's
   own sign-in takes over, and nothing has to be managed or rotated:
   ```bash
   unset PW_API_KEY
   ```
2. **Cloud cluster**: a personal API key (Account > Authentication > API keys),
   exported as `PW_API_KEY` at the top of the job script and replaced before it
   expires: only new `pw` invocations read it, a running tunnel is not affected.
   Setup 1 works there too once the user has run `pw auth` on the login node.

`env -u PW_API_KEY pw auth whoami` tells at run time whether the node has a sign-in of
its own, `PW_API_KEY=<key> pw auth whoami` whether a given key works;
`workflows/hpc_status/app/start-template.sh` tries both and warns when neither holds.

## A key the user hands the workflow

A `password` input, carried under another name in the top-level `env:` block and read
from the runtime env (`workflows/probe/yamls/general.yaml`, `PROBE_API_KEY`). An app
that needs the key as a string in its own config takes it on every cluster type
(`workflows/librechat`, `ACTIVATE_API_KEY`: checked with `pw auth whoami` before the
controller writes it into LibreChat's `.env`). Keep `set -x` off around it, or the
trace prints it; the platform keeps form values, password inputs included, in the
run's record and renders them into the step scripts under the job's `logs/`. A test
passes it from an environment variable (`_test.secrets`, `tools/tests/README.md`): a
key never sits in a test file or anywhere else in the repo.
