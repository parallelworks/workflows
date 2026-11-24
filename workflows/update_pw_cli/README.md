# update_pw_cli

Subworkflow every `emed` workflow calls as the first step of its preprocessing job. It
upgrades the `pw` CLI at `~/pw/pw` on the resource's login node to the version the
platform serves, so the scripts of the run (the controller, the start script's
`pw endpoints run`) work with a current client.

Why a copy under `~/pw`: `pw upgrade` replaces its own binary and needs write access
to it. On the managed cluster of `cluster.einsteinmed.edu` the `pw` on the PATH is
`/usr/local/bin/pw`, root-owned, and falls behind the platform. The `emed` workflows
put `$HOME/pw` first in the PATH of their scripts (`inputs.sh`), so the copy there is
the one they run. On an existing cluster `~/pw/pw` is the agent's own binary and is
upgraded in place. A step that keeps the PATH it was given (the `wait_for_endpoint`
subworkflow) still runs the system `pw` on the managed cluster.

It is an `emed.yaml`, not a `general.yaml`, because both reasons belong to that
platform: the root-owned system CLI and the host the upgrade falls back to.

One step, on the login node over SSH:

1. When `~/pw/pw` is missing or not executable, copy the `pw` on the PATH (else
   `/usr/local/bin/pw`) to it, through `~/pw/pw.tmp` and a rename.
2. Remove partial downloads an interrupted upgrade left in `~/pw`
   (`.pw-cli-update-*` older than ten minutes).
3. Hard-link the binary to `~/pw/.pw.keep.<inode>`, so the file an upgrade replaces
   stays on disk for whatever still runs it (below), and drop the replaced ones after
   30 days.
4. `~/pw/pw upgrade`, for 120 s at most, against `PW_PLATFORM_HOST`
   (`cluster.einsteinmed.edu` when the step's environment does not carry it).

**It must never stop its caller.** A failed or stalled upgrade is a `::warning::`
naming the version that stays in use, and the step exits 0. The call carries
`ignore-errors: true` for what the step cannot absorb: a sub-run the platform fails
before it starts.

## Usage

```yaml
  preprocessing:
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - name: Update pw CLI
        uses: github/parallelworks/workflows@canary
        ignore-errors: true
        with:
          $yaml: workflows/update_pw_cli/yamls/emed.yaml
          resource: ${{ inputs.cluster.resource }}
      - name: Checkout
        ...
```

It goes before the checkout so nothing in the run has called `pw` yet. It also runs on
its own from the platform, which is how it is tested (`tests/emed/`: the test plants a
stale partial download and checks that none is left and that the binary has its
`.pw.keep` link).

## Inputs

| input | meaning |
|---|---|
| `resource` | the compute cluster whose login node holds `~/pw/pw` (`compute-clusters`; the workspace is excluded, its CLI is the platform's own) |

## What the upgrade does to what is running

Verified 2026-11-24 on `pw://einsteinloginnode` (managed) and
`pw://avidaltorr/einsteindefault` (existing). They share one home directory: the
managed login node has it on GPFS, the existing cluster's node mounts it over NFSv3,
and `~/pw/pw` is the binary that node's agent runs (`~/pw/pw agent start-existing`).

- `pw upgrade` downloads the new binary to `.pw-cli-update-<n>` beside the old one and
  renames it over it (the inode changes).
- **A bare rename from one host breaks the processes that run the old binary on
  another host over NFS.** The first upgrade here ran on the managed node, before
  step 3 existed; on the existing node `stat -L /proc/<agent pid>/exe` then answered
  `Stale file handle`. The agent keeps going on the pages it holds in memory; a page
  it has to read back from the file can no longer be read, which the kernel answers
  with a bus error (not seen yet in the hour that followed).
- The hard link of step 3 prevents it: the replaced inode stays allocated, so its file
  handle stays valid on every host (reproduced with a copy of `sleep` replaced from the
  other host, with and without the link). A replaced binary costs about 110 MB until
  it is dropped, 30 days after its replacement; an agent that keeps running a binary
  longer than that is exposed again. Restarting the cluster starts a new agent.
- Killed mid-download (a canceled run), the upgrade leaves `~/pw/pw` intact and
  working, and the partial download behind: step 2 of the next run removes it.
- It needs the platform host and nothing else: no sign-in and no `PW_API_KEY`
  (it upgraded a fresh copy under an empty `HOME`).
- An upgrade (v7.136.0 or v7.138.1 to v7.141.0) took about 1.5 s on the login node;
  when the CLI is current it is a 0.1 s check. The call added about 4 s to a caller's
  preprocessing either way: a subworkflow is a job of its own.
- `pw cluster ls` keeps reporting the agent's version from when it started: the
  agent picks the new binary up on its next start.
