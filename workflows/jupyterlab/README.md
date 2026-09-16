# JupyterLab

Starts a JupyterLab server on a compute cluster and serves it through a `pw`
endpoint named `jupyterlab-host-<run-slug>`. The run stays green while the
service keeps running; stop it with `pw endpoints delete`.

## How it works

1. `app/controller.sh` runs on the login node: installs Miniconda and
   JupyterLab under the parent install directory (default `${HOME}/pw/software`)
   if missing, or loads an existing environment via the command you provide.
   Miniconda and the environment come from repo.anaconda.com; when that fails
   (some HPC login nodes block it), the controller unpacks a prebuilt copy of the
   same environment from `ghcr.io/parallelworks/jupyterlab-conda:<installation>`
   (x86_64, glibc >= 2.28; only the pinned installation has one). Build and
   push it with `build-conda-artifact.sh`; the hidden `conda_source` input
   (`auto` | `native` | `artifact`) forces either path. The hsp form skips the
   download entirely: it takes the registry reference of the prebuilt
   environment and unpacks that.
2. `app/start-template.sh` runs on the login node or a scheduler job
   (SLURM/PBS, your choice in the form) and launches `jupyter-lab` behind
   `pw endpoints run`.

## Form options

- Start directory for the lab UI (default `${HOME}`).
- Installation: pinned JupyterLab release, latest versions, Dask dependencies
  for PW (from `app/dask-extension-jupyterlab.yaml`, including the
  [Dask JupyterLab extension](https://github.com/dask/dask-labextension)),
  or paste your own conda environment YAML.
- Or skip installation and point at an existing environment.

For running JupyterLab on Kubernetes, see [README_k8s.md](README_k8s.md).
