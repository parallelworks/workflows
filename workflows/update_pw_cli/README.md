# update_pw_cli

Subworkflow every `emed` workflow calls as the first step of its preprocessing job. It
upgrades the `pw` CLI at `~/pw/pw` on the resource's login node to the version the
platform serves, so the rest of the run (the controller, the start script's
`pw endpoints run`) works with a current client.

Why a copy under `~/pw`: `pw upgrade` replaces its own binary and needs write access
to it. On the managed cluster of `cluster.einsteinmed.edu` the `pw` on the PATH is
`/usr/local/bin/pw`, root-owned, and falls behind the platform. The `emed` workflows
already put `$HOME/pw` first in the PATH of their scripts (`inputs.sh`), so the copy
there is the one they run. On an existing cluster `~/pw/pw` is the agent's own binary
and is upgraded in place.

One step, on the login node over SSH:

1. When `~/pw/pw` is missing or not executable, copy the `pw` on the PATH (else
   `/usr/local/bin/pw`) to it, through a temporary file and a rename.
2. `~/pw/pw upgrade`, against `PW_PLATFORM_HOST` (`cluster.einsteinmed.edu` when the
   step's environment does not carry it).

**It never fails its caller.** A failed upgrade is a `::warning::` naming the version
that stays in use; the run goes on with the CLI already there.

## Usage

```yaml
  preprocessing:
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - name: Update pw CLI
        uses: github/parallelworks/workflows@canary
        with:
          $yaml: workflows/update_pw_cli/yamls/emed.yaml
          resource: ${{ inputs.cluster.resource }}
      - name: Checkout
        ...
```

It goes before the checkout so nothing in the run has called `pw` yet. It also runs on
its own from the platform, which is how it is tested (`tests/emed/`).

## Inputs

| input | meaning |
|---|---|
| `resource` | the compute cluster whose login node holds `~/pw/pw` (`compute-clusters`; the workspace is excluded, its CLI is the platform's own) |

## What the upgrade does to a running service

Verified 2026-11-24 on `pw://einsteinloginnode` (managed) and
`pw://avidaltorr/einsteindefault` (existing), which share one home directory:

- `pw upgrade` writes the new binary beside the old one and renames it over it (the
  inode changes, nothing is left behind). Processes started from the old binary keep
  running on it: the existing cluster's agent (`~/pw/pw agent start-existing`) and
  the `pw endpoints run` of a session started earlier are not interrupted.
- It needs the platform host and nothing else: no sign-in and no `PW_API_KEY`
  (it upgraded a fresh copy under an empty `HOME`).
- An upgrade (v7.136.0 or v7.138.1 to v7.141.0) took about 1.5 s on the login node;
  when the CLI is current it is a 0.1 s check. The call adds a few seconds to the run
  either way: a subworkflow is a job of its own.
- `pw cluster ls` keeps reporting the agent's version from when it started: the
  agent picks the new binary up on its next start.
