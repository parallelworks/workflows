# File Browser

Starts [File Browser](https://filebrowser.org) ([filebrowser/filebrowser](https://github.com/filebrowser/filebrowser)),
a web file manager, on a compute cluster and serves it through a `pw` endpoint named
`filebrowser-<run-slug>`. The run completes once the endpoint answers; the container keeps
running until `pw endpoints delete filebrowser-<run-slug>`.

File Browser is a self-hosted web application for managing files and folders: browse,
upload (drag & drop, chunked), download, create, edit, rename, move, copy, delete,
preview and zip files from the browser. Users and permissions, shares, and the command
runner are managed from its settings page.

## How it works

1. `app/controller.sh` runs on the login node and creates the directories the service
   mounts.
2. `app/start-template.sh` runs on the login node or inside a scheduler job (SLURM/PBS,
   your choice in the form). It starts the Docker daemon if needed, pulls the image,
   bootstraps or updates the File Browser database with the authentication the form
   selects, and runs the container with Docker Compose behind `pw endpoints run`. The
   container runs as your user, so the files it creates belong to you.
3. `wait_for_endpoint` probes the endpoint until File Browser answers, then releases the
   run while the service lives on.

## Form options

- **Root Directory**: the directory File Browser serves (default
  `${HOME}/filebrowser/data`). Set it to `${HOME}` to browse your whole home directory.
- **Run Directory**: keeps File Browser's configuration and database (`config/`,
  `database/`; default `${HOME}/filebrowser`). Reuse it to keep the users, settings and
  shares of earlier sessions.
- **Authentication**:
  - *Platform login only* (default): the endpoint already requires the platform login,
    and whoever opens it is signed in as File Browser's admin user.
  - *File Browser users*: File Browser asks for its own username and password, so
    several users with their own permissions and home folders can share the instance.
    **Admin Password** sets the admin user's password when the database is created and
    updates it on later starts; left empty, the first start generates one and prints it
    in the run log, and later starts keep the current one.
- **File Browser Image**: the Docker image (default `filebrowser/filebrowser:v2.50.0`).

## Requirements

- Docker (with the Compose plugin) on the node that runs the service, usable directly
  or through `sudo`
- Outbound internet access from that node on the first launch, to pull the image
