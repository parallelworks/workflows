# VS Code

Runs [code-server](https://github.com/coder/code-server) — VS Code in the
browser — on a cluster, exposed through a platform endpoint.

## Inputs

- **Service host** — the cluster that runs the IDE. With **Schedule Job?**
  enabled the service is submitted to a compute node via SLURM/PBS (with the
  usual directive inputs); otherwise it runs on the login/controller node.
- **Download URL** — the code-server release tarball to install.
- **Password** — optional password for the IDE session; blank means no
  password.
- **Directory to open** — the folder the IDE opens, encoded in the endpoint
  URL.
- **Subdomain of the IDE URL** — the label in `https://<subdomain>.<sessions
  domain>/`; defaults to `vscode-<namespace>-<cluster>-<user>`. Keep it the same across
  runs (see below). Not offered on platforms without session subdomains (emed),
  where the IDE URL is path-based and already stable.

## Lifecycle

The workflow run completes once the endpoint registers; the service keeps
running on the resource. Find it with `pw endpoints list` (named
`openvscode-<run-slug>`) and tear it down with
`pw endpoints delete openvscode-<run-slug>`.

The code-server installation persists under `<parent_install_dir>` (default
`${HOME}/pw/software`), so subsequent runs skip the download.

## What persists between runs

Settings, keybindings and installed extensions live on the cluster under
`~/.local/share/code-server` and survive every run. Everything VS Code keeps on
the browser side — GitHub and Copilot sign-ins, which extensions are disabled,
trusted folders, UI layout — is stored by the browser per URL, so it only comes
back when the IDE is served at the same URL again. That is why the workflow pins
the endpoint subdomain instead of taking a random one: open the IDE from the same
browser and that state is still there.

Consequences:

- A second IDE on the same cluster needs a different **Subdomain**. If the URL is
  already served, the run fails naming the endpoint that holds it; delete that
  endpoint with `pw endpoints delete <name>` to take the URL back.
- Another browser, a cleared browser profile, or a changed subdomain starts from
  scratch: sign in again, re-disable extensions, re-trust folders.
