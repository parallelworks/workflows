# OpenFOAM from conda-forge (openfoam.com v2412)

> What running OpenFOAM inside a workflow taught while building
> `workflows/dakota-openfoam` (2026-09). That README holds the physics, the
> mesh-fidelity table and the run instructions; this file holds the install and
> parallel-run facts and the traps, with the symptom text you would grep for.

## Install without sudo

- `conda create -n openfoam openfoam=2412` into a Miniforge prefix (~5 min once);
  idempotence check `conda run -n openfoam simpleFoam -help`. Pattern:
  `workflows/dakota-openfoam/app/install-openfoam.sh` + `install-common.sh`
  (Miniforge itself: [conda-environments.md](conda-environments.md)).
- **Activation is incomplete:** the package does not export `FOAM_TUTORIALS` — derive
  it as `${CONDA_PREFIX}/tutorials` after `conda activate` (verified 2026-09-29).
  Check every `FOAM_*`/`WM_*` variable you rely on the same way.
- A site install works through the same code path: `module load openfoam/2412` or
  `source /opt/openfoam2412/etc/bashrc` typed into the form becomes one sourceable
  file that every case sources (`workflows/dakota-openfoam/app/prepare-env.sh`).

## Parallel runs (`-parallel`)

- **Symptom: `The dummy Pstream library cannot be used in parallel mode`** on every
  `mpirun ... <solver> -parallel` (verified 2026-09-30). The conda package ships its MPI
  Pstream under `lib/mpich-3.3` while the binaries' RPATH (and `FOAM_MPI`) name
  `lib/sys-mpich`, so the loader falls back to `lib/dummy`. RPATH beats
  `LD_LIBRARY_PATH`, so the fix is a link of the expected name to the real directory,
  made idempotently on every run so existing installs get it too
  (`install-openfoam.sh`, `f_link_mpi_pstream`). Confirm with
  `ldd $(command -v simpleFoam) | grep Pstream`.
- The env's MPI is **MPICH 4.3 with the hydra `mpirun`**; `decomposePar` has scotch,
  metis and kahip available (`ls $FOAM_LIBBIN | grep Decomp`), so `method scotch` works.
- **Launcher:** `mpirun --bind-to none -np N`. Hydra and OpenMPI both accept the flag;
  without it, concurrent launchers on one node (a login node running `batch_size` cases
  at once) all pin their ranks to the same first cores. Let the sourced environment
  export `MPIRUN` to replace the launcher (`srun --mpi=pmix` on a site that wants it)
  and validate the launcher's first word, not `mpirun`, in preprocessing.
- **Chain:** `blockMesh` → `decomposePar` → `mpirun ... potentialFoam -parallel` →
  `mpirun ... simpleFoam -parallel`. Function objects (`forceCoeffs`) write to
  `case/postProcessing` from the master rank, so objectives need no `reconstructPar`.
- **Under SLURM** one node per case, `--nodes=1 --ntasks=N`: hydra launches its ranks
  locally inside the allocation (verified 2026-09-30 on gcpsmall's 4-core nodes, two
  2-rank cases packed per node). PBS: `-l select=1:ncpus=N:mpiprocs=N`.
- **When it pays** (gcpsmall login node, NACA 2412 C-grid, simpleFoam + SA):

  | cells | 1 core | 2 ranks | 4 ranks |
  |---:|---:|---:|---:|
  | 5.4k | 6.5 s | 8.6 s | — |
  | 21.6k | ~1 min | — | 29 s |

  Below ~15k cells per rank decomposition loses to halo exchange; keep the default at
  1 core and let the user raise it with the mesh. Rank results agree with serial to
  within 0.5% on Cd.
- A mid-run cancel (submitter kills the `run.sh` process group) leaves no `mpirun`,
  `hydra_pmi_proxy` or rank behind even though hydra puts them in their own process
  groups: the proxies exit when their control connection drops (verified 2026-09-30).

## Numerics that bit

- **The same design can converge on one node type and diverge on another** (SIGFPE in
  `simpleFoam` around iteration 170 on gcpsmall's compute nodes; 800 clean iterations
  on its login node, serial and 4-rank alike, 2026-09-30): high-camber airfoils at the
  default mesh sit close to the stability edge, and floating-point differences between
  CPU types tip them. Treat divergence as a per-design result the optimizer absorbs
  (`FAIL`), not as an infrastructure failure to retry.

- On the C-grid an impulsive uniform start of SIMPLE diverges at every design point:
  initialize with `potentialFoam` first (`fvSolution` needs a `Phi` solver block).
- Finer meshes need a larger iteration cap and softer relaxation (`p` 0.25, `U`/`nuTilda`
  0.5 from `mesh_scale` 2); scale `endTime` with the mesh rather than fixing it.
- Write `0/U` wholesale when the freestream changes: a `foamDictionary` edit of
  `internalField` alone leaves the `$internalField` macros of the boundary
  conditions expanded to the old value.
