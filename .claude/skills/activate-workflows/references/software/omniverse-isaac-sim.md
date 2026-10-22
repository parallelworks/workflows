# NVIDIA Omniverse: Isaac Sim in a container

> Learned building `workflows/omniverse` (2026-10-22, `awsgpu`: L4, driver 610.43.02,
> Docker 29 with the containerd image store, singularity-ce 4.4.2 in `--userns` mode).
> The workflow's README covers the design; this file lists the facts and traps.

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
  `set_velocities(linear_velocities=[[x, y, z]])` after `play()`.
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
