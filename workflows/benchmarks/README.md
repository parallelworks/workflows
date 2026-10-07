# Benchmarks

Runs one MPI or file system benchmark on a cluster and reports the figures:

| Benchmark | What it measures | Tool |
|---|---|---|
| `imb-pingpong` | point-to-point latency and bandwidth between two ranks, on two different nodes when the job has them | IMB-MPI1 PingPong ([Intel MPI Benchmarks](https://github.com/intel/mpi-benchmarks)) |
| `imb-alltoall` | the time of an all-to-all exchange per message size, for 2, 4, … all ranks | IMB-MPI1 Alltoall |
| `ior` | write and read bandwidth of a parallel file system, one file per rank | [IOR](https://github.com/hpc/ior) |
| `mdtest` | metadata rates of a file system: file and directory creation, stat, read, removal | mdtest (ships with IOR) |

The run completes when the benchmark finishes and fails when it fails. The raw
output streams to the run log while the job runs; the result tables land as CSV in
the job directory, and the headline figures come back as workflow outputs.

![A bandwidth curve over two nodes exchanging a ping-pong](thumbnails/benchmarks.png)

## How it works

1. **preprocessing**, on the login node, prepares the MPI environment (see
   [The MPI](#the-mpi)), builds the benchmark against it once per MPI under
   `<install directory>/benchmarks/<mpi>/` (reused by later runs) and writes the job
   script.
2. **benchmark** submits that script through the shared
   [`script_submitter`](../script_submitter/) as one SLURM or PBS job of **Nodes ×
   MPI ranks per node** (`--nodes`, `--ntasks-per-node`; PBS
   `select=N:ncpus=M:mpiprocs=M`), or runs it on the login node, and streams its
   output. The script launches `mpirun -np <ranks> <benchmark>` and records its exit
   status in `benchmark.exit`.
3. **results** fails the run when the benchmark did not exit `0`, printing the tail of
   its output; otherwise it writes `results/<benchmark>.csv` and publishes the figures.

Cancelling the run ends the job and the benchmark's processes and removes the I/O
directory IOR or mdtest worked in.

## Form options

| Group | Input | Meaning |
|---|---|---|
| `cluster` | `resource` | the cluster to benchmark |
| | `scheduler` | **Yes** (default): one SLURM/PBS job on compute nodes. **No**: the login node, a quick check |
| | `nodes` | nodes of the job. With 2 or more, PingPong's pair is placed on two different nodes and measures the interconnect |
| | `ntasks_per_node` | MPI ranks per node; every rank takes part, so use the cores per node for Alltoall, IOR and mdtest. On the login node it is the total rank count |
| | `slurm`, `pbs` | partition, walltime and extra directives; a directive repeating `--nodes` or `--ntasks-per-node` wins over the workflow's |
| `benchmark` | `name` | `imb-pingpong`, `imb-alltoall`, `ior` or `mdtest` |
| | `imb_args` | extra IMB-MPI1 arguments, e.g. `-msglog 0:22 -iter 1000 -npmin 8` |
| | `preset` | IOR/mdtest arguments: `standard`, `minimal` or `custom` (below) |
| | `ior_args`, `mdtest_args` | the custom arguments, everything but `-o` / `-d`, which the workflow sets |
| | `io_dir` | directory on the file system to benchmark; the run works in `<io_dir>/<run slug>` and removes it. Shell variables expand on the node (`${SCRATCH}`). Empty: `io/` under the run's job directory |
| `software` | `mpi` | `auto` (default), `conda-forge` or `commands` |
| | `mpi_load` | with `commands`: what puts `mpicc`, `mpicxx` and `mpirun` on PATH, e.g. `module load openmpi/4.1.6`; `export MPIRUN="srun --mpi=pmix"` replaces the launcher |
| | `install_dir` | where the benchmarks (and the conda-forge OpenMPI) are installed; default `${HOME}/pw/software` |

| preset | IOR | mdtest |
|---|---|---|
| `standard` | `-w -r -i 3 -t 64m -b 64m -s 16 -F -C -e`: 1 GiB per rank, 3 iterations | `-n 20840 -e 4096 -w 4096 -i 3 -u`: 20840 files per rank, 4 KiB written and read, 3 iterations |
| `minimal` | `-w -r -i 1 -t 1m -b 16m -s 16 -F -C -e`: 256 MiB per rank, 1 iteration | `-n 20840 -i 1 -u`: 20840 empty files per rank, 1 iteration |

## Results

In the run's job directory on the login node (`~/pw/jobs/<run-slug>/` for CLI runs,
`~/pw/jobs/<workflow-name>/<run-number>/` for registered ones):

```
run.<slug>.out              the streamed output: header (MPI, ranks, command) and benchmark output
results/<benchmark>.out     the raw benchmark output
results/<benchmark>.csv     its result tables
benchmark.exit              the benchmark's exit status
```

The `results` job publishes `RESULTS_DIR`, `RESULTS_CSV` and the figures as outputs:

| Benchmark | Outputs |
|---|---|
| `imb-pingpong` | `latency_usec` (at `latency_bytes`), `bandwidth_mbytes_per_sec` (at `bandwidth_bytes`), `processes` |
| `imb-alltoall` | `processes`, `t_avg_usec_smallest`/`smallest_bytes`, `t_avg_usec_largest`/`largest_bytes` |
| `ior` | `write_mib_per_sec_mean`, `write_mib_per_sec_max`, `read_mib_per_sec_mean`, `read_mib_per_sec_max` |
| `mdtest` | `<operation>_ops_per_sec_mean` per row of its summary (`file_creation_…`, `file_stat_…`, …) |

The same figures appear as a notice in the run log.

## The MPI

The benchmark is compiled against, and launched by, the MPI the run uses:

- **`auto`**: the `mpicc` and `mpirun` already on PATH; else a system MPI module
  (`mpi/openmpi-x86_64`, `mpi/mpich-x86_64`, `openmpi`, `mpich`); else Open MPI from
  conda-forge. On the platform's cloud clusters this is the system Open MPI module.
- **`conda-forge`**: Open MPI 5 with its compilers, installed once under
  `<install directory>/benchmarks/miniforge` (~2 GB, no sudo, a few minutes). It
  launches across the nodes of a SLURM job with plain `mpirun`.
- **`commands`**: the form's load commands, for a site module or an Intel oneAPI
  `setvars.sh`.

The run log says which MPI ran. IMB-MPI1 is built from the Intel MPI Benchmarks
source (an `IMB-MPI1` already on PATH, as Intel MPI ships, is used instead); `ior`
and `mdtest` from the IOR release tarball, with Lustre support when the headers are
present. Builds are keyed by the MPI's directory, so two MPIs never share one.

## Variants

| File | Target |
|---|---|
| `yamls/general.yaml` | standard cloud and on-prem SLURM/PBS clusters |
| `yamls/hsp.yaml` | HSP (`activate.hpc.mil`): the `hsp` submitter, SLURM account, QoS and node type for on-prem resources, the HSP PBS defaults |
| `yamls/noaa.yaml` | NOAA (`noaa.parallel.works`): the `noaa` submitter, SLURM account and QoS, the builds in the cluster's shared software tree when the account can write there |

On a cloud cluster the three behave alike; `tests/hsp/` and `tests/noaa/` exercise
them there.

## Run

```bash
pw workflows run "$PWD/workflows/benchmarks/yamls/general.yaml" -i '{
  "cluster": {"resource": "pw://<user>/<cluster>", "scheduler": true, "nodes": 2, "ntasks_per_node": 2,
              "slurm": {"is_enabled": true, "partition": "compute", "time": "00:30:00"}},
  "benchmark": {"name": "imb-pingpong"},
  "software": {"mpi": "auto"}}'
```

`pw workflows runs logs <slug>` has the benchmark output; `pw workflows runs errors
<slug>` the summary when the run failed.

## Tests

`tests/<variant>/`: the four benchmarks on the login node and on SLURM, 2-node
PingPong, the conda-forge MPI, custom arguments and an `io_dir`, and the failure
paths (a bad MPI environment, bad benchmark arguments, a bad rank count), all on
`pw://alvaro/gcpsmall`. Run them with `tools/tests/run-workflow-test.py`.

## Files

- `app/install-mpi.sh` — finds or installs the MPI and writes its environment file
- `app/install-benchmark.sh` — builds IMB-MPI1, or `ior` and `mdtest`, once per MPI
- `app/run-template.sh` — the job script: rank layout, launcher, the benchmark command
- `app/summarize.py` — raw output to CSV, notice and outputs
