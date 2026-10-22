# Omniverse

Renders a short physics animation on a GPU with [NVIDIA Omniverse](https://www.nvidia.com/en-us/omniverse/)
and serves the frames as a flipbook page through a `pw` endpoint.

Omniverse is NVIDIA's platform for 3D simulation: a framework (Kit), a scene format
(USD), a ray-tracing renderer (RTX) and a physics engine (PhysX). You never run
"Omniverse" by itself; you run an application built on it. This workflow runs
[Isaac Sim](https://docs.isaacsim.omniverse.nvidia.com/), NVIDIA's robotics simulator,
because it is the one Omniverse application NVIDIA lets anyone download, with no NGC
account. We use none of the robotics parts: only the renderer, the physics and the
scene tools that every Omniverse application shares. It runs headless in a container
(Docker or Singularity), so the workflow needs a GPU and a container runtime and
nothing else. Running it accepts NVIDIA's
[Isaac Sim license](https://www.nvidia.com/en-us/agreements/enterprise-software/isaac-sim-additional-software-and-materials-license/).

```
form ──► preprocessing ──► start script ──► render.py in the container ──► gallery page ──► https://<endpoint>/
         (checks, with     (GPU, image,     Isaac Sim: PhysX + RTX,        serve.py over       the run completes; the page
          Singularity       cache)           PNG frames + render.json       the frames          stays up until you delete the endpoint
          the SIF)
```

![Frames of the built-in scene](thumbnails/omniverse.png)

## The scene

The built-in scene is a pyramid of thirty colored cubes on a floor and a steel ball
thrown at them. The camera circles the pyramid while the physics plays, and every frame
is rendered to a PNG. The endpoint is `omniverse-<run slug>`; the page plays the frames
and lists what rendered them. It keeps serving after the run until
`pw endpoints delete omniverse-<run slug>`.

A 3D scene in Omniverse is a **USD file** (Universal Scene Description, Pixar's format):
a text or binary file that lists everything in the scene, as a tree. Each object has a
shape (a cube, a sphere, a mesh of triangles), a position, a size, a color or material,
and may carry lights, a camera, animation, and physics properties such as "this is a
rigid body", "this collides" or "this starts with this velocity". Anything an Omniverse
application does, it does to a USD scene.

Here, `app/render.py` builds the pyramid, the ball, the floor and the lights as a USD
scene in memory, and gives the ball its throw as a physics property of the scene. The
only things that are **not** in the scene are the camera's path, which the script
computes frame by frame, and the frame count, resolution and renderer from the form.
Every run of the built-in scene also writes it out as `render/scene.usda`, a readable
text file: open it to see what a USD scene looks like, change a color or a position,
and pass the edited file as the **USD scene** input to render it.

With a USD file of your own, the script opens it as it is, points the camera at its
objects (a floor or a table top is ignored when framing), adds a light when the file
has none, and plays its timeline, so any physics or animation in the file runs during
the frames.

## Two ways to run it

| Container runtime | What runs | Needs |
|---|---|---|
| **Docker** (default) | `nvcr.io/nvidia/isaac-sim:6.2.0.1`, pulled on the node that renders, as your user | Docker (directly or through `sudo`), about 35 GB free in Docker's own storage for the image (11 GB to download, 20 GB unpacked) |
| **Singularity** | The same image as a SIF, `ghcr.io/parallelworks/isaac-sim:6.2.0.1`, pulled once by the login node into the install directory and run by any node as your user | `singularity`/`apptainer`, 11 GB in the install directory |

Both keep Isaac Sim's home (its shader caches and logs) under
`<install directory>/omniverse/cache`, shared by every run on the node, so the shaders
compile once. Singularity is the one for clusters without Docker, or where Docker's
storage sits on a small partition; a kernel that cannot mount a SIF (hardened images
disable squashfs) still runs it in a user namespace, which the log says.

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host | | The cluster; the login node renders unless the job is submitted to the scheduler |
| Submit to the scheduler, GPUs per job, directives | login node, 1 GPU | A SLURM/PBS job on a GPU node: `--gres=gpu:N` (PBS `select=1:ngpus=N`) goes ahead of your directives; 0 requests none, for a cluster whose GPU nodes have no GRES configured; the walltime ends the service |
| Frames | 90 | Frames of simulated time at 30 per second (three seconds); about a second each on an L4 once the shaders are cached |
| Resolution | 1280 × 720 | 640 × 360 and 1920 × 1080 too |
| Renderer | RTX Real-Time | `RayTracedLighting` (32 passes a frame, about 0.8 s on an L4 at 1280 × 720) and `RealTimePathTracing` are the fast ones; `PathTracing` (64 samples, denoised) takes about 2 s a frame |
| USD scene | empty | Absolute path of a `.usd`/`.usda`/`.usdc` file on the cluster; empty renders the built-in scene |
| Container runtime | Docker | Docker or Singularity, above |
| Container image | `nvcr.io/nvidia/isaac-sim:6.2.0.1` | Docker. Pulled once per node into Docker's own storage |
| Singularity image file | empty | Singularity. A SIF of your own (built with `build-container.sh`); empty pulls `ghcr.io/parallelworks/isaac-sim:6.2.0.1` into the install directory once |
| Install directory | `${HOME}/pw/software` | `omniverse/cache` under it is Isaac Sim's home (shader caches, logs) and `omniverse/containers` holds the SIF, shared by every run on the node |

## How it works

1. **preprocessing**, on the login node, checks the form (the numbers, that the scene
   file exists), creates the cache directory, with Singularity pulls the SIF into the
   install directory once, and assembles the start script from `inputs.sh` and the
   runtime's `start-template.sh`.
2. **session_runner** hands the start script to the
   [`script_submitter`](../script_submitter/) subworkflow, which runs it on the login
   node or submits it as a SLURM/PBS job. The script checks the GPU (`nvidia-smi -L`),
   with Docker pulls the image if the node does not have it, runs `app/render.py` in
   the container, and once `render/render.json` and the frames exist starts
   `app/serve.py` under `pw endpoints run`. A failure before that point (no GPU, no
   space for the image, a render error) fails the run, with the output in the run log.
3. **wait_for_endpoint** calls the [`wait_for_endpoint`](../wait_for_endpoint/)
   subworkflow, which polls `pw endpoints list` for `omniverse-<run slug>` and probes
   `render.json` through the platform until it answers; then the run completes and
   the service is left running.

Cancelling the run while it renders removes the container (`cancel.sh`); deleting
the endpoint stops the page.

### The files

```
yamls/general.yaml                 the form and the jobs
app/render.py                      the scene, the camera and the capture, run inside the container
app/serve.py, app/web/             the page and the small server that serves it
app/check-inputs.sh                the form checks both runtimes share
omniverse-docker/                  controller.sh and start-template.sh for Docker
omniverse-singularity/             the same two for Singularity
isaac-sim.def, build-container.sh  how the Singularity image is built
```

`app/render.py` is an ordinary Isaac Sim standalone script. It starts `SimulationApp`
headless with the renderer and resolution from the form, builds the scene (or opens
yours), creates a Replicator camera and render product, and for every frame moves the
camera along its circle and calls `rep.orchestrator.step()` with the timeline playing:
PhysX advances a thirtieth of a second, the renderer accumulates its passes and the
`BasicWriter` saves `frames/rgb_NNNN.png`. At the end it writes `render.json`, the
frame list and what rendered them, which the page reads.

The real-time renderers use temporal anti-aliasing over 32 passes a frame rather than
DLSS: the NGX library DLSS needs is not part of what the container runtimes hand a
container, and without it the frames come out speckled.

`app/web/` is a static page in the platform's look (the theme tokens and fonts vendored
with `tools/ui/sync-theme.sh`): the current frame, play/pause, a slider, the arrow keys
to step, and a table of what rendered the frames. `app/serve.py` serves it with the
standard library from the node's own `python3`.

## Changing it

- **Your own scene.** Put a USD file where the render node sees it and give its path
  in *USD scene*. Start from the `render/scene.usda` a run writes if you want a
  template. A file that references other files by relative path keeps working as long
  as they sit beside it. Isaac Sim's own sample assets are not in the image.
- **Another animation, or other outputs.** Edit `app/render.py`: `build_scene` makes
  the scene, `orbit` is the camera path, and the writer's `rgb=True` is the output.
  Replicator's `BasicWriter` can also write depth, normals, segmentation masks and
  bounding boxes, one flag each; that is what Isaac Sim users generate training data
  with.
- **Longer or faster.** *Frames* on the form; `--fps` and `SUBFRAMES` in `render.py`
  (fewer passes render faster and noisier).
- **Another Omniverse application.** NVIDIA publishes other applications built on the
  same Kit framework: USD Composer, for building scenes by hand, and the bare Kit SDK,
  for writing an application of your own. Their container images
  (`nvcr.io/nvidia/omniverse/usd-composer`, `nvcr.io/nvidia/omniverse/kit`) need an
  NGC account to pull. If you have one, `docker login nvcr.io` on the render node,
  put the image in *Container image*, and replace `render.py` with a script written
  for that application; the scene and Replicator calls are the same, only the launcher
  differs. On the Singularity side, build a SIF from that image the way
  `build-container.sh` does.

### Why frames and not a live window

Omniverse applications can stream their window to a browser, like a video call: you
would see the scene live, drag the camera around, edit things. That stream is WebRTC,
and WebRTC sends its video over UDP on ports of its own. A `pw` endpoint carries web
traffic (HTTP, HTTPS and the WebSockets web apps use) to one port, and `pw forward`
tunnels TCP ports over SSH; neither carries UDP. So this workflow renders to files and
serves the result, which also makes it the shape of a batch render job you can adapt
to render anything.

## Output and debugging

In the run's job directory on the render node (`~/pw/jobs/<run-slug>/` for CLI
runs, `~/pw/jobs/<workflow-name>/<run-number>/` for registered ones):

```
render/frames/rgb_NNNN.png   the frames
render/render.json           what rendered them (the page's data)
render/scene.usda            the built-in scene as a USD file
run.<JOBID>.out              the start script's output: the GPU, the pull, Isaac Sim's log, the server
<install dir>/omniverse/cache/.nvidia-omniverse/logs/   Isaac Sim's own logs
```

```bash
pw workflows runs logs <slug>            # the whole run
pw workflows runs errors <slug>          # just the failures
pw endpoints list                        # the page's URL
pw endpoints delete omniverse-<slug>     # stop the page
```

The first render on a node compiles the RTX shaders: about two and a half minutes
before the first frame, on top of the 30 to 50 s Isaac Sim takes to start. The
caches go to the install directory, so a later run on that node renders its first
frame a few seconds after starting (90 frames at 1280 × 720 took 103 s in all on an
L4).

## Run from the CLI

```bash
pw workflows run "$PWD/workflows/omniverse/yamls/general.yaml" -i '{
  "resource": "pw://<user>/<gpu-cluster>", "cluster": {"scheduler": false},
  "service": {"frames": 60},
  "software": {"runtime": "omniverse-docker"}}'
```

## Building the Singularity image

```bash
cd workflows/omniverse
./build-container.sh        # the NGC image, its files opened for reading by any user
tools/oras/oras push ghcr.io/parallelworks/isaac-sim:6.2.0.1 isaac-sim-6.2.0.1.sif
```

New Isaac Sim version, new tag, and the tag in `omniverse-singularity/controller.sh`,
`omniverse-singularity/start-template.sh` and the form's defaults moves with it. Keep
the package public.

## Variants

`yamls/general.yaml` only: the cloud clusters and any SLURM/PBS cluster with Docker or
Singularity.
