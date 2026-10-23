# Omniverse: render or simulate a scene

Isaac Sim, headless in a container on a GPU node, runs one of four examples (or a
script of yours) on a USD scene and serves the result as a page through a `pw`
endpoint. `yamls/general-render.yaml`; `hsp-render` and `noaa-render` for those
platforms.

```
form ──► preprocessing ──► start script ──► run.py in the container ──► page ──► https://<endpoint>/
         (checks, the SIF,  (GPU, image,     Isaac Sim: PhysX or Newton,    serve.py      the run completes; the page
          the source copied  cache)           RTX; frames, or poses + USD     over the      stays up until you delete
          from the bucket)                    snapshots; render.json          outputs       the endpoint
                                                     │
                                                     └──► a copy to the destination (bucket or path)
```

![Frames of the pyramid example](thumbnails/omniverse.png)

## The examples

| Example | What runs | Needs the files section | Outputs |
|---|---|---|---|
| **Pyramid of blocks** (default) | thirty colored cubes and a steel ball thrown at them | no | frames |
| **Fracture** | a 2.4 m wall prefractured into 24 chunks with the Blast SDK, held by breakable bonds, hit by a 190 kg steel ball; or a mesh of yours, fractured by the run (see below) | only for your mesh | frames, the broken bonds |
| **Render your scene** | your USD file, framed from its objects' bounds, lit if it has no light, its timeline played | yes (the scene) | frames |
| **Simulate only** | a scene (yours, or the wall) stepped with no camera: every body's pose per frame and the stage as USD at intervals | optional (the scene) | `poses.csv`, `snapshots/*.usda` |

Each example is a directory under `app/examples/<name>/` with a `run.py` and, for the
bundled scenes, its `scene.usda`. The scripts share `app/kitrun.py` and take the same
arguments, so a `run.py` beside your scene replaces the example's one for one.

**Physics engine**: PhysX (Omniverse's default) or Newton (experimental in Isaac Sim
6.2; wants mass and collision geometry on every body). Both read the same USD Physics
schema; the pyramid runs under both.

## Form

| Field | Default | Notes |
|---|---|---|
| GPU host; submit to the scheduler, cores, GPUs, directives | login node, 8 cores, 0 GPUs | `--cpus-per-task` and `--gres=gpu:N` go ahead of your directives. A job gets one core by default and Kit stalls on it. Cloud clusters define no GRES, so 0 is right there; a cluster that schedules GPUs takes 1. The walltime ends the page |
| Example, physics engine | pyramid, PhysX | above |
| Frames, resolution, renderer | 90, 1280 × 720, RTX Real-Time | 30 frames a second of simulated time; about a second a frame on an L4 once the shaders are cached. Hidden for "simulate only": snapshot interval instead (30) |
| Fracture: your mesh, chunks, seed, bond strength | off, 24, 7, 150 kPa | shown for the fracture example |
| Files in and out | hidden | shown when the example needs files: a switch to use a bucket, the bucket, a source path and a destination path (in the bucket, or absolute on the cluster) |
| Software | Singularity, `${HOME}/pw/software` | the runtime, its image or SIF, the install directory |

## Files in and out

- **Source**: a USD file (`.usd`, `.usda`, `.usdc`, `.usdz`), or a directory holding
  `scene.usd*` (or one USD file), whatever it references by relative path, and
  optionally a `run.py`. For fracturing: an OBJ file, or a directory holding one. A
  bucket directory is copied as a whole into the job directory; a cluster path is read
  in place.
- **Destination**: the outputs are copied to `<destination>/<run slug>/` when the run
  ends. Empty leaves them in the job directory. The page serves the local copy either
  way.

The run's own key signs the bucket transfers; nothing is configured on the cluster.

## Fracture

`omni.blast`, the Kit extension for Blast, is neither in the image nor in Kit 110's
registry, so the chunks are authored with the Blast SDK itself (BSD-3, `blast/` of the
[PhysX repository](https://github.com/NVIDIA-Omniverse/PhysX)) and PhysX breaks them at
run time:

1. `app/fracture/blast-fracture.cpp` cuts a mesh into Voronoi chunks with the SDK's
   authoring library and writes them as an OBJ with the cut faces marked.
2. `app/fracture/make-scene.py` turns the chunks into USD: each chunk a rigid body with
   a convex-hull collider, a fixed joint at every shared cut face that breaks above the
   face's area times the bond strength, the bottom chunks mortared to the ground, and
   a steel ball thrown at it.
3. At the end the fracture script checks every joint's two anchors against where their
   bodies ended up; the ones that came apart are the broken bonds, counted into
   `render.json` with their paths.

**Your own mesh**: tick *Fracture a mesh of yours* and give an OBJ (meters, base at
z = 0) as the source. The first run builds the SDK, the tool and a `usd-core` venv on
the login node under `<install directory>/omniverse/blast` (`app/install-blast.sh`:
git, gcc, cmake and internet; about five minutes), and every run fractures the mesh
into `fracture/scene.usda` in the job directory before rendering it.

## How it works

1. **preprocessing** (login node): the checks, the SIF pull, the source copy
   (`app/fetch-source.sh`), the fracture of your mesh when asked, and the start
   script's assembly (`app/create-start-script.sh`) with the scheduler directives.
2. **session_runner**: the [`script_submitter`](../script_submitter/) runs the start
   script on the login node or as a SLURM/PBS job: the GPU check, the runtime
   (`omniverse-<runtime>/runtime.sh`), the example's `run.py` in the container, the
   output check, the copy to the destination, then `app/serve.py` under
   `pw endpoints run`.
3. **wait_for_endpoint** probes `render.json` through the platform; the run completes
   and the page is left serving until `pw endpoints delete omniverse-<run slug>`.

A failure before the page (no GPU, no space, a scene that does not open) fails the
run with the output in the run log; cancelling removes the container.

## Outputs and debugging

```
render/frames/rgb_NNNN.png   the frames (a render)
render/poses.csv             frame, time, body, x, y, z, qw, qx, qy, qz (simulate only)
render/snapshots/*.usda      the stage with the bodies where they were (simulate only)
render/render.json           what ran, and the outputs (the page's data)
render/scene.usda            the bundled scene, when one ran
fracture/scene.usda          your fractured mesh, when asked
run.<JOBID>.out              the script's output: the GPU, the pull, Isaac Sim's log, the server
```

```bash
pw workflows runs logs <slug>            # the whole run
pw workflows runs errors <slug>          # just the failures
pw endpoints list                        # the page's URL
pw endpoints delete omniverse-<slug>     # stop the page
```

```bash
pw workflows run "$PWD/workflows/omniverse/yamls/general-render.yaml" -i '{
  "resource": "pw://<user>/<gpu-cluster>", "cluster": {"scheduler": false},
  "service": {"example": "fracture", "engine": "physx", "frames": 60}}'
```
