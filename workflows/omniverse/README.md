# Omniverse

Renders a short physics animation on a GPU with [NVIDIA Omniverse](https://www.nvidia.com/en-us/omniverse/)
and serves the frames as a flipbook page through a `pw` endpoint. The application is
[Isaac Sim](https://docs.isaacsim.omniverse.nvidia.com/), the Omniverse Kit app NVIDIA
publishes on NGC without an account; it runs headless in a container, so the workflow
needs a GPU and a container runtime, nothing else.

```
form ──► preprocessing ──► start script ──► render.py in the container ──► gallery page ──► https://<endpoint>/
         (checkout,         (GPU, image,     Isaac Sim: PhysX + RTX,        serve.py over       the run completes; the page
          checks)            cache)           PNG frames + render.json       the frames          stays up until you delete the endpoint
```

The built-in scene stacks thirty colored cubes in a pyramid and throws a steel ball
at them; the camera orbits while the PhysX simulation plays and the RTX renderer
writes every frame. Give it a USD file of your own instead and it does the same with that
stage. The endpoint is `omniverse-<run slug>`; the page plays the frames and shows
what rendered them (GPU, renderer, times). It keeps serving after the run until
`pw endpoints delete omniverse-<run slug>`.

![Frames of the built-in scene](thumbnails/omniverse.png)

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host | | The cluster; the login node renders unless the job is submitted to the scheduler |
| Submit to the scheduler, GPUs per job, directives | login node, 1 GPU | A SLURM/PBS job on a GPU node: `--gres=gpu:N` (PBS `select=1:ngpus=N`) goes ahead of your directives; the walltime ends the service |
| Accept the NVIDIA Isaac Sim license | off | Required. The container only starts with `ACCEPT_EULA=Y`; the [license](https://www.nvidia.com/en-us/agreements/enterprise-software/isaac-sim-additional-software-and-materials-license/) is NVIDIA's |
| Frames | 90 | Frames of simulated time at 30 per second (three seconds); about a second each on an L4 once the shaders are cached |
| Resolution | 1280 × 720 | 640 × 360 and 1920 × 1080 too |
| Renderer | RTX Real-Time | `RayTracedLighting` (32 passes a frame, about 0.8 s on an L4 at 1280 × 720) and `RealTimePathTracing` are the fast ones; `PathTracing` (64 samples, denoised) takes about 2 s a frame |
| USD scene | empty | Absolute path of a `.usd`/`.usda`/`.usdc` on the cluster; empty renders the built-in scene |
| Container runtime | Docker | Where the image lives and how it runs, below |
| Container image | `nvcr.io/nvidia/isaac-sim:6.2.0.1` | Docker. Pulled once per node (11 GB down, 20 GB unpacked) into Docker's own storage, which needs about 35 GB free |
| Install directory | `${HOME}/pw/software` | `omniverse/cache` under it is Isaac Sim's home: its shader caches and logs, shared by every run on the node |

## How it works

1. **preprocessing**, on the login node, checks the form (the license box, the
   numbers, that the scene file exists), creates the cache directory, and assembles
   the start script from `inputs.sh` and `app/start-template.sh`.
2. **session_runner** hands the start script to the shared
   [`script_submitter`](../script_submitter/), which runs it on the login node or
   submits it as a SLURM/PBS job. The script checks the GPU (`nvidia-smi -L`), pulls
   the image if the node does not have it, runs `app/render.py` in the container, and
   once `render/render.json` and the frames exist starts `app/serve.py` under
   `pw endpoints run`. A failure before that point (no GPU, no space for the image, a
   render error) fails the run, with the output in the run log.
3. **wait_for_endpoint** polls `pw endpoints list` for `omniverse-<run slug>` and
   probes `render.json` through the platform until it answers; then the run completes
   and the service is left running.

Cancelling the run while it renders removes the container (`cancel.sh`); deleting
the endpoint stops the page.

### The render script

`app/render.py` is an ordinary Isaac Sim standalone script: it starts
`SimulationApp` headless with the renderer and resolution from the form, builds the
scene with the `isaacsim.core.experimental` objects (ground plane, lights, cubes and
a sphere with rigid-body and collision APIs, the sphere given a velocity once the
simulation plays), creates a Replicator camera and render product, and for every
frame moves the camera along its orbit and calls `rep.orchestrator.step()` with the
timeline playing, so PhysX advances a thirtieth of a second, the renderer accumulates
its passes and the `BasicWriter` saves `frames/rgb_NNNN.png`. At the end it writes
`render.json`: the frame list and what rendered them, which the page reads.

The real-time renderers use temporal anti-aliasing over 32 passes a frame rather
than DLSS: the NGX library DLSS needs is not part of what the container runtimes hand
a container, and without it the frames come out speckled.

With a USD scene, `open_scene` opens the stage instead of building one, frames the
camera orbit from the stage's bounds, adds a dome light when the stage has none and
plays its timeline, so physics or animation in the file run during the frames.

### The page

`app/web/` is a static page in the platform's look (the theme tokens and fonts
vendored with `tools/ui/sync-theme.sh`): the current frame, play/pause, a slider,
the arrow keys to step, and a table of what rendered the frames. `app/serve.py`
serves it with the standard library from the node's own `python3`, under a
subdomain or a path-based endpoint alike.

## Customizing it

- **Your own scene**: put a USD file where the render node sees it and give its
  path in *USD scene*. Isaac Sim's own sample assets are not in the image; a stage
  that references files by relative path keeps working as long as they sit beside it.
- **Another animation or output**: edit `app/render.py`. `build_scene` is the scene,
  `orbit` the camera path, the writer's `rgb=True` the output: Replicator's
  `BasicWriter` also writes depth, normals, segmentation and bounding boxes, with one
  flag each.
- **More or longer frames**: *Frames* and the `--fps` default in `render.py`.
  Rendering is about 0.8 s per frame at 1280 × 720 with RTX Real-Time on an L4
  (fewer passes in `SUBFRAMES` make it faster and noisier); path tracing is about 2 s.
- **Another Omniverse application**: the Omniverse Kit SDK and USD Composer images
  on NGC (`nvcr.io/nvidia/omniverse/kit`, `.../usd-composer`) need an NGC account.
  After `docker login nvcr.io` on the render node, point *Container image* at one of
  them and replace `render.py` with a script for that app's Python (`kit/python.sh`
  instead of Isaac Sim's `python.sh`, the same `omni.replicator.core` API).
- **A streamed, interactive Omniverse session** is not what this workflow does: Kit's
  WebRTC streaming needs UDP ports the platform's HTTPS endpoint does not carry.

## Output and debugging

In the run's job directory on the render node (`~/pw/jobs/<run-slug>/` for CLI
runs, `~/pw/jobs/<workflow-name>/<run-number>/` for registered ones):

```
render/frames/rgb_NNNN.png   the frames
render/render.json           what rendered them (the page's data)
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
  "service": {"accept_eula": true, "frames": 60},
  "software": {"runtime": "docker"}}'
```

## Variants

`yamls/general.yaml` only: the cloud clusters and any SLURM/PBS cluster with Docker.
