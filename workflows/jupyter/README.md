# Jupyter Notebook

Starts a Jupyter Notebook server on a compute cluster and serves it through a
`pw` endpoint named `jupyter-host-<run-slug>`. The run stays green while the
service keeps running; stop it with `pw endpoints delete`.

## How it works

1. `app/controller.sh` runs on the login node: installs Miniconda and Jupyter
   under the parent install directory (default `${HOME}/pw/software`) if
   missing, or loads an existing environment via the command you provide.
2. `app/start-template.sh` runs on the login node or a scheduler job
   (SLURM/PBS, your choice in the form) and launches `jupyter-notebook`
   behind `pw endpoints run`. Works with Notebook 6 and 7.

## Form options

- Start directory for the notebook UI (default `${HOME}`).
- Installation: latest versions, a pinned Notebook release, or paste your own
  conda environment YAML. Optional Julia and R kernels.
- Or skip installation and point at an existing environment.

NOAA on-prem notes: [noaa-onprem.md](noaa-onprem.md).
