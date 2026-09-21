# Spack MPI Stack Builder

Builds a Spack **v1** multi-MPI HPC stack on a SLURM/PBS cluster and generates Tcl
modules, publishing everything to a binary build cache so later runs install in
minutes instead of hours.

**This is a build workflow, not an endpoint/session service.** It runs to
completion and exits. It does register a `pw` endpoint at the end, but that
endpoint is a placeholder serving an empty page — see
[The placeholder endpoint](#the-placeholder-endpoint).

## What gets built

| | |
|---|---|
| Compiler | `gcc@14.2.0`, built with the system compiler, then used for everything else |
| MPIs | `openmpi@5.0.10`, `mpich@4.2.2`, `intel-oneapi-mpi@2021.13.0` |
| Applications | `gromacs@2025.4`, one build per MPI |
| Validation | `osu-micro-benchmarks`, one build per MPI |
| Optional GPU path | CUDA-aware `openmpi+cuda` and `gromacs+cuda` |

The three MPIs coexist in one environment via `concretizer: unify: false`.

## How it decides what to build for

The compile runs on the **login node** — it has internet for source fetches and
no queue walltime — but the stack is meant for the **compute nodes**, which on
most clouds are a different instance type. So a short job runs on a worker first
and reports its fabric, GPU and CPU microarchitecture.

That split has a consequence worth understanding. Spack only emits code the build
host can run, and `packages: all: target:` is a *preference*, so an unsupported
target is silently dropped rather than rejected. `app/resolve-target.py` makes the
decision explicit:

- **Worker target is older than the login node** → build exactly for the worker
  (`exact`).
- **Worker target is newer, same lineage** (skylake_avx512 → cascadelake) → the
  login node cannot emit it, so the build falls back to the login node's own
  target and says so loudly (`fallback`). Those binaries still *run* on the
  worker — a newer microarchitecture on the same lineage is a superset; they just
  leave its newer instructions unused. Build on a worker node if that last few
  percent matters.
- **The two are incomparable — different vendors** → neither target works, and
  falling back to the login node's would be silently wrong. The build targets the
  best **common ancestor** instead (`common`).
- **Different CPU family** (x86_64 login, aarch64 workers) → no target serves
  both, so the build **fails** rather than producing binaries that cannot run.

**Requesting the target is not enough — reuse has to be constrained too.**
`packages: all: target:` is a preference, and `reuse: true` outranks a
preference: an installed spec built for a different microarchitecture still
satisfies the request, so Spack takes it rather than building. On aws run
`fair-mastodon` the resolver correctly chose `x86_64_v3` for a `zen2` worker and
the environment *still* came out holding 45 `skylake_avx512` specs — `fftw`,
`gcc-runtime`, `curl` and all three CPU GROMACS builds — reused from the Intel
login node's earlier CPU stack. Those carry AVX-512 and cannot execute on zen2.
The run passed: it completed, the endpoint answered, and nothing in the pass
criteria can see a wrong-ISA binary.

The environment therefore pins reuse to the chosen target:

```yaml
concretizer:
  reuse:
    include:
    - target=<the resolved target>
```

Reuse still does its job in the normal redeploy case, where everything cached is
already at the right target, and is refused for everything else — from the local
install tree and the build cache alike.

The third case is not hypothetical and is the one that bites. On `aws` the login
node is a `c5n.9xlarge` (Intel `skylake_avx512`) while the GPU partitions are
`g6`/`g5` — AMD EPYC, `zen3`. AVX-512 is not a *subset* of zen3, it is **absent**
from it, so a `skylake_avx512` build would SIGILL on those nodes. Checked with
archspec on the login node: `zen3 <= skylake_avx512` and `skylake_avx512 <= zen3`
are **both** false. The resolver now picks `x86_64_v3` for that pair — the most
capable target both machines implement — and `zen4`/`skylake_avx512` resolves to
`x86_64_v4`.

Both cases have been seen on the same `aws` cluster across rebuilds: login node
`skylake_avx512` with `cascadelake` workers (the fallback), and — after the
cluster was rebuilt with `c5n.9xlarge` in the `cpu` partition — login and workers
both `skylake_avx512` (the exact case, run `charming-mongoose`).

## Fabric handling

| Detected | Profile | Transport |
|---|---|---|
| EFA device present | `aws` | libfabric/OFI, EFA provider |
| Verbs device + Azure | `azure` | UCX over verbs |
| Verbs device + Oracle | `oracle` | UCX over verbs |
| GCP | `gcp` | OFI / verbs |
| No RDMA hardware | `generic` | TCP + shared memory |

Hardware is authoritative; cloud identity only breaks ties. The `aws` profile
*requires* an EFA-capable libfabric rather than pinning a version, so a cluster
whose EFA install cannot do EFA fails loudly instead of silently running over TCP.

## Build cache

Every package built is pushed to `buildcache_path` (default
`${HOME}/spack-buildcache`), a directory-backed Spack mirror, and later runs
install from it. Notes:

- The mirror is **unsigned** — it is a private path only this account can write,
  and requiring a GPG keyring would make every fresh cluster a manual step.
- Pushes use `--private` because `intel-oneapi-mpi` is non-redistributable and is
  skipped silently otherwise, leaving a hole exactly where the slowest package is.
- On a cold cache Spack warns `cannot be used in concretization (no index found)`.
  That is expected: an empty mirror cannot be indexed. The index appears with the
  first push.
- Install paths are padded (`padded_length: 128`) so the cache stays
  **relocatable**. Without padding Spack refuses to move a package into a longer
  prefix (`CannotGrowString: ... because the new prefix is longer`), which ties a
  build cache to the exact install root that produced it. Verified both ways on
  an unpadded cache: redeploying into a *shorter* root worked in seconds and the
  binaries ran with no references to the original prefix, while a *longer* root
  failed outright. 128 leaves headroom for any target root up to 128 characters.

### Archiving and redeploying the build cache

The cache is a plain directory, so the robust way to move it is to tar it and
copy it — no symlinks are involved, and `build.sh` pushes with `--update-index`,
so the index is current and no extra sync step is needed:

```bash
tar -czf spack-buildcache.tar.gz -C "$(dirname "$buildcache_path")" "$(basename "$buildcache_path")"
```

Two things to know before shipping one:

- **Relocation is what padding buys.** With `padded_length: 128` the binaries can
  be unpacked and installed under a different root. An *unpadded* cache can only
  ever move to a root no longer than the one it was built in.
- **The cache contains `intel-oneapi-mpi`,** because `build.sh` pushes with
  `--private` (without it Spack silently skips non-redistributable packages and
  leaves a hole where the slowest package should be). Intel oneAPI has
  redistribution terms, so keep such an archive in a private bucket, or push
  without `--private` to omit it.

## Redeployment: what a warm cache is worth

Measured on `aws`, run `charming-mongoose` (recorded as
`tests/general/buildcache-redeploy.json`). The cluster had been rebuilt, `${HOME}`
held nothing but a copied `spack-buildcache`, and `${HOME}/spack` and
`${HOME}/.spack` were deleted before the run:

| | |
|---|---|
| Whole run, submission to endpoint | **7 min 43 s** |
| Cache forecast after concretization | 66 of 66 buildable specs cached, 4 external |
| What the install did | 36 specs from the build cache, **0 compiled from source** |
| Against a cold build of the same stack | ~1.6 h at `-j8` |

Afterwards all three MPIs load with a working `mpirun` and
`gromacs/2024.3-openmpi-5.0.10` reports `2024.3-spack` — from binaries alone, on a
machine that had no Spack on it ten minutes earlier. (That run predates the
GROMACS 2025.4 bump below, so its cached GROMACS specs no longer apply; the
measurement of what a warm cache is worth still stands.)

Note the install paths contain literal `__spack_path_placeholder__` components.
That is the `padded_length: 128` padding on disk, not a relocation failure; it is
exactly what makes the cache relocatable into a different root.

## Build times (rule of thumb)

**Budget roughly 2 hours on 8 cores for a cold CPU-only build.** One measured
sample: 100 packages, ~1.6 h wall clock at `-j8` on the `generic` profile with an
empty cache.

`gcc@14.2.0` is ~30 min of that and everything waits on it, so a second run
against the same prefix and target is far quicker — it comes back from the build
cache. The rest is cheaper than "three MPIs and three GROMACS" sounds: Intel MPI
is a prebuilt tarball that never compiles, and CPU-only GROMACS is minutes per
build. More cores help sublinearly, since gcc's bootstrap does not parallelise
well. Times exclude cloning Spack and downloading sources, which are
internet-bound rather than CPU-bound.

## Overrides

`target`, `fabric` and `cuda-arch` are **all-or-nothing**: set all three to skip
hardware inspection entirely (no worker is allocated), or none to inspect. Partial
overrides are rejected. Use `cuda-arch=none` to force a CPU-only build.

## Options worth knowing

- **Stop after concretizing** (`concretize_only`) bootstraps Spack, sets up the
  build cache, inspects the hardware, renders and concretizes — then stops before
  the long compile. This is the fast way to validate a new cluster or a spec
  change, and it is what the recorded test uses.
- **Spack root** (`install_prefix`, default `${HOME}/spack`) must be on a
  filesystem shared between login and compute nodes. Keeping it in user space is
  what removes every `sudo` from this workflow.

## Where the modules go, and holding several stacks

The module tree root is the `module_root` form input (default
`${HOME}/pw/software/modules`), not a fixed path under the Spack root, because a
cluster is expected to hold more than one stack.

Spack keys the tree by **spec** architecture — `<root>/<platform>-<os>-<target>`
— so stacks built for different targets already separate themselves. Point
separate stacks at separate roots when you want them independent beyond that.

One consequence catches everyone: a *single* stack spans **two** of those
directories. The packages carry the stack target (`linux-rocky9-skylake_avx512`),
while the external compiler carries a generic one (`linux-rocky9-x86_64`), so the
`gcc` modulefile is filed apart from everything built with it. Both belong on
`MODULEPATH` — see "After the build".

Three things were wrong here and are now fixed:

- **`module tcl refresh --delete-tree` wiped other stacks.** `--delete-tree`
  deletes the whole tree and regenerates only the current environment's specs, so
  building a CPU stack removed the GPU stack's modules from the same root while
  leaving its installs in place — run `powerful-jaguar` erased the modules
  `moral-silkworm` had written that morning. The refresh no longer passes it.
- **The "DONE" banner printed the wrong `MODULEPATH`.** It was built from
  `spack arch`, which reports the *login node*, while modules are written under
  the *spec's* architecture. On a cross-architecture cluster — the case this
  workflow exists for — those differ: `moral-silkworm` built `x86_64_v3` and told
  users to add the `skylake_avx512` directory, which held none of its modules. It
  is now composed from the resolved target.
- **The banner offered no compiler, and said there was none to offer.** It
  printed the stack tree alone and a note claiming no `gcc` module exists or can
  exist — which was never true: `include:` overrides `exclude`, so the external
  compiler does get a modulefile, in the generic-target tree the banner never
  mentioned. Users could load and run the stack but had no `gcc` on `PATH` to
  build against it. The banner now locates that tree with `spack module tcl find
  --full-path gcc` (the generic target is not derivable from `$TARGET`), prints
  both directories and a `module load gcc` line, and warns against pointing
  `MODULEPATH` at their parent.

## Module names in a GPU build

A GPU environment holds a `~cuda` and a `+cuda` build of the same
name/version/compiler — `openmpi`, `gromacs`, `fftw`, `hwloc` and others — and
the CPU projections name both identically, so `module tcl refresh` aborts with
`Name clashes detected in module files`. That happens **after** a fully
successful install, which is how `caring-warthog` managed to build and push the
entire GPU stack and still fail.

GPU builds therefore get two extra things, and CPU builds are untouched:

```
gromacs/2025.4-openmpi-5.0.10-cuda-<hash>     GPU build
gromacs/2025.4-openmpi-5.0.10-<hash>          CPU build
```

- a **`-cuda` suffix**, which means exactly one thing: *this package is
  CUDA-enabled*. The constraint is `+cuda` on the package itself.

  It must **not** be written `^mpi+cuda`. A variant constraint on a *virtual* is
  silently dropped, so that degenerates to `^mpi` and matches every MPI build:

  ```
  ^mpi+cuda      → dtymywh dzhjyzk tf5yvlt 7izjiju   (all four — wrong)
  ^openmpi+cuda  → tf5yvlt 7izjiju                   (concrete provider — correct)
  +cuda          → 7izjiju                           (the package itself)
  ```

  Run `moral-silkworm` consequently labelled its `mpich~cuda` and
  `intel-oneapi-mpi` GROMACS builds `-cuda`, though neither they nor their MPI
  had any CUDA — three of four builds mismarked, the opposite of the point.
  Constrain the concrete provider, or the package, and matching behaves.

  Two rules, in this order: `+cuda ^mpi` first, so a CUDA-enabled package that
  links an MPI keeps the MPI in its name; then `+cuda` alone, which catches the
  CUDA-aware MPIs themselves — they *provide* mpi rather than depend on it, so
  they never match the first rule. The result carries one suffix per genuinely
  CUDA-enabled spec:

  ```
  gromacs/2025.4-openmpi-5.0.10-cuda-7izjiju    gromacs+cuda
  gromacs/2025.4-openmpi-5.0.10-tf5yvlt         gromacs~cuda on CUDA-aware openmpi
  gromacs/2025.4-mpich-4.2.2-dzhjyzk            gromacs~cuda
  openmpi/5.0.10-gcc-14.2.0-cuda-uoyrl2w        openmpi+cuda
  mpich/4.2.2-gcc-14.2.0-embhosw                no CUDA anywhere
  ```
- a **hash suffix** (`hash_length: 7`), because a suffix alone is not enough:
  `pmix` and `prrte` each appear twice with *identical* variants, differing only
  in which `hwloc` they were built against, and no projection can express that.

Spack picks the first projection whose constraint the spec satisfies, in the
order they are written, with `all` reserved as the fallback — see
`get_projection` in `lib/spack/spack/projections.py`.

## After the build

The build ends with a `=== DONE ===` banner that prints these paths for the
stack it just built. Take them from there rather than composing them by hand;
the shape is

```bash
export MODULEPATH=<module_root>/<arch>:<module_root>/<generic-arch>:$MODULEPATH
module load gcc/<gccver>-none-none              # gcc/g++/gfortran, to compile
module load openmpi/<version>-gcc-<gccver>      # or mpich / intel-oneapi-mpi
module load gromacs/<version>-openmpi-<version>
```

which on a `skylake_avx512` CPU stack installed with the default module root is

```bash
M=$HOME/pw/software/modules
export MODULEPATH=$M/linux-rocky9-skylake_avx512:$M/linux-rocky9-x86_64:$MODULEPATH
```

**Two directories, and `MODULEPATH` must name them, not their parent.** The
`depends-on` lines Spack writes into every modulefile are *bare* names
(`gcc-runtime/14.2.0-none-none`), resolved against a `MODULEPATH` entry. Point
`MODULEPATH` at `$M` and the modules are named `linux-rocky9-skylake_avx512/…`
instead, so every one of those requirements misses and the load aborts:

```
$ export MODULEPATH=$HOME/pw/software/modules
$ module load linux-rocky9-skylake_avx512/openmpi
  ERROR: Unable to locate a modulefile for 'gcc-runtime/14.2.0-none-none'
  ERROR: Load of requirement gcc-runtime/14.2.0-none-none failed
```

Nothing loads, and — because the `module` command still returns 0 — the shell is
left on the *system* MPI, which is the same silent-wrong-direction failure
`external-modules.py` exists to prevent.

**The `gcc` module lives in the second tree**, the `<generic-arch>` one. The
stack compiler is registered as an *external* (the solver refuses to build the
provider of the `c` virtual, see `build.sh`) and `build.sh` excludes every
external from the module tree — but `include: [gcc, …]` in `spack.yaml.in` takes
precedence over `exclude` (`return not include_matches and (exclude_matches or
excluded_as_implicit)`, `lib/spack/spack/modules/common.py`), so `gcc` alone
comes back. It lands in a tree of its own because the external entry carries a
*generic* target (`x86_64`) while everything built with it carries the stack
target, and Spack files modules by the spec's architecture.

That second tree is what makes the stack usable for *building*, not just
running: it sets `PATH`, `MANPATH`, `CMAKE_PREFIX_PATH` and
`CC`/`CXX`/`FC`/`F77` to the Spack compiler. With only the first tree, `module
load openmpi` succeeds and `mpirun` works — every package is RPATH-linked and
`gcc-runtime` carries the runtime libraries — but no compiler lands on `PATH` to
compile anything new against it. `spack load gcc` does the same job without
modules.

Use the **full** module name. Plain `module load openmpi` can match a system
module of the same name earlier on `MODULEPATH` and silently give you the system
MPI instead.

Always run these binaries **through the module**, not by absolute path. Intel MPI
in particular needs the environment the module sets; invoked bare, `gmx_mpi` dies
in `MPIDI_OFI_mpi_init_hook -> open_fabric`.

The OSU binaries install under `libexec/osu-micro-benchmarks/mpi/...`, not `bin`,
so they are not placed on `PATH` by design.

Verified on this cluster: all three MPIs run `osu_latency` (0.25-0.56 us
intra-node) and all three GROMACS builds report `2024.3-spack` — measured before
the 2025.4 bump.

Launcher note: OpenMPI 5 dropped the `pmi` and `legacylaunchers` variants, and
this stack does not assume a PMIx plugin in Slurm. Check `srun --mpi=list` on your
cluster; where only `pmi2` is offered, launch with `mpirun` inside an allocation,
or `srun --mpi=pmi2`.

MPICH is built **without** `+slurm`: `--with-slurm` needs Slurm headers, and
`slurm-devel` is absent on images that ship only the Slurm runtime. `pmi=pmi2`
gives the integration that matters without them. On a cluster that does have the
headers, adding `+slurm` is a reasonable improvement.

MPI versions and fabric variants are stated as **package requirements**, not
inside each spec. `gromacs` and `osu` depend on a bare `^openmpi`/`^mpich`, and
under `unify: false` that otherwise concretizes to a different node than the
standalone MPI spec — building two copies of every MPI and linking GROMACS
against one while the module tree advertises the other.

## Layout

```
yamls/general.yaml        preprocess -> detect (worker) -> build (login node)
                          -> verify -> endpoint + wait_for_endpoint
app/controller.sh         login node: bootstrap Spack, externals, build cache
app/detect-fabric.sh      worker: fabric + GPU + microarchitecture probe
app/build.sh              login node: render, concretize, install, push, modules
app/start-template.sh     login node: the placeholder endpoint
app/inspect-buildcache.py build cache inventory, integrity and hit/miss forecast
app/resolve-profile.sh    all-or-nothing override policy
app/resolve-target.py     reconcile worker target with what the build host can emit
app/render-env.py         spack.yaml.in + fabric fragment -> spack.yaml
app/packages.yaml         site externals baseline (policy, not versions)
app/templates/            environment template + 5 fabric fragments
tests/general/            recorded end-to-end test
```

## Known gaps and deferred work

- **The whole GPU stack builds.** Verified on gce2 run `caring-warthog`: UCX
  1.19.1, `gdrcopy`, the CUDA-aware `openmpi@5.0.10 +cuda`, `fftw` against it and
  `gromacs@2025.4 +cuda cuda_arch=90` all installed and pushed to the cache. What
  is still unverified is *running* those binaries on a GPU.
- **GROMACS is 2025.4 because 2024.3 does not link against CUDA 13.** Verified on
  gce2 run `funky-pigeon`: GROMACS compiled with the right architecture
  (`compute_90`/`sm_90`) and then failed at link with a single unresolved symbol,
  its own `__global__` function template instantiation —
  `undefined reference to void nbnxn_kernel_prune_cuda<false>(...)` plus
  `relocation R_X86_64_PC32 against undefined hidden symbol`. No library was
  missing; nvcc 13.2 emits such instantiations as hidden stubs the host
  translation unit cannot reference. Spack cannot warn about this: the package
  declares `depends_on("cuda", when="+cuda")` with **no upper bound**, so any
  GROMACS pairs with any CUDA and the mismatch appears only after the whole CPU
  stack has built (1h28m in that run). Both 2025.4 specs, CPU and GPU, were
  checked with `spack spec` before committing.
- **`cuda_arch` is set once under `packages: all: variants`, not per spec.** Only
  packages that *have* the variant pick it up. Setting it per-spec reached
  `gromacs` and missed everything transitive: in the same run `ucx` and `gdrcopy`
  concretized with `cuda_arch:=none`, and gdrcopy ran
  `nvcc --generate-code arch=compute_none,code=sm_none` → `nvcc fatal :
  Unsupported gpu architecture 'compute_none'`. One consequence worth knowing:
  inside a GPU run the CPU GROMACS specs also carry `cuda_arch`, so their hashes
  differ from the same specs built by a CPU-only run and the two cannot share
  cache entries. CPU-only runs are untouched — the key is only added when the GPU
  path is active.
- **The GPU path still has not completed a run**, now because of UCX rather than
  GROMACS. Two distinct UCX failures, one after the other:
  1. `hopeful-haddock`: `^ucx@1.17.0 +verbs +rdmacm +dc` could not configure
     against an image whose rdma-core external has no headers — the identical
     failure the gcp fragment's own header documents for the CPU path, which its
     GPU spec then asked for anyway. Fixed to `~verbs ~rdmacm ~dc +cuda +gdrcopy`.
  2. `many-mako`: with the RDMA transports gone UCX configured and reached the
     compile, then failed on CUDA 13:
     `cuda_copy_md.c:405:5: error: unknown type name 'PFN_cuMemGetHandleForAddressRange';
     did you mean 'PFN_cuMemGetHandleForAddressRange_v11070'?` — CUDA 13 dropped
     the unsuffixed typedef and UCX 1.17.0 predates it. **UCX is now 1.19.1**,
     across all five fragments, the same reasoning that moved GROMACS to 2025.4.
     Note that bump touches the azure and oracle fragments, whose UCX-over-verbs
     paths remain untested on real InfiniBand; leaving them on a pin known to be
     incompatible with CUDA 13 seemed the worse of the two risks.
- **GPU detection works; the GPU build has still not been run end to end.**
  Verified on gce2 (run `loving-firefly`): the inspection job reports
  `2x NVIDIA H100 80GB HBM3`, `cuda_arch=90`, driver `595.45.04`, driver CUDA
  `13.2`, toolkit `nvcc 13.2`. What is still unverified is everything after that
  — whether `openmpi+cuda` and `gromacs +cuda` build against **CUDA 13.2**. Note also that the aws `gpu` partition advertises `Gres=(null)`, so a
  `--gpus=` request there has nothing to bind to; gce2 does advertise its GPUs.
  Run `moral-ghost` was the first to reach the CUDA registration and found a
  second latent bug there: `spack config add "packages:cuda:externals:[{spec: …}]"`
  cannot work, because `config add` splits its argument on `:` and the colons
  inside the inline mapping become path components. The external is now written
  as a YAML file and merged with `spack config add -f`, which was verified
  against Spack 1.2.2 before being committed.
- **A GPU build now fails when no usable GPU is reported**, instead of quietly
  producing the CPU stack. If inspection lands on a GPU-less node, or the node's
  GPUs are hidden from a job that requested none, the run stops in the first
  minutes with an actionable message rather than after two hours with the wrong
  artefact.
- **The `common` target branch is unit-tested, not run.** Every branch of
  `resolve-target.py` was exercised against archspec on the aws login node
  (`zen3`→`x86_64_v3`, `zen4`→`x86_64_v4`, `cascadelake`→fallback,
  `skylake`→exact, `neoverse_v1`→error), but no build has yet been produced
  through it, because that needs an AMD compute node.
- **The gce2 redeploy is recorded as a failure, not a verdict on the workflow.**
  Run `creative-rat` never got a compute node (1h38m in `CF`) and was cancelled.
  What it did establish, from the controller log alone, is that the gce2 build
  cache is *intact but incomplete*: 35 specs, 872 MiB, all blobs present and the
  right size, containing `gcc` and its build closure and nothing above it.
- The PBS path is untested.
- Heterogeneous clusters need one run per node type; the design assumes one
  representative worker.
- Thumbnails are placeholders.
- **Module flavour is Tcl.** If the site standard is Lmod, flip the template's
  `modules.default.enable` to `[lmod]` and add a `core_compilers` list — Lmod
  needs it to build its hierarchy.
- **Deferred enhancements:** a GPU-aware OSU build (`-d cuda`) for device-buffer
  bandwidth numbers, and cuFFTMp to let GROMACS spread PME across multiple GPUs.

## Verifying the stack actually runs

A build exiting 0 and an endpoint answering HTTP say nothing about whether the
binaries can execute. The build happens on the **login node**, so a stack
compiled for the login node's ISA runs there perfectly and every recorded
criterion passes. Run `fair-mastodon` did exactly that: it passed while 45 specs
in the environment -- three GROMACS builds among them -- carried `skylake_avx512`
AVX-512 instructions that its `zen2` worker could not execute.

So the workflow runs the binaries on a compute node, in its own job
(`exec_check` + `exec_verify`). It has to be a separate submitted job: a check
that runs where the build ran proves nothing, because that is the node whose ISA
the binaries wrongly match.

`app/check-exec.sh` runs `gmx_mpi -version` for every GROMACS install in the
environment, **under that package's own run environment** (`spack load --sh`),
and separates two verdicts, which mean different things:

Running the bare binary path is not representative and produces false failures.
`intel-oneapi-mpi` needs `FI_PROVIDER_PATH` to locate the libfabric providers it
ships; without it `MPI_Init` aborts with `OFI fi_getinfo() failed ... No data
available` on a binary that is completely sound -- run `powerful-jaguar` reported
exactly that, and setting the variable made the same binary run. `spack load --sh`
is used rather than `module load` deliberately: it produces the same environment
without touching the TCL module tree, whose name clashes in a GPU build are the
reason modules are avoided here at all.


- **SIGILL (exit 132)** -- the binary cannot execute on this CPU. This is the
  fault the job exists to catch, and it fails the run.
- **anything else** -- the binary started but its MPI could not initialise here.
  This warns rather than fails. It is a property of the launch environment, not
  of what was compiled: MPICH built `--with-pmi=pmi2` has no process manager to
  reach when run standalone (`write_line error; fd=-1`), and `intel-oneapi-mpi`
  aborts with `OFI fi_getinfo() failed` on a node with no suitable provider.
  Failing on those would fail a run on every cluster without an EFA device.

A non-SIGILL failure is retried once under the binary's own launcher, resolved
from the MPI it actually links against (`ldd`) rather than whatever `mpiexec` is
on `PATH`. If *every* binary fails, the job fails regardless: nothing was proven
to run, which is the same as having no check at all.

### Why it does not use `srun`

The job is submitted to the compute partition, so the script is already running
on a worker -- `srun` is not needed to reach one, and it cannot launch half of
these binaries anyway:

    $ srun --mpi=list
    none, cray_shasta, pmi2          # no pmix
    $ ls /usr/lib64/slurm/           # mpi_pmi2.so, libpmi2.so present
    $ ls /usr/include/slurm/pmi2.h   # missing, as is pmix.h

OpenMPI 5 dropped native PMI2 in favour of PMIx, and this SLURM has no pmix
plugin, so `srun ./gmx_mpi` cannot start the OpenMPI-linked builds -- the CUDA
one among them -- although they run perfectly standalone via singleton init.
Running directly and falling back to the binary's own launcher avoids PMI
negotiation entirely. This is the same split the header probe reports: the PMI
runtime libraries are installed, the headers to build against are not.

When the check does land on the node that built the stack -- which happens with
`scheduler=false`, where there is no separate compute node -- it says so with a
warning, because in that configuration it cannot detect a microarchitecture
mismatch at all.

## Header inventory: head node vs compute node

`spack external find` detects a package from its libraries, but Spack then
COMPILES against it, which needs the `-devel` headers. `prune-headerless-externals.py`
removes externals that lack them, but silently -- so a build that failed on a
missing `ucx` or `pmi2` header left nothing in the log saying which headers the
node actually had.

`app/probe-headers.sh` now records that inventory explicitly, on **both** nodes,
as part of the `detect` job:

- `Inspect compute node` writes `headers.compute.env` beside `fabric.env`.
- `Inspect head node` writes `headers.head.env`, and also logs the head node's
  own parameters -- microarchitecture, OS image, kernel, glibc, gcc, nvcc --
  which were never written down anywhere before. When a stack misbehaves on the
  worker the first question is how the two nodes differ, and that was
  unanswerable after the fact.

Probed: `UCX`, `LIBFABRIC`, `VERBS`, `RDMACM`, `SLURM`, `PMI2`, `PMIX`, `CUDA`,
`GDRCOPY`.

The two sets are then diffed, and the asymmetry matters:

- **present on compute, missing on head → the run fails loudly.** The build
  links on the head node, so such a header cannot be used no matter what the
  worker supports. This is the split-image case, and it otherwise surfaces as a
  configure error hours into a compile.
- **present on head, missing on compute → warning.** It builds, and may still
  run, because the runtime library can be present while only the headers are
  absent.

With full overrides the `detect` job is skipped entirely, so neither probe runs
and there is nothing to compare.

## The placeholder endpoint

The last two jobs (`endpoint`, `wait_for_endpoint`) start a `pw` endpoint named
`spack-builder-<run-slug>` that serves one static page: the run slug, the
resolved fabric profile and the `MODULEPATH` to use — read from
`modulepath.env`, which `build.sh` writes in the shared run directory, because
the endpoint job runs elsewhere with no Spack set up and cannot work the two
module trees out for itself. **Nothing in the build
needs it.** It exists because the shared end-to-end test runner
(`tools/tests/run-workflow-test.py`) passes a run only when

```python
row["result"], row["error"] = "fail", "run completed but no endpoint listed"
```

does *not* fire — an endpoint named `*-<run-slug>` must be listed and its URL
must answer. This is the only workflow in the repository that serves nothing, so
rather than teach the shared runner a new pass mode, it serves an empty page.

The endpoint outlives the run, exactly like a real service: `wait_for_endpoint`
touches the `SKIP_CLEANUP` marker once the endpoint answers and cancels the
submitter, so the run completes with the endpoint still up and the test runner
can find it, check it and then `pw endpoints delete` it. On a **cancel** — and on
any teardown that does not skip cleanups — `cancel.sh` deletes the endpoint
explicitly (`pw endpoints delete`) before killing the process group. Deleting it
is the part that matters: killing the process alone would leave a stale entry in
`pw endpoints list` that outlives the run.

Delete it by hand after a manual run:

```bash
pw endpoints delete spack-builder-<run-slug>
```

**This is expected to be removed.** The build is finished and the stack is usable
before the endpoint starts; it is scaffolding for the test framework, not a
feature. If the runner grows a way to express "this workflow serves nothing and
its result is a command that must succeed on the resource", these two jobs and
`app/start-template.sh` should go. Keep them only if a real use for a served page
appears — a browsable build log or module list would be one.

## Diagnosing a run from the logs alone

Whoever reads a failed run usually has no shell on the cluster, so the things
needed to explain a build are printed rather than left on the node:

| Question | Where the answer is printed |
|---|---|
| What is this node, and is the disk full? | `controller.sh` site facts: host, OS, kernel, cores, memory and `df -h` for `$HOME`, the Spack root and the cache — printed before anything can fail |
| Did the mirror index? | `controller.sh` reports the result of `spack buildcache update-index` instead of swallowing it. An unindexed mirror is silently ignored by the concretizer, and the only other symptom is that everything rebuilds |
| What is in the build cache, and did it arrive intact? | `inspect-buildcache.py` inventory: spec count, packages, and a blob-level integrity check (every manifest's blobs present and the exact size the manifest records) |
| Will this run use the cache, or compile for two hours? | `inspect-buildcache.py --lock` after concretization: hits, misses, and for each miss the same-named cached spec it collided with |
| Which hardware did the stack get built for? | `detect-fabric.sh` echoes the resolved `fabric.env`; `build.sh` prints the profile and the target decision. The login node's CPU model and `spack arch -t` are in the controller's site facts |
| Is there really a usable GPU, and which CUDA? | `detect-fabric.sh` logs the GPU model, compute capability, driver version, the driver's CUDA runtime and the toolkit's `nvcc` version — and logs *why* when `nvidia-smi` gives no answer, rather than leaving an unexplained empty `cuda_arch` |
| Why did a package fail to compile? | `build.sh` inlines the last 80 lines of each failing package's Spack build log, which otherwise only exists on the node |
| Did the build actually succeed? | `BUILD_STATUS` + the `verify` job. `script_submitter`'s unscheduled path detaches the script and polls `kill -0`, so it sees that the process ended but never its exit status |

### Reading the logs

```bash
pw workflows runs logs   <slug>            # everything, in order
pw workflows runs logs   <slug> --failed   # only failed steps
pw workflows runs errors <slug> -o text
```

**`--job build` matches nothing.** A submitted script's output is not filed under
the job name in this YAML: `script_submitter` contributes its own job names, so
everything the three submitted scripts print appears under `preprocessing`,
`slurm_job`, `ssh_job` and `stream_output` — and all three submissions share
them. Read the unfiltered log and search for the `=== [controller] ===`,
`=== [detect] ===` and `=== [build] ===` banners instead.

On the node, each submitted job gets its own directory under the run dir:

```
~/pw/jobs/<slug>/           inputs.sh, fabric.env, spack-env/, the assembled scripts
~/pw/jobs/<slug>/detect/    run.<JOBID>.out of the hardware probe
~/pw/jobs/<slug>/build/     run.<JOBID>.out of the build, spack-install.log, BUILD_STATUS
~/pw/jobs/<slug>/endpoint/  run.<JOBID>.out of the placeholder endpoint, endpoint-root/
```

They must stay separate: `script_submitter` streams to `run.${PW_JOB_ID}.out`
and all three submissions of a run carry the **same** `PW_JOB_ID`, so one shared
directory means each job truncates the previous one's log. That is how the aws
run `charming-mongoose` lost its entire build log to the endpoint job, leaving
the platform-side log as the only copy.

`fabric.env` is **sourced**, so every value it carries is quoted on write. Until
the GPU fields arrived every value was a single token — profiles, 0/1 flags,
paths, targets — so nothing needed quoting and nothing revealed the gap. The
first multi-word value (`GPU_NAME=NVIDIA H100 80GB HBM3`) made line 8 parse as an
assignment followed by the command `H100`, and `build.sh` aborted with status 127
before running anything. `bash -n` does not catch this; writing the file with
real values and sourcing it does.

A failing `spack install` prints the tail of `spack-install.log` itself, not only
the per-package logs Spack names. Those named paths point into the build stage,
which Spack removes when `install` exits, so by the time the handler runs they
are usually gone — on `hopeful-haddock` the loop found both paths and could read
neither. Spack's own streamed excerpt of the failing build (the `>`-marked lines)
is in `spack-install.log` and is what actually carried UCX's
`configure: error: RDMACM requested but required file (rdma/rdma_cma.h)`.

The integrity check compares **sizes**, not checksums: hashing a 1.4 GiB cache
on every run costs minutes, and the failure it guards against — an interrupted
copy or a full disk — truncates files, which a size check catches exactly.

A cache miss is reported as a *warning*, not an error, in both cases (damaged
blobs and no matching hash): Spack compiles what it cannot extract, so the run
still produces a correct stack. What the reader needs is the reason it suddenly
takes two hours, and the two causes look identical from the outside —

- **damaged**: manifests exist but blobs are missing or truncated → re-copy the cache.
- **complete but irrelevant**: every hash differs because this image resolved
  different externals, or the fabric profile or microarchitecture changed → working
  as designed; the run rebuilds and pushes, and the cache then serves both.

## Recorded tests

`tests/general/` holds the end-to-end tests, run by
`python3 tools/tests/run-workflow-test.py <test>.json`:

| test | what it covers |
|---|---|
| `cpu-smoke.json` | `concretize_only` into a throwaway Spack root on `aws`: bootstrap, externals, build cache, worker inspection, render and solve, in minutes rather than hours. The cheap way to validate a cluster or a spec change |
| `buildcache-redeploy.json` | a full install on `aws` with a build cache already present — the redeployment case: a fresh cluster whose only Spack artifact is a copied `${HOME}/spack-buildcache` |
| `gce2-buildcache-redeploy.json` | the same redeployment on `gce2`, a different cloud and image: the externals differ, so it is also the test of whether a cache built elsewhere still applies |

Each sets a `warm_marker` on the Spack root and the cache, so the CSV records
whether a row was a cold, warm or partial start — for the redeploy tests,
`partial` (cache present, no Spack root) *is* the case under test.
