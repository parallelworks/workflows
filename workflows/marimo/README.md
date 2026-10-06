# marimo

Starts a [marimo](https://marimo.io) notebook server on a compute cluster and serves
it through a `pw` endpoint named `marimo-<run-slug>`. The run completes once the
endpoint answers; the server keeps running until `pw endpoints delete marimo-<run-slug>`.

## How it works

1. `app/controller.sh` runs on the login node: installs Miniforge and marimo from
   conda-forge under the parent install directory (default
   `${HOME}/pw/software/.miniforge3-marimo`) if missing, or loads an existing
   environment with the command you provide. The default installation is the
   environment pinned in `app/marimo0.25.1-python3.14.7.yaml`, exported from a
   tested install and bootstrapped with the Miniforge release it came from.
2. `app/start-template.sh` runs on the login node or inside a scheduler job
   (SLURM/PBS, your choice in the form) and launches `marimo edit` or `marimo run`
   behind `pw endpoints run`. marimo listens on the loopback address only; the
   endpoint requires the platform login, so marimo's own access token is disabled.

## Form options

- **Notebook Mode**: `Edit` opens the notebook editor, `Run` serves the notebook as
  a read-only app.
- **Notebook Path**: a marimo notebook (`.py`) on the cluster. In edit mode it may be
  empty (marimo's home page in your home directory, listing the notebooks there and
  creating new ones), a directory (the home page in that directory) or a `.py` that
  does not exist yet (a new notebook). Run mode needs a notebook.
- **Installation**: the pinned environment, the latest marimo and Miniforge from
  conda-forge, or paste your own conda environment YAML. Or skip the installation
  and point at an existing environment with a load command.
