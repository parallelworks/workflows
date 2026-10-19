# CWL MPI Hello World on SLURM

Demonstrates Common Workflow Language (CWL) based job execution on ACTIVATE: an
MPI Hello World program compiled and run as a SLURM job, orchestrated by
[cwltool](https://github.com/common-workflow-language/cwltool) on the cluster's
login node. The CWL workflow itself submits and monitors the SLURM job — that
submission is the point of the demo, so the `script_submitter` call runs cwltool
with `scheduler: false`: the submitter contributes its cancel cleanup, not the
scheduling.

## The jobs

1. **preprocessing** (login node): sparse-checks-out `workflows/cwl-mpi-hello-world/app`,
   installs Intel oneAPI MPI with spack and cwltool under Miniconda when the form
   asks (idempotent, under `${HOME}/pw/software`, reused by later runs) — otherwise
   the form's load commands are used — and writes the CWL input file `inputs.yaml`,
   the run script `run-cwl.sh` and the cleanup script `cancel.sh` from the form
   values.
2. **run_cwl**: `script_submitter` runs `run-cwl.sh` (cwltool on the login node).
   On a cancel the submitter's cleanup runs `cancel.sh`, which `scancel`s a SLURM
   job the CWL workflow left behind — a job-level `cleanup:` list does not run
   after a user cancel (the skill's pitfalls, 2026-10-12).
3. **results** (login node): fails the run unless `cwl.exit` is `0` (the submitter
   never forwards the script's status), `job_status.txt` says `COMPLETED` and
   `slurm-output/mpitest.out` holds MPI output.
4. **cancel_slurm_job** (`if: ${{ !success() }}`): the error-path belt and braces
   for a SLURM job that outlived a failed cwltool.

## The CWL workflow (`app/cwl/`)

- **compile.cwl** — builds `mpitest.c` with `mpicc`
- **generate_sbatch.cwl** — writes the batch script from the form's scheduler
  directives, the MPI load command and the process count
- **submit_job.cwl** — `sbatch`s the script
- **wait_for_slurm_job.cwl** — polls `squeue`/`sacct` until the job reaches a
  final state, written to `job_status.txt`

cwltool runs with `--leave-tmpdir` under `<job dir>/cwl-tmp/` because the batch
script references files cwltool staged there and the SLURM job reads them after
the staging step has finished.

## Output

The MPI output lands on the cluster in the run's job directory:

```
<job dir>/cwl_workflow/slurm-output/mpitest.out
```

```
Hello world from processor alvaro-gcpsmall-00319-1-0002, rank 3 out of 4 processors
Hello world from processor alvaro-gcpsmall-00319-1-0001, rank 1 out of 4 processors
Hello world from processor alvaro-gcpsmall-00319-1-0002, rank 2 out of 4 processors
Hello world from processor alvaro-gcpsmall-00319-1-0001, rank 0 out of 4 processors
```

SLURM only: the CWL steps submit with `sbatch` and poll with `squeue`/`sacct`,
so the form restricts the resource to the `*-slurm` providers and there is one
`general.yaml`.
