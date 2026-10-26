# Omniverse

[NVIDIA Omniverse](https://www.nvidia.com/en-us/omniverse/) on a GPU node of a cluster,
through the one Omniverse application anyone can pull without an NVIDIA account: Isaac
Sim, in a container, headless or in a browser desktop. Three workflows:

| Workflow | What it does | README |
|---|---|---|
| **Render** | Renders or simulates a USD scene: the bundled examples (a pyramid of blocks, a wall prefractured with the Blast SDK), yours, or a mesh of yours fractured by the run, with PhysX or Newton; serves the frames or the poses as a page | [README-render.md](README-render.md) |
| **Build** | Builds a USD scene from a manifest: meshes converted, URDF and MJCF robots imported, physics applied; a batch job | [README-build.md](README-build.md) |
| **Desktop** | Isaac Sim's own window in a KasmVNC browser desktop, from the same image | [README-desktop.md](README-desktop.md) |

Running any of them accepts NVIDIA's
[Isaac Sim license](https://www.nvidia.com/en-us/agreements/enterprise-software/isaac-sim-additional-software-and-materials-license/).

## What Omniverse is

![The Omniverse ecosystem and where this workflow sits](thumbnails/omniverse-ecosystem.svg)

- **OpenUSD** is the file format and the in-memory model everything reads and writes:
  meshes, materials, lights, cameras, animation and physics properties. Every example
  here is a `.usda` file you can open in a text editor.
- **Kit** is NVIDIA's SDK for building applications on OpenUSD; an application is a
  `.kit` file naming the extensions it loads. **RTX** is its renderer, **PhysX** its
  default physics engine (open source), **Newton** the new open engine (NVIDIA, Disney
  Research, Google DeepMind; experimental in Isaac Sim 6), **Replicator** its capture
  layer. **Blast** is NVIDIA's destruction SDK; its Kit extension stopped at Kit 104,
  so this workflow uses the SDK itself, at authoring time.
- **Applications built on Kit**: Isaac Sim (robotics, open source), the Kit App Template
  builds (USD Composer, USD Explorer, USD Viewer) and Audio2Face. NVIDIA files the old
  prebuilt Composer and Explorer under "legacy"; you build them from the template now.
- **Why Isaac Sim here**: it is the one Kit application published as a container that
  pulls anonymously; every image under `nvcr.io/nvidia/omniverse/` needs an NGC login.
  It carries the shared stack (RTX, PhysX, Newton, Replicator, the asset converter,
  the robot importers); the robotics parts go unused.
- **Nucleus**, Omniverse's collaboration server, is in transition: the Launcher and
  Nucleus Workstation were retired on 2025-10-01; the Enterprise server remains, and
  NVIDIA points new deployments at its Storage API or plain S3. USD files on buckets,
  which these workflows read and write, is the direction.
- **Licensing**: as of May 2026 Omniverse is free for development and production, no
  NVIDIA AI Enterprise subscription needed; software built with it may be
  redistributed on the same terms; support without a subscription is community only.

## Two ways to run the container

| Runtime | What runs | Needs |
|---|---|---|
| **Singularity** (default) | `ghcr.io/parallelworks/isaac-sim:6.2.0.1`, the Isaac Sim image as a SIF, pulled once by the login node into the install directory and run by any node as your user | `singularity`/`apptainer`, 11 GB in the install directory |
| **Docker** | `nvcr.io/nvidia/isaac-sim:6.2.0.1`, pulled on the node that runs the job | Docker, about 35 GB free in its image store (on a hardened cloud image `/var` is 15 GB: move the stores to `/home`) |

Both keep Isaac Sim's shader caches under `<install directory>/omniverse/cache`, so
the first run on a node compiles them (a few minutes) and later runs start fast. The
SIF is built with `build-container.sh` from `isaac-sim.def`; a new Isaac Sim version
means a new tag there and in the forms' hidden `sif_registry` default.
