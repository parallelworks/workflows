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
```

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host; submit to the scheduler, cores, GPUs, directives | login node, 8 cores, 0 GPUs | as the render workflow; the walltime ends the desktop |
| Application | Isaac Sim (PhysX) | or with Newton physics |
| Software | `${HOME}/pw/software` | a SIF of your own, the install directory |

The desktop outlives the run until `pw endpoints delete kasmvnc-<run slug>`. The first
start on a node compiles the shaders (a few minutes); the caches are shared with the
render workflow's runs.

## The platform's own desktop sessions

The launcher is meant to work from a [platform desktop
session](https://parallelworks.com/docs/run/sessions/desktops) too, and it does not
yet: those sessions run an X server without the GLX extension, on which NVIDIA's driver
crashes while Isaac Sim opens its window. The plain-language account and the evidence
are in [desktop-issue.txt](desktop-issue.txt); the fix is on the platform's side (an
Xvnc with GLX, as KasmVNC's has).
