# NVIDIA Omniverse: Isaac Sim in a container

> Learned building `workflows/omniverse` (2026-10-22 and 2026-10-23, `awsgpu`: L4, driver
> 610.43.02, Docker 29 with the containerd image store, singularity-ce 4.4.2 in `--userns`
> mode). The workflow's README covers the design and the ecosystem; this file lists the
> facts and traps.

## Which image

- Every Omniverse application image under `nvcr.io/nvidia/omniverse/` (`kit`,
  `usd-composer`, `usd-viewer`, `kit-app-template`, `isaac-lab`) answers 401 to an
  anonymous pull: they need an NGC account. `nvcr.io/nvidia/isaac-sim` is public (tags
  `4.5.0`, `5.0.0`, `5.1.0`, `6.0.0` to `6.2.0.1` in 2026-10), and Isaac Sim is an
  Omniverse Kit application with the RTX renderer, PhysX and Replicator, so it is the one
  to showcase Omniverse without credentials. `6.2.0.1`: 10.7 GB compressed, 20 GB
  unpacked, 19 layers, multi-arch (amd64 and arm64 manifests).
- The container needs `ACCEPT_EULA=Y` (its `license.sh` refuses to start otherwise) and
  `PRIVACY_CONSENT` only to opt in to telemetry.

## Running it

- **The image's entrypoint is `runheadless.sh`, the WebRTC streaming server.** A
  `docker run <image> /isaac-sim/python.sh script.py` appends the command to that
  server's arguments: the "Isaac Sim Full Streaming App" loads, idles for ever, and the
  script never runs, with nothing in stdout. Always `--entrypoint /isaac-sim/python.sh`
  (the docs' `--entrypoint bash`). Singularity has no entrypoint problem:
  `singularity exec <sif> /isaac-sim/python.sh script.py`.
- The image user is `isaac-sim` (1234:1234) and `/isaac-sim` is mode 750, so another
  uid cannot even read it. Docker: run as the workflow user with `--group-add 1234`
  (group read access, the frames come out as the user's). Singularity: a `%post` with
  `chmod -R a+rX /isaac-sim` in the def file (`workflows/omniverse/isaac-sim.def`;
  `--fakeroot` build works on awsgpu with the subuid range in place).
- Isaac Sim writes two places: `$HOME` (`.cache/ov` shader caches, `.nv`,
  `.nvidia-omniverse/logs`, `.local/share/ov`) and `/isaac-sim/kit/cache` (the shader
  database, `Failed to initialize rtx::shaderdb::ContextManager` when it cannot).
  Bind both from a directory in the install directory (`-e HOME=/cache -v
  <dir>:/cache -v <dir>/kit:/isaac-sim/kit/cache`; Singularity `--home <dir>:/cache
  --bind <dir>/kit:/isaac-sim/kit/cache`). The first render on a node compiles the RTX
  shaders for about 150 s before its first frame; with the caches in place the first
  frame takes about 5 s and startup about 30 s (Docker) to 50 s (Singularity over FUSE).
- `--network none` works for the built-in scene: nothing is fetched.
- **The hardened cloud image keeps `/var` on a 15 GB partition** (awsgpu 2026-10-23, a
  fresh instance; the day before it had room): Docker's `data-root` and containerd's
  `root` both live there, so the workflow's free-space check refuses the 35 GB pull.
  With both stores empty, `root = "/home/containerd"` in `/etc/containerd/config.toml`
  (the commented default line), `"data-root": "/home/docker"` merged into
  `/etc/docker/daemon.json` (keep the `nvidia` runtime entry) and `systemctl restart
  containerd docker` moved them to the 160 GB `/home`; `docker info` then shows the new
  root and the check reads containerd's root from the config file.
- The NVIDIA NGX library (`libnvidia-ngx.so`) reaches neither container (the Docker
  toolkit's `all` capabilities and Singularity's `nvliblist.conf` both leave it out), so
  DLSS fails (`Failed to create NGX context`) and the real-time renderers come out
  speckled. `carb.settings.get_settings().set("/rtx/post/aa/op", 1)` (TAA) plus
  `rep.orchestrator.step(rt_subframes=32)` converges the lighting: clean frames at about
  0.5 to 1 s each at 1280x720 on an L4. Path tracing (64 spp, the OptiX denoiser, which
  is bound) is clean at 1 pass, about 2 s a frame.
- FIPS hosts: pass `OPENSSL_FORCE_FIPS_MODE=0` as for PhysicsNeMo
  (`software/physicsnemo.md`); the Kit Python did not need it for the render, but the
  variable is harmless.

## The 6.2 Python API

- `from isaacsim import SimulationApp`; `SimulationApp({"headless": True, "renderer":
  "RayTracedLighting" | "RealTimePathTracing" | "PathTracing", "width": W, "height":
  H})`. Every `omni.*` / `isaacsim.*` import comes after it.
- Scene: `isaacsim.core.experimental.objects` (`GroundPlane`, `Cube`, `Sphere`,
  `DistantLight`), `isaacsim.core.experimental.prims` (`RigidPrim`, `GeomPrim(...,
  apply_collision_apis=True)`), `isaacsim.core.experimental.materials.PreviewSurfaceMaterial`;
  `isaacsim.core.experimental.utils.app.play()`; `SimulationManager.set_physics_dt`.
  `RigidPrim.get_world_poses()` returns Warp arrays (`.numpy()` before indexing);
  `set_velocities(linear_velocities=[[x, y, z]])` after `play()`. **Create a `RigidPrim`
  view before `play()` when the scene authors `physics:velocity`** (verified 2026-10-23,
  awsgpu): wrapping the bodies once the simulation runs zeroes their velocities (the
  thrown ball of the fracture scene stopped after three physics steps and fell
  straight down); created before play, the authored throw survives. Writing poses back
  into USD during play (`with use_backend("usd"): set_world_poses(...)`, for a snapshot)
  does not disturb the simulation.
- Capture: `rep.functional.create.camera(position, look_at, look_at_up_axis, focal_length)`,
  `rep.create.render_product(cam, (W, H))`, `DiskBackend` + `BasicWriter(rgb=True)`
  (writes `rgb_NNNN.png` and a `metadata.txt`), `rep.orchestrator.step(rt_subframes,
  delta_time=1/fps, pause_timeline=False)` advances the timeline (and PhysX) by
  `delta_time` per capture, verified by logging `omni.timeline` time and a falling
  body's height. Moving a prim: `rep.functional.modify.pose(prim,
  position_value=..., look_at_value=..., look_at_up_axis=...)` (not `position=`).
- `isaacsim.core.experimental.utils.stage.create_new_stage()` /
  `omni.usd.get_context().open_stage(path)`; a user stage's bounds from
  `UsdGeom.BBoxCache(...).ComputeWorldBound(stage.GetPseudoRoot())`.

## Scheduled jobs

- **A SLURM job gets one core by default, and Kit stalls on it** (verified 2026-10-23,
  awsgpu, run pet-earwig): `task/affinity` pinned the render to core 0 (`Cpus_allowed_list:
  0`), `carb.tasking is likely stuck` repeated, Replicator logged `renderer failed to
  advance to the scheduled frame`, and the run sat at frame 1 for 17 minutes. Request
  cores ahead of the form's directives (`--cpus-per-task=8`, PBS `select=1:ncpus=8`;
  the workflow's `cluster.cpus` input), as the GPU request is composed.

## Physics engines (Isaac Sim 6.2)

- The image ships `isaacsim.physics.newton` (Newton 1.6.1, MuJoCo Warp) beside PhysX
  (`omni.physx` 110.4.4), but the python experience (`isaacsim.exp.base.python.kit`)
  does not enable it, so a standalone script gets PhysX. For Newton pass
  `extra_args=["--/exts/isaacsim.core.simulation_manager/default_engine=newton",
  "--enable", "isaacsim.physics.newton", "--enable", "isaacsim.physics.newton.tensors"]`
  to `SimulationApp` (the nut-and-bolt standalone example does), then
  `SimulationManager.get_active_physics_engine()` reports it;
  `SimulationManager.switch_physics_engine("newton")` switches before play. The GUI's
  `isaac-sim.newton.sh` is the same with PhysX disabled.
- Newton rejects bodies without mass or collision geometry, reversed joints and
  non-unit `metersPerUnit`; it is experimental and tested by NVIDIA on a handful of
  robots. The image's `/isaac-sim/skills/` directory holds NVIDIA's own agent skills
  (physics-simulation, physx-to-newton-conversion, urdf-mjcf-to-usd-conversion, ...),
  worth reading before guessing an API.

## Blast (destruction)

- **`omni.blast` is not in Kit 110's extension registry** (verified 2026-10-23: a
  headless `SimulationApp`, `sync_registry()`, `fetch_extension_versions("omni.blast")`
  returned no package in `kit/prod/default` nor `kit/prod/sdk`, and enabling it failed
  with "No versions of omni.blast"), nor in the image. Its documentation stopped at
  Kit 104 (2022). Destruction at run time therefore has no Kit extension here.
- **The Blast SDK builds from source on a cloud login node** (Rocky 9, gcc 11.5,
  cmake 3.31; `NVIDIA-Omniverse/PhysX`, `blast/`, BSD-3): `./setup.sh` pulls its
  dependencies through packman from NVIDIA's CDN with no account; `./build.sh
  --no-docker -r -t <target>` for `NvBlastGlobals`, `NvBlast`, `NvBlastTk`,
  `NvBlastExtAuthoring` (the default build relaunches in a docker container, and the
  test programs do not compile). gcc 11 needs `vla` dropped from `enablewarnings` and
  `class-memaccess`, `maybe-uninitialized` added to `disablewarnings` in
  `premake5.lua`, plus `<cstdio>` and `<limits>` includes in two sources. The SDK is
  built with the pre-C++11 ABI (`-D_GLIBCXX_USE_CXX11_ABI=0` for anything linking it).
  `workflows/omniverse/fracture/` prefractures a mesh with its authoring library
  (Voronoi sites, `FractureTool`, `getBaseMesh` returns world-space triangles with
  the cut faces marked by the interior material id) and `make-scene.py` turns the
  chunks into rigid bodies joined by `PhysicsFixedJoint`s with `physics:breakForce`,
  so PhysX breaks them at run time without Blast's runtime.

## Importers and converters

- `omni.kit.asset_converter` 6.1 (OBJ, STL, FBX, glTF) is in the image's extension
  cache, enabled with `isaacsim.core.experimental.utils.app.enable_extension`; the
  conversion is an async task (`create_converter_task(...).wait_until_finished()`,
  the `standalone_examples/api/omni.kit.asset_converter` example). URDF and MJCF come
  in through `isaacsim.asset.importer.urdf.URDFImporter(URDFImporterConfig(...)).import_urdf()`
  and the MJCF pair (`pip_prebundle` packages of those extensions; the config fields are
  documented in their `impl/config.py`). `scipy` is not in the image's Python; `numpy`,
  `PIL` and `yaml` are, through `python.sh` only (the bare `kit/python/bin/python3` has
  no site packages on its path). `pxr` is not importable without Kit: a standalone USD
  script on the login node takes `pip install usd-core` in a venv.

## The GUI in a VNC desktop

- **Isaac Sim's GUI runs inside the KasmVNC desktop from the same SIF** (verified
  2026-10-23 on awsgpu, driver 610.43.02): with the desktop's X socket directory and
  `.Xauthority` (the kasmvnc job's `container_tmp/`) bound at `/tmp/.X11-unix` and
  `/tmp/.Xauthority`, `DISPLAY=:N`, `--nv`, `/isaac-sim/isaac-sim.sh` created its window
  on the Xvnc display and rendered the viewport at about 27 fps (RTX Real-Time 2.0,
  886 MiB of the L4): Kit presents its Vulkan swapchain to the VNC X server without
  VirtualGL (Vulkan is not GLX). NVIDIA's container page says the GUI does not work over
  VNC; with this driver it does. Startup takes about 170 s from the SIF. `xwininfo
  -root -tree` and `xdpyinfo` on the login node reach the display through a symlink
  `/tmp/.X11-unix/X<N>` to the job's socket; a screenshot without `xwd` comes from
  libX11 through ctypes in the container's Python (PIL is there).
