# Activate Batch

Runs a list of shell commands as a batch job on a compute cluster: directly on the
login node, or submitted through SLURM or PBS. It is the hello world of job
submission on ACTIVATE — pick a resource, type commands, run, read the output in
the run log — and the template for any workflow that needs to "run this on that
cluster" without serving anything.

Unlike the other workflows in this repository it registers **no endpoint**: the run
completes when the commands finish and **fails when they fail**.

## How It Works

1. **preprocessing** first rejects a request in the retired top-level input shape
   (see [API input shape](#api-input-shape)), then writes `commands.sh` in the job directory: `set -e`, a trap
   that records the script's exit status in `commands.exit`, a banner with the
   hostname, date, user and directory, your commands, and a completion footer.
2. **script_submitter** submits that file through the shared
   [`script_submitter/v3.6`](../script_submitter/) subworkflow (`use_existing_script`),
   on the login node or via `sbatch`/`qsub` depending on **Schedule Job?**. The
   submitter streams `run.<id>.out` to the log while the job runs and, if the run is
   cancelled, kills the process or `scancel`s/`qdel`s the job.
3. **Check Exit Status** reads `commands.exit` and fails the run when it is not `0`.

## Inputs

- **Compute resource** / **Schedule Job?** / **SLURM Directives** / **PBS Directives**:
  the same cluster form as every workflow here. Account, QoS, node counts, memory and
  the like go in the scheduler directives editor, one `#SBATCH`/`#PBS` line each.
- **Commands to Execute**: the commands, one per line. They run under `set -e`, so
  the job stops at the first failing command; append `|| true` to a command that
  may legitimately fail (`nvidia-smi || true`). Load modules first if a command
  needs them (`module load gcc`).

## Variants

`yamls/general.yaml` targets standard cloud and on-prem SLURM/PBS clusters.
`yamls/hsp.yaml` is the HSP (`activate.hpc.mil`) form: it submits through the `hsp`
script submitter and adds the SLURM account, QoS, CPUs per task, node count and
DSRC node-type fields plus a PBS account, all of which only appear for `existing`
(on-prem) resources; on a cloud cluster the two variants behave the same.

## Output and Debugging

Everything is in the run's job directory on the login node
(`~/pw/jobs/<run-slug>/` for CLI runs, `~/pw/jobs/<workflow-name>/<run-number>/`
for registered ones): `commands.sh` as generated and `commands.exit` with the exit
status at its root, and `run.<id>.out` with the commands' stdout and stderr under
`subworkflows/script_submitter/step_0/`, the submitter's own directory. From anywhere:

```bash
pw workflows runs logs <slug>            # includes the streamed job output
pw workflows runs errors <slug>          # summary when the run failed
```

A missing `commands.exit` means the script never reached its end (killed, walltime
exceeded, node failure); the run fails with that message.

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/activate-batch/yamls/general.yaml" \
  -i '{"cluster":{"resource":"pw://<user>/<cluster>","scheduler":false},"service":{"commands":"hostname\ndate"}}'
```

## API input shape

The form groups its inputs: the cluster settings under `cluster` and the commands under
`service`. The standalone `parallelworks/activate-batch` template took them at the top
level, and the platform does not reject input keys a workflow does not declare, so a
request in the old shape is accepted, its `commands` never bind, and `service.commands`
falls back to its default. To keep that from running the example commands and reporting
success, **preprocessing fails the run** when a request carries a top-level `commands`,
`scheduler` or `submit_to_scheduler` input:

```
Legacy inputs: The request uses retired top-level inputs (commands submit_to_scheduler).
Commands now go in service.commands; scheduler settings in cluster.scheduler, cluster.slurm
and cluster.pbs (see workflows/activate-batch/README.md). Nothing was run.
```

| Standalone template | `general.yaml` | `hsp.yaml` |
|---|---|---|
| `resource` | `cluster.resource` | `resource` |
| `commands` | `service.commands` | `service.commands` |
| `scheduler` / `submit_to_scheduler` | `cluster.scheduler` | `cluster.scheduler` |
| `slurm.partition`, `slurm.time`, `slurm.scheduler_directives` | `cluster.slurm.*` | `cluster.slurm.*` |
| `slurm.account`, `slurm.qos`, `slurm.nodes`, `slurm.cpus_per_task` | `cluster.slurm.scheduler_directives` (`#SBATCH` lines) | `cluster.slurm.*` |
| `slurm.gres`, `slurm.mem` | `cluster.slurm.scheduler_directives` | `cluster.slurm.scheduler_directives` |
| `pbs.account` | `cluster.pbs.scheduler_directives` (`#PBS -A`) | `cluster.pbs.account` |
| `pbs.queue`, `pbs.walltime`, `pbs.select`, `pbs.scheduler_directives` | `cluster.pbs.scheduler_directives` | `cluster.pbs.scheduler_directives` |

Only those three keys are checked: they are present in every request in the old shape,
and the form cannot send them, so the check never fires on a run started from the UI.

## Provenance

Moved from the standalone `parallelworks/activate-batch` repository, where it
submitted through the `marketplace/job_runner/v4.0` action; here it uses the
repository's own script submitter so it shares the cluster form, the scheduler
logic and the cancel handling with every other workflow.
