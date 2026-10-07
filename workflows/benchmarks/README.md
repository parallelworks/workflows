# Benchmarks

Runs one MPI or file system benchmark on a cluster and reports the figures:

| Benchmark | What it measures | Tool |
|---|---|---|
| `imb-pingpong` | point-to-point latency and bandwidth between two ranks, placed on two different nodes when the job has them | IMB-MPI1 PingPong ([Intel MPI Benchmarks](https://github.com/intel/mpi-benchmarks)) |
| `imb-alltoall` | the time of an all-to-all exchange per message size, for 2, 4, … all ranks | IMB-MPI1 Alltoall |
| `ior` | write and read bandwidth of a parallel file system, one file per rank | [IOR](https://github.com/hpc/ior) |
| `mdtest` | metadata rates of a file system: file and directory creation, stat, read, removal | mdtest (ships with IOR) |

The run completes when the benchmark finishes and fails when it fails. The raw
output streams to the run log while the job runs; the result tables land as CSV in
the job directory, and the headline figures come back as workflow outputs.

![A bandwidth curve over two nodes exchanging a ping-pong](thumbnails/benchmarks.png)

## How it works

1. **preprocessing**, on the login node: checks out `workflows/benchmarks/app`
   and `tools/utils`, writes `inputs.sh`, then prepares the **MPI environment**
   as one sourceable file, `mpi-env.sh`: the form's load commands, or what
   `install-mpi.sh` finds or installs ([The MPI](#the-mpi));
   `tools/utils/prepare-env.sh` checks that sourcing it provides `mpicc` and
   `mpirun` before anything is built. `install-benchmark.sh` then **builds the
   benchmark against that MPI**, once per MPI under
   `<install directory>/benchmarks/<mpi>/` and reused by every later run, and the
   job script `benchmark.sh` is assembled: `inputs.sh`, the binary and environment
   paths, `run-template.sh`.
2. **benchmark**: the shared [`script_submitter`](../script_submitter/) runs
   `benchmark.sh` in the job directory as one SLURM or PBS job of **Nodes × MPI
   ranks per node** (`--nodes`, `--ntasks-per-node`; PBS
   `select=N:ncpus=M:mpiprocs=M`), or on the login node, and streams its output.
   The script reads the rank layout from the allocation, runs
   `mpirun -np <ranks> <benchmark>`, leaves the raw output in
   `results/<benchmark>.out` and its exit status in `benchmark.exit`, and removes
   the I/O directory IOR or mdtest worked in. If the run is cancelled the
   submitter cancels the job and runs `cancel.sh`, which removes that directory.
3. **results**: fails the run when `benchmark.exit` is missing or not `0`,
   printing the tail of the output, then `summarize.py` writes
   `results/<benchmark>.csv` and the headline figures, as a `::notice` in the
   log and as the outputs below.

## Inputs

| Group | Input | Meaning |
|---|---|---|
| `cluster` | `resource` | the cluster whose nodes, interconnect or file system is benchmarked |
| | `scheduler` | **Yes** (the default): one SLURM/PBS job on compute nodes. **No**: the login node, with `ntasks_per_node` ranks, as a quick check |
| | `nodes` | nodes of the job (`--nodes`). With 2 or more, IMB-MPI1 gets `-map <ranks per node>x<nodes>`, which numbers the ranks so that PingPong's pair sits on two different nodes and measures the interconnect |
| | `ntasks_per_node` | MPI ranks per node (`--ntasks-per-node`). Every rank takes part, so set the cores per node for Alltoall, IOR and mdtest; on the login node it is the total rank count |
| | `slurm`, `pbs` | partition, walltime and extra directives. The workflow writes `--nodes` and `--ntasks-per-node` (PBS `-l select=…`) first, so a directive typed here that repeats one of them wins |
| `benchmark` | `name` | `imb-pingpong`, `imb-alltoall`, `ior` or `mdtest` |
| | `imb_args` | extra IMB-MPI1 arguments, e.g. `-msglog 0:22 -iter 1000 -npmin 8` (message sizes, repetitions, smallest process count) |
| | `preset` | the IOR or mdtest arguments: `standard`, `minimal` or `custom` (table below) |
| | `ior_args`, `mdtest_args` | the custom arguments: everything but `-o` (IOR's test file) or `-d` (mdtest's directory), which the workflow places in the I/O directory |
| | `io_dir` | a directory on the file system to benchmark; the run works in `<io_dir>/<run slug>` and removes it afterwards. Shell variables expand on the node (`${HOME}`, `${SCRATCH}`). Empty: `io/` under the run's job directory, i.e. the file system that holds the home directories |
| `software` | `mpi` | `auto` (the default), `conda-forge` or `commands` |
| | `mpi_load` | with `commands`: shell commands that put `mpicc`, `mpicxx` and `mpirun` on PATH, one per line (`module load openmpi/4.1.6`, `source /opt/intel/oneapi/setvars.sh`). `export MPIRUN="srun --mpi=pmix"` here replaces the launcher |
| | `install_dir` | where the benchmarks, and the conda-forge OpenMPI when used, are installed; default `${HOME}/pw/software` |

| preset | IOR | mdtest |
|---|---|---|
| `standard` | `-w -r -i 3 -t 64m -b 64m -s 16 -F -C -e`: 1 GiB per rank in 64 MiB transfers, 3 iterations | `-n 20840 -e 4096 -w 4096 -i 3 -u`: 20840 files per rank with 4 KiB written and read, 3 iterations |
| `minimal` | `-w -r -i 1 -t 1m -b 16m -s 16 -F -C -e`: 256 MiB per rank in 1 MiB transfers, 1 iteration | `-n 20840 -i 1 -u`: 20840 empty files per rank, 1 iteration |

IOR writes one file per rank (`-F`), reads back another rank's file (`-C`, so the
page cache does not serve the read) and fsyncs (`-e`); mdtest gives every rank its
own directory (`-u`). The IOR and mdtest manuals list every other option.

## The MPI

The benchmark is compiled against, and launched by, the MPI the run uses. Which
one is the `mpi` input:

- **`auto`**: the first of these that provides `mpicc` and `mpirun` wins: the
  PATH as it is; a system MPI module (`mpi/openmpi-x86_64` and
  `mpi/mpich-x86_64`, the EL package modules, then `openmpi` and `mpich`); the
  conda-forge install below. On the cloud clusters of the platform (EL images)
  this is the system Open MPI module.
- **`conda-forge`**: Open MPI 5 with conda's compilers, installed once under
  `<install directory>/benchmarks/miniforge` (env `mpi`, ~2 GB, no sudo, a few
  minutes). Its PRRTE has the `slurm` and `pbs` components, so plain `mpirun`
  launches across the nodes of a SLURM job (verified on gcpsmall).
- **`commands`**: the form's load commands, verbatim, for a site module or an
  Intel oneAPI `setvars.sh`.

The run log says which MPI ran (`MPI : Open MPI 4.1.1`, and the preprocessing
notices), and `<install directory>/benchmarks/<mpi>/MPI.txt` records the
compiler and MPI of each build. `<mpi>` is the MPI's directory with `/` turned
into `_` (`usr_lib64_openmpi`), so a second MPI never shares a build.

What is built:

- **IMB-MPI1** from the Intel MPI Benchmarks v2021.11 source with the upstream
  Makefile's flags (`-O0 -Werror`); Open MPI's deprecated C++ bindings are
  skipped (`-DOMPI_SKIP_MPICXX`, IMB uses the C API) and GCC 14's
  `template-id-cdtor` warning is demoted for that compiler. An `IMB-MPI1`
  already on PATH, as Intel MPI ships, is used as it is.
- **ior** and **mdtest** from the IOR 4.0.0 release tarball, which carries its
  `configure` (no automake, no sudo); Lustre support is detected from the headers;
  `-std=gnu17` keeps GCC 15 off C23, where IOR 4.0.0 does not compile.

The launcher is `mpirun -np <ranks>`: Open MPI and Intel MPI read a SLURM
allocation themselves; under PBS, Open MPI also gets `--hostfile $PBS_NODEFILE`.
`MPIRUN` in the environment commands replaces it (`srun --mpi=pmix`, a
site-specific wrapper). PBS has not been exercised from this repository.

## What a run leaves

In the run's job directory on the login node (`~/pw/jobs/<run-slug>/` for CLI
runs, `~/pw/jobs/<workflow-name>/<run-number>/` for registered ones):

```
inputs.sh                   the form values and PW_* variables
mpi-env.sh                  the MPI environment the build and the job sourced
benchmark.sh                the job script: inputs.sh + paths + run-template.sh
benchmark.exit              the script's exit status, written even when it failed
run.<slug>.out              the streamed output (header, command, benchmark output)
results/<benchmark>.out     the raw benchmark output
results/<benchmark>.csv     its result tables
results/outputs.txt         the headline figures, KEY=value
```

The `results` job publishes `RESULTS_DIR`, `RESULTS_CSV` and the figures:

| Benchmark | Outputs |
|---|---|
| `imb-pingpong` | `processes`, `latency_usec` and `latency_bytes` (the first row, 0 bytes), `bandwidth_mbytes_per_sec` and `bandwidth_bytes` (the row with the peak) |
| `imb-alltoall` | `processes` (the largest count run), `t_avg_usec_smallest`/`smallest_bytes` and `t_avg_usec_largest`/`largest_bytes` |
| `ior` | `write_mib_per_sec_mean`, `write_mib_per_sec_max`, `read_mib_per_sec_mean`, `read_mib_per_sec_max` from IOR's summary |
| `mdtest` | `<operation>_ops_per_sec_mean` for every row of the SUMMARY rate table (`file_creation_…`, `file_stat_…`, `directory_removal_…`, …) |

The CSVs are the tables as the tools print them: IMB-MPI1 one row per message
size with the benchmark name and process count in front (several tables for
Alltoall), IOR its per-iteration `Results` rows, mdtest the SUMMARY rate rows.

## Running from the CLI

```bash
pw workflows run "$PWD/workflows/benchmarks/yamls/general.yaml" -i '{
  "cluster": {"resource": "pw://<user>/<cluster>", "scheduler": true, "nodes": 2, "ntasks_per_node": 2,
              "slurm": {"is_enabled": true, "partition": "compute", "time": "00:30:00"}},
  "benchmark": {"name": "imb-pingpong"},
  "software": {"mpi": "auto"}}'
```

`pw workflows runs logs <slug>` has the streamed benchmark output;
`pw workflows runs errors <slug>` the summary when the run failed. A failed
benchmark fails the run with its exit status and the tail of its output; a missing
`benchmark.exit` means the script never reached its end (walltime, node failure).

## Variants

`yamls/general.yaml` targets standard cloud and on-prem SLURM/PBS clusters.
`yamls/hsp.yaml` is the HSP (`activate.hpc.mil`) form: the resource is the form's
top-level input, the job goes through the `hsp` script submitter, the SLURM group
adds the per-site **Account**, **QoS** and **Node Type** fields (shown for on-prem
`existing` resources) and the DSRC `--constraint=mla` hint, and the PBS group adds
the **Account** (`-A`) and the HSP directive defaults, whose commented per-site
`select` lines take precedence over the workflow's when uncommented. That submitter
writes `--nodes` before the form's directives, so the layout directives still win
there. `yamls/noaa.yaml` is the NOAA (`noaa.parallel.works`) form: the `noaa`
submitter and the **Account** and **QoS** fields; because that submitter writes
`--ntasks` and `--nodes` after the directives on `existing` resources, the layout
also reaches it through those two inputs (`ntasks` = nodes × ranks per node); and
with no install directory given, the builds go to the cluster's shared software tree
(`/contrib/pw` on Hera, Mercury and Ursa, `/usw/rdhpcs/software/pw` on Gaea) when the
account can write there, `${HOME}/pw/software` otherwise. The app is the same for the
three; on a cloud cluster the variants behave alike, which is how `tests/hsp/` and
`tests/noaa/` exercise them.

## Tests

`tests/<variant>/`, all on `pw://alvaro/gcpsmall` (Rocky 9, Open MPI 4.1.1 module,
8-core compute nodes):

| test | what it exercises |
|---|---|
| `general/gcpsmall-pingpong-login.json` | the login node, 2 ranks, `auto` MPI (the system module), the IMB build |
| `general/gcpsmall-pingpong-2nodes.json` | a 2-node SLURM job, 2 ranks per node, `-map 2x2` placing the pair across nodes |
| `general/gcpsmall-alltoall-conda.json` | the conda-forge Open MPI across 2 nodes × 4 ranks, `imb_args` (`-npmin 8`) |
| `general/gcpsmall-ior-minimal.json` | IOR, `minimal` preset, one node × 4 ranks, the default I/O directory |
| `general/gcpsmall-mdtest-custom.json` | mdtest, `custom` arguments, an `io_dir` with a shell variable |
| `general/fail-bad-ranks.json` | failure path: `ntasks_per_node: 0` (the API can send what the form's `min` forbids) fails in preprocessing before anything is built |
| `general/fail-mpi-commands.json` | failure path: `commands` MPI mode with a module that does not exist fails before anything is built |
| `general/fail-ior-bad-args.json` | failure path: IOR rejects an unknown option, the run fails with its exit status and the output tail |
| `hsp/`, `noaa/` | `gcpsmall-pingpong-login`, `gcpsmall-ior-minimal` and `fail-ior-bad-args` through the `hsp` and `noaa` submitters |

The failure tests set `_test.expect: error`: they pass when the run ends in error
and nothing is left behind. Every test completed with no SLURM job, process or I/O
directory left behind. A run cancelled while `ior` was running on the compute node
(`pw workflows runs cancel`) also left nothing: the submitter's `scancel` and
`cancel.sh` removed the job and the I/O directory, and `benchmark.exit` recorded `143`.

## Files

| `app/` | Role |
|---|---|
| `install-mpi.sh` | the MPI ladder (PATH, system module, conda-forge) and the conda-forge install; writes the environment file for `tools/utils/prepare-env.sh` |
| `install-benchmark.sh` | idempotent per-MPI build of IMB-MPI1 or of IOR's `ior` and `mdtest`, under a lock; records the MPI in `MPI.txt` |
| `run-template.sh` | the job script body: rank layout from the allocation, launcher, the benchmark command, `cancel.sh`, `benchmark.exit` |
| `summarize.py` | the raw output → CSV, `::notice` headline, `KEY=value` outputs (standard library only) |

Shared: `tools/utils/prepare-env.sh`, `tools/utils/miniforge.sh`.

## Provenance

Moved from the standalone `parallelworks/benchmarks` repository (its
`workflow.yaml` and `benchmarks/*/main.sh`). Beyond the layout, what changed:

- The legacy `workflow-utils` resource wrapper, the hand-written `sbatch`,
  `squeue`/`sacct` polling and the `tail -f` streaming job (four jobs) are the
  shared `script_submitter` call; the benchmark scripts no longer ssh back to the
  user container to stream or copy their output.
- Every run cloned Spack into its job directory and installed Intel oneAPI MPI
  and compilers (30+ minutes, never reused). The MPI is now the one the resource
  has, or the form's commands, or a one-time conda-forge Open MPI, and the
  benchmarks are built once per MPI and reused.
- IOR came from `git clone` + `./bootstrap` after `sudo yum install automake`; the
  release tarball needs neither. `--with-lustre` was a form toggle defaulting to
  yes, which fails `configure` on a cluster without the Lustre headers; it is
  auto-detected now.
- `ior-minimal`/`ior-standard`/`mdtest-minimal`/`mdtest-standard` are the
  `standard` and `minimal` presets of `ior` and `mdtest`, plus `custom`
  arguments; IOR reads back as well as writes (`-w -r`).
- PingPong ran with `-np $SLURM_CPUS_ON_NODE` on whatever ranks came first (two on
  the same node); the pair is now placed across nodes with `-map`.
- The plotly HTML results page used a v2 UI display route that no longer exists;
  the results are CSV files, `::notice` lines and workflow outputs instead.
