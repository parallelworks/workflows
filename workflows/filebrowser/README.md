# File Browser

[File Browser](https://filebrowser.org) web file manager in Docker on a compute cluster,
served through a `pw` endpoint named `filebrowser-<run-slug>`. The run completes once the
endpoint answers; the container runs until `pw endpoints delete filebrowser-<run-slug>`.

## How it works

- `app/controller.sh` creates the mounted directories on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job: pulls the image,
  bootstraps or updates the File Browser database with the form's authentication, and
  runs the container with Docker Compose behind `pw endpoints run`. The container runs
  as your user, so the files it creates belong to you.

## Form options

- **Root Directory**: what File Browser serves (default `${HOME}/filebrowser/data`).
- **Run Directory**: File Browser's configuration and database (default
  `${HOME}/filebrowser`); reuse it to keep users, settings and shares.
- **Authentication**: *Platform login only* (default) signs whoever opens the endpoint
  in as admin. *File Browser users* asks for File Browser's own login; **Admin
  Password** is set when the database is created and updated on later starts (empty:
  keep the current one; the first start prints a generated one in the run log).
- **File Browser Image**: default `filebrowser/filebrowser:v2.50.0`.

## Requirements

Docker with the Compose plugin on the service node (directly or through `sudo`), and
internet access there on the first launch.
