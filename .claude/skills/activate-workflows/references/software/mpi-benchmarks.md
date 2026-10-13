# MPI benchmarks: IMB-MPI1, IOR, mdtest, and the MPI under them

What `workflows/benchmarks` learned building and running the Intel MPI Benchmarks
and IOR on gcpsmall (Rocky 9, Open MPI 4.1.1 module, conda-forge Open MPI 5.0.11),
verified 2026-10-06. The scripts: `workflows/benchmarks/app/install-mpi.sh`,
`install-benchmark.sh`, `run-template.sh`.

## Finding an MPI without asking the user

- The EL images of the platform's cloud clusters ship Open MPI and MPICH as
  **modules**, not on PATH: `module load mpi/openmpi-x86_64` (`/usr/lib64/openmpi`)
  and `mpi/mpich-x86_64`. Nothing MPI is on PATH in a workflow step until a module is
  loaded, and `module` itself may be undefined there (source
  `/etc/profile.d/modules.sh` first, as `tools/utils/prepare-env.sh` does).
- `tools/utils/prepare-env.sh`'s installer contract (`bash <installer> <env-file>`,
  run when the form's snippet is empty) also fits a **detect-or-install** script: probe
  the PATH and well-known module names in a fresh `bash -c` and write what worked into
  the env file; only install when nothing is found (`install-mpi.sh`).
- **conda-forge Open MPI 5 launches across SLURM nodes with plain `mpirun -np N`**:
  its PRRTE has the `plm slurm` and `ras slurm`/`pbs` components (`prte_info | grep
  "MCA plm"`), verified in a 2-node job. The package set that also compiles against it
  is `openmpi openmpi-mpicc openmpi-mpicxx c-compiler cxx-compiler make` (~2 GB): the
  wrappers call conda's own gcc, so the compilers must come along.
- `SLURM_NTASKS` **is** set in a job requested with `--nodes=N --ntasks-per-node=M`
  (N×M), and `SLURM_JOB_NUM_NODES` with it; compute nodes carry only a few `PW_*`
  variables (`PW_POOL_NAME`, `PW_SESSION_ID`), so everything else must come from
  `inputs.sh`.
- Key the per-MPI build directory on the MPI's install directory
  (`$(dirname $(dirname $(command -v mpicc)))` with `/` → `_`, e.g.
  `usr_lib64_openmpi`): readable, and two MPIs never share a binary.

## IMB-MPI1 (intel/mpi-benchmarks)

- Tags are `IMB-v2021.11` (latest, 2024) down to `IMB-v2021.1`; the archive URL is
  `https://github.com/intel/mpi-benchmarks/archive/refs/tags/IMB-v<ver>.tar.gz`. Build
  one binary with `make IMB-MPI1 CC=mpicc CXX=mpicxx` (defaults are `mpiicx`/`mpiicpx`).
- The Makefile compiles with `override CXXFLAGS += -g -O0 -Wall -Wextra -Werror`, so:
  - Open MPI's `mpi.h` pulls the deprecated C++ bindings into every C++ unit and
    their `op_inln.h` fails `-Werror=cast-function-type`. IMB uses the C API:
    `CPPFLAGS=-DOMPI_SKIP_MPICXX` fixes it.
  - GCC 14+ (conda-forge ships 15) fails `benchmark.h:69` with
    `-Werror=template-id-cdtor` in every `-std` mode; add
    `CXXFLAGS=-Wno-error=template-id-cdtor` **only for GCC ≥ 14** (`__GNUC__` from
    `mpicxx -dM -E -x c++ -`): clang rejects an unknown `-Wno-error=` option under
    `-Werror`, and GCC 11 has no such warning.
  - `-O2` instead of the forced `-O0` fails with new warnings-as-errors; keep Intel's
    flags (the timings are MPI, not the harness).
- `-map <ppn>x<nodes>` renumbers the ranks so that 0 and `ppn` sit on different nodes:
  the way to make PingPong cross-node in a job with several ranks per node without
  launcher-specific placement flags. Benchmark names are case-insensitive
  (`pingpong`, `alltoall`); Alltoall runs tables for 2, 4, … np processes unless
  `-npmin np`.

## IOR and mdtest (hpc/ior)

- The **release tarball** (`https://github.com/hpc/ior/releases/download/4.0.0/ior-4.0.0.tar.gz`)
  carries `configure`: no `./bootstrap`, hence no automake and no `sudo yum`. `make
  install` gives `bin/ior`, `bin/mdtest`, `bin/md-workbench`.
- `--with-lustre` fails `configure` when the Lustre headers are absent; the default
  (`check`) detects them, so never expose that flag as a default-on form toggle.
- IOR 4.0.0 does not compile with GCC 15's default C23 (`option.c: too many arguments
  to function 'fp'; expected 0`); `CFLAGS="-g -O2 -std=gnu17"` (pass the `-g -O2` too,
  setting CFLAGS replaces the default).
- Output to parse: IOR's `Results:` table (`access bw(MiB/s) IOPS … iter`, one
  `write`/`read` row per iteration) and `Summary of all tests:` (`Operation Max(MiB)
  Min(MiB) Mean(MiB) … #Tasks … reps …`); mdtest's `SUMMARY rate: (of N iterations)`
  with multi-word operation names and four numbers (max, min, mean, stddev). IMB prints
  `# Benchmarking <Name>`, `# #processes = N`, then a `#bytes #repetitions …` header and
  numeric rows. `workflows/benchmarks/app/summarize.py` parses all three with the
  standard library (the login nodes have no pandas or matplotlib).
