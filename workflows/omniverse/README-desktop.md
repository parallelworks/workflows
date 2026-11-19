# Omniverse: Isaac Sim's window in a browser desktop

Isaac Sim's own GUI (the stage, the viewport, the physics, every extension) inside a
KasmVNC browser desktop on a GPU node, from the same Singularity image the other
workflows run.

```
form ──► preprocessing ──► kasmvnc workflow (a subworkflow) ──► https://<endpoint>/
         (checks, the SIF,  the desktop on the login node or a      the run completes when the
          the launcher       SLURM/PBS node, Isaac Sim started       desktop answers; Isaac Sim's
          installed)         as its startup application             window follows a few minutes later
```

The workflow composes the [kasmvnc](../kasmvnc/) workflow and hands it
`app/isaac-sim-gui.sh` as the desktop's startup application; that launcher is what the
Singularity controller installs beside the SIF, so it is the same script a user can
run from any desktop's terminal:

```bash
~/pw/software/omniverse/isaac-sim-gui.sh            # PhysX
~/pw/software/omniverse/isaac-sim-gui.sh newton     # Newton physics
~/pw/software/omniverse/isaac-sim-gui.sh physx ~/pw/omniverse/stages/study   # and follow a stage
```

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host; submit to the scheduler, cores, GPUs, directives | login node, 8 cores, 0 GPUs | as the render workflow; the walltime ends the desktop |
| Application | Isaac Sim (PhysX) | or with Newton physics |
| Stage to follow | none | a stage directory or a `.usd`, `.usda` or `.usdc` file; see below |
| Software | `${HOME}/pw/software` | a SIF of your own, the install directory |

The desktop outlives the run until `pw endpoints delete kasmvnc-<run slug>`. The first
start on a node compiles the shaders (a few minutes); the caches are shared with the
render workflow's runs.

On a host whose glibc is newer than the desktop image's (Ubuntu 24.04, for one), the
NVIDIA GL libraries the runtime injects into the image cannot load, and the kasmvnc
workflow starts the desktop without them. Isaac Sim is unaffected: it runs on the host
in its own container with the GPU, and draws its window through the desktop's X server.

## Following a stage

Given **Stage to follow**, Isaac Sim opens that stage (`study.usda` when the field is a
directory) once the file exists, frames it, and checks every 3 seconds for layers that
changed on disk. A changed study or design file is reloaded, and the view is framed
again when designs were added. The [usd-export](../usd-export/README.md) workflow
writes such a stage from simulation results, so a desktop started on the same stage
directory shows each design as the export adds it, while the study is still running.

The stage the app shows is an in-memory layer with the study file as its sublayer.
Changes made in the app, such as a field picked in the Property panel, go to that
layer, so they survive the study's reloads and the study file is never written. Save
them with File > Save As. Opening another stage from the File menu ends the following.
The script is `app/stage-follow.py`, which `isaac-sim-gui.sh` hands to Kit's exec option.

## The platform's own desktop sessions

The launcher is meant to work from a [platform desktop
session](https://parallelworks.com/docs/run/sessions/desktops) too, and it does not
yet: those sessions run an X server without the GLX extension, on which NVIDIA's driver
crashes while Isaac Sim opens its window. The fix is on the platform's side (an Xvnc
with GLX, as KasmVNC's has); the request and its evidence are in
[desktop-issue.txt](desktop-issue.txt).
