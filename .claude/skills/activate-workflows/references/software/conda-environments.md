# Conda environments on login nodes (sudo-free software)

> How the workflows here install scientific software without root, and where that
> broke. Examples: `tools/utils/miniforge.sh` (Miniforge
> bootstrap shared by two installers), `workflows/jupyterlab/build-conda-artifact.sh`
> (prebuilt env as an artifact).

## Miniforge, not Miniconda

- Bootstrap Miniforge from its GitHub release (`Miniforge3-Linux-x86_64.sh -b -p
  <prefix>`); it defaults to conda-forge and avoids repo.anaconda.com's terms of
  service. Check every download and installer's exit status.
- Idempotence: `[ -x <prefix>/bin/conda ]` for the bootstrap, then
  `conda run -n <env> <tool> --version` (or `-help`) before `conda create`, so a
  re-run finds a working env and skips.
- Keep several envs in one prefix under
  `${service_parent_install_dir:-$HOME/pw/software}/<workflow>/miniforge`, and any
  post-install repair (a missing symlink, a variable the activation forgets) in the
  installer so re-runs apply it to existing installs too.
- **conda-forge stacks activate incompletely:** check the variables a tool's own
  `etc/bashrc` would have set (OpenFOAM's `FOAM_TUTORIALS`, see
  [openfoam.md](openfoam.md)) and derive what is missing after `conda activate`.

## Activating inside a run

- `source <prefix>/etc/profile.d/conda.sh && conda activate <env>` — put these two
  lines in one file that preprocessing writes and every later step and case sources
  (`tools/utils/prepare-env.sh`); absolute paths work on compute
  nodes because the home filesystem is shared. Validate it in preprocessing by
  sourcing it in a fresh `bash -c` and checking `command -v <tool>`.
- `conda run -n <env> <cmd>` is fine for one-off checks; do not wrap a long-running
  service in it (it buffers output and adds a wrapper process to kill).

## Login nodes that block repo.anaconda.com (hsp `jean`): ship a prebuilt env

A download that runs under `nohup` with its output sent to a file is never checked, so
the failure surfaces 80 lines later as "command not found". Check every download and
installer, and ship the fallback as a conda-pack tarball on ghcr
(`workflows/jupyterlab/build-conda-artifact.sh`, pulled with `oras_pull_file`). Packing
a Miniconda root prefix works (`--exclude 'pkgs/*' --exclude 'envs/*'`); run the
generated `conda-unpack` as `<prefix>/bin/python <prefix>/bin/conda-unpack` because its
`#!/usr/bin/env python` shebang finds no `python` on RHEL 8 (verified in a Rocky 8
container). Build with `CONDA_OVERRIDE_GLIBC=<target>` and `PIP_ONLY_BINARY=:all:`, and
whitelist pure-Python sdists (`PIP_NO_BINARY=jupyterlab-slurm`) that publish no wheel.
Pull it through `tools/oras/libs.sh:oras_pull_file` (retries; anonymous first — a stale
ghcr login in `~/.docker/config.json` makes `oras pull` say `denied` for a public
package).
