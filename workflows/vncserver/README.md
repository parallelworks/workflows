# Host Desktop (KasmVNC)

A browser-based desktop that runs **directly on the compute node** — no
container. It uses the node's own `kasmvncserver` and GNOME packages: Xvnc
renders the desktop, serves the bundled web client, and terminates the
websocket itself over HTTPS, so there is no reverse proxy, no noVNC download,
and nothing to install.

Use it when applications should run natively on the host with its modules,
filesystems, and hardware — the desktop *is* a host GNOME session. For a
containerized desktop that works on hosts without a VNC server, see
[workflows/kasmvnc](../kasmvnc/).

## How it works

```
Your Browser ── HTTPS/WebSocket ──▶ pw endpoint ──▶ Xvnc (KasmVNC, compute node)
                                                     └─ GNOME session (host)
```

1. Preprocessing checks out this directory and assembles the start script.
2. `script_submitter` submits it to the scheduler (or runs it on the login
   node, which lacks `kasmvncserver` on emed — keep the job scheduled).
3. The start script picks a free display, starts
   `vncserver -select-de gnome -interface 127.0.0.1` with derived ports, waits
   for the web client to answer (GNOME needs about a minute), and exposes it
   with `pw endpoints https`.
4. The run completes once the endpoint registers; the desktop keeps serving.

Teardown: `pw endpoints delete vncserver-<run-slug>` — the start script's
monitor loop notices the client die and runs `cancel.sh`, which kills the
Xvnc daemon and the GNOME session. Canceling a starting run works the same
way through `script_submitter`'s cleanup hook.

## Authentication

The endpoint requires platform login. The VNC layer's web basic auth is
disabled (`-disableBasicAuth`), matching the trust model of the other desktop
workflows; the password in the URL is vestigial. Xvnc listens on
`127.0.0.1` only, so the port is not reachable from other cluster nodes.

## Variants

| YAML | What it starts |
|---|---|
| `yamls/emed.yaml` | plain GNOME desktop |
| `yamls/emed_rstudio.yaml` | `module load rstudio; rstudio` |
| `yamls/emed_matlab.yaml` | `module load matlab; matlab -desktop` |
| `yamls/emed_firefox.yaml` | `firefox` (must exist on the node) |
| `yamls/emed_fsl.yaml` | `module load fsl/6.0.5_cpu; fsl` |
| `yamls/emed_schrodinger.yaml` | `module load schrodinger; maestro` |
| `yamls/emed_vmd.yaml` | `module load vmd; vmd` |

All target `cluster.einsteinmed.edu` (path-based endpoint, `--no-subdomain
--strip-path`). The app variants expose a visible "Command to load X" form
field plus a hidden binary; the app runs natively on the compute node against
the desktop's display, with stdin on a FIFO so console-driven GUIs (vmd)
survive backgrounding. A missing binary only logs an error; the desktop keeps
serving.

The legacy multi-platform generation of this workflow (TigerVNC/TurboVNC
detection, noVNC proxy, nginx, rootless docker) lives on in
`parallelworks/interactive_session`; this directory is a clean emed-only
rewrite on the endpoint pattern.
