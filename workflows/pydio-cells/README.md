# Pydio Cells

[Pydio Cells](https://pydio.com/en/cells-overview) file sharing and collaboration
platform (web file browser, workspaces, share links, WebDAV, previews, search) with a
MySQL database, in Docker on a compute cluster, served through a `pw` endpoint named
`pydio-cells-<run-slug>`. The run completes once the endpoint answers; the containers run
until `pw endpoints delete pydio-cells-<run-slug>`. Sign in as `admin` with the form's
**Admin Password**.

## How it works

- `app/controller.sh` checks the form's directories on the login node.
- `app/start-template.sh` runs on the login node or in a SLURM/PBS job: pulls the images
  and runs MySQL and Cells with Docker Compose behind `pw endpoints run`. Both containers
  run as your user, so every file they write belongs to you. On the first start of a Run
  Directory it installs Cells (admin account, random database password in
  `.mysql.env`) and creates the **Data Directory** workspace over the Data Directory.

## Form options

- **Data Directory** (default `${HOME}/pydio-cells/files`): the files of the *Data
  Directory* workspace, readable and writable by every Cells user. Cells indexes it and
  keeps a hidden `.pydio` file in each folder; a change made on the host while Cells runs
  appears after a restart or a re-sync of the `userfiles` datasource (Cells Console →
  Storage → Datasources). It may be `${HOME}`, but must not contain the Run Directory.
- **Run Directory** (default `${HOME}/pydio-cells`): `mysql_data/`, `cells_data/`
  (configuration, Common/Personal Files, versions, thumbnails). Reuse it to keep users,
  shares and settings; delete it to start over.
- **Admin Password** (default `changeme`): set when the Run Directory is installed; later
  runs keep the current one, which you change in Cells.
- **Pydio Cells Image** (default `pydio/cells:5.1.0`), **MySQL Image** (default
  `mysql:8.4`).

## Requirements

Docker with the Compose plugin on the service node (directly or through `sudo`), and
internet access there on the first launch. Cells serves at the root of its address, so
the endpoint must be a subdomain one (the default). Run Directories from the
`activate-pydio-cells` workflow belong to root; `sudo chown -R` them to reuse them.
