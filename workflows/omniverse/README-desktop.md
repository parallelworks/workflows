# Omniverse: Isaac Sim's window in a desktop session

Isaac Sim's own GUI (the stage, the viewport, the physics, every extension) in one of
the platform's [desktop sessions](https://parallelworks.com/docs/run/sessions/desktops),
the kind the Sessions page starts, on a GPU host's login node, from the same
Singularity image the other workflows run.

```
form ──► checks, the SIF, ──► pw sessions create ──► Isaac Sim on the ──► Sessions: omniverse-<run slug>
         the launcher          a desktop session      session's display    the run completes when Kit
         installed             on the login node                           reports its window ready
```

The steps run on the login node. The controller pulls the SIF once and installs
`app/isaac-sim-gui.sh` beside it; `app/desktop-session.sh` then starts the desktop
session `omniverse-<run slug>` with `pw sessions create`, starts the launcher on the
session's display, and waits for Kit to report `app ready`. The launcher is the same
script a user can run from any desktop session's terminal:

```bash
~/pw/software/omniverse/isaac-sim-gui.sh            # PhysX
~/pw/software/omniverse/isaac-sim-gui.sh newton     # Newton physics
~/pw/software/omniverse/isaac-sim-gui.sh physx ~/pw/omniverse/stages/study   # and follow a stage
```

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host | none | the session and Isaac Sim run on its login node, which needs an NVIDIA GPU and `singularity` or `apptainer` |
| Application | Isaac Sim (PhysX) | or with Newton physics |
| Stage to follow | none | a stage directory or a `.usd`, `.usda` or `.usdc` file; see below |
| Software | `${HOME}/pw/software` | a SIF of your own, the install directory |

## The session

The run's notice gives the session's URL, and the session is listed under Sessions.
Once the node's shader caches exist (the render workflow's runs share them), Isaac
Sim's window is ready about a minute after the session starts; the first start on a
node compiles the shaders, which takes a few minutes. The run fails when Isaac Sim
exits before then, or is not ready after 15 minutes, with the end of its output; all
of it is in `isaac-sim.log` in the run's directory.

The session outlives the run. Stop it from the Sessions page or with
`pw sessions stop omniverse-<run slug>`: Isaac Sim exits with the session's X server,
and nothing of the run is left. A run that fails, or is canceled before Isaac Sim is
ready, stops the session itself.

Isaac Sim renders on the GPU in its container and draws its window through the
session's X server, which needs the GLX extension. The launcher checks for it before
starting Kit, since NVIDIA's driver crashes without it; desktops started by an older
platform agent lack it. The session's display is the one VNC server that appears on the
node while `pw sessions create` runs, so when two desktops start there at the same
moment the run fails and asks to be run again.

## Other desktop sessions

The controller also adds an **Isaac Sim** entry (PhysX, an empty stage) to the
Applications menu of the desktop sessions, through
`~/.local/share/applications/pw-isaac-sim.desktop`. The workflow places its session on
the login node. A desktop session on a GPU compute node, which the platform schedules
with `pw sessions create --environment <partition>`, runs its X server on that node,
out of the run's reach; there, start Isaac Sim from the menu or the session's terminal,
which works on any node that shares the home directory.

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
