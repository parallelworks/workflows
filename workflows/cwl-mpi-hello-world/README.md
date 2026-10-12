# CWL MPI Hello World on SLURM

Demonstrates Common Workflow Language (CWL) based job execution on ACTIVATE: an
MPI Hello World program compiled and run as a SLURM job, orchestrated by
[cwltool](https://github.com/common-workflow-language/cwltool) on the cluster's
login node. The CWL workflow itself submits and monitors the SLURM job — that
submission is the point of the demo, so this workflow does not use
`script_submitter`.

## The jobs

1. **preprocessing** (login node): sparse-checks-out `workflows/cwl-mpi-hello-world/app`,
   installs Intel oneAPI MPI with spack and cwltool under Miniconda when the form
   asks (idempotent, under `${HOME}/pw/software`, reused by later runs) — otherwise
   the form's load commands are used — and writes the CWL input file `inputs.yaml`
   from the form values.
2. **run_cwl** (login node): runs `cwltool mpi_workflow.cwl inputs.yaml` and then
   checks the final SLURM job state: the run fails unless the job `COMPLETED` and
   wrote MPI output. A cancel mid-flight `scancel`s a SLURM job the CWL workflow
   left behind.

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

Migrated from <https://github.com/parallelworks/cwlmpihelloworld>.
