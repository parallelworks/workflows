"""What every example shares: the app, the scene, the camera, the capture, the manifest.

    python.sh run.py --out DIR [--frames N] [--fps F] [--width W --height H]
                     [--renderer RayTracedLighting|RealTimePathTracing|PathTracing]
                     [--engine physx|newton] [--scene PATH.usd] [--snapshots N]

Every example script (and a run.py of yours) takes these arguments, so the start script
runs any of them the same way. A script calls start(), opens or builds a scene, and
either render() (frames for the gallery page) or simulate() (a physics-only run:
the bodies' poses and USD snapshots, no frames); both write DIR/render.json, which the
page reads. Runs inside the Isaac Sim container, an Omniverse Kit application.
"""
import argparse
import csv
import json
import math
import os
import socket
import subprocess
import sys
import time

USD_EXTENSIONS = (".usd", ".usda", ".usdc", ".usdz")
PHYSICS_HZ = 60
# Render passes accumulated per frame: the real-time modes converge their sampled
# lighting over passes (the DLSS denoiser needs the NGX library, which the container
# does not carry), path tracing already takes 64 samples per pass
SUBFRAMES = {"RayTracedLighting": 32, "RealTimePathTracing": 32, "PathTracing": 1}

_started = time.time()
_app = None


def parse_args(description, scene_default=""):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--out", required=True, help="output directory: render.json, frames/ or poses.csv and snapshots/")
    parser.add_argument("--frames", type=int, default=90, help="frames of simulated time")
    parser.add_argument("--fps", type=int, default=30, help="frames per second of simulated time")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--renderer", default="RayTracedLighting",
                        choices=["RayTracedLighting", "RealTimePathTracing", "PathTracing"])
    parser.add_argument("--subframes", type=int, default=0,
                        help="render passes accumulated per frame; 0 picks a default for the renderer")
    parser.add_argument("--engine", default="physx", choices=["physx", "newton"], help="the physics engine")
    parser.add_argument("--scene", default=scene_default, help="the USD stage to open")
    parser.add_argument("--snapshots", type=int, default=30,
                        help="physics-only runs: a USD snapshot of the scene every N frames; 0 writes only the last")
    parser.add_argument("--delivered-to", default="", help="where the outputs are copied afterwards, for render.json")
    parser.add_argument("--image", default="", help="the container image, recorded in render.json")
    parser.add_argument("--tag", default="", help="ignored; lets a cleanup script find this process")
    args, _ = parser.parse_known_args()
    return args


def beside(script, name):
    """A file next to the calling script (its bundled scene)."""
    return os.path.join(os.path.dirname(os.path.abspath(script)), name)


def start(args):
    """Kit starts here; every omni.* / isaacsim.* import must come after it."""
    global _app
    os.makedirs(args.out, exist_ok=True)
    from isaacsim import SimulationApp  # noqa: E402

    extra_args = []
    if args.engine == "newton":
        # Newton ships as an opt-in backend: its extensions are not in the python
        # experience, and the manager keeps PhysX unless told at launch
        extra_args = ["--/exts/isaacsim.core.simulation_manager/default_engine=newton",
                      "--enable", "isaacsim.physics.newton", "--enable", "isaacsim.physics.newton.tensors"]
    _app = SimulationApp({
        "headless": True,
        "renderer": args.renderer,
        "width": args.width,
        "height": args.height,
        "extra_args": extra_args,
    })
    from isaacsim.core.simulation_manager import SimulationManager  # noqa: E402
    active = SimulationManager.get_active_physics_engine()
    if args.engine == "newton" and str(active).lower() != "newton":
        if not SimulationManager.switch_physics_engine("newton"):
            fail("Newton is not available in this image; its extensions did not load")
        active = SimulationManager.get_active_physics_engine()
    print(f"Isaac Sim is up; the physics engine is {active}", flush=True)
    return _app


def fail(message):
    print(f"::error::{message}", flush=True)
    if _app is not None:
        _app.close()
    sys.exit(1)


def scene_bounds(stage):
    """The world bounds of the stage's shapes. A flat slab (a floor, a table top) is
    left out when anything else is there, so the camera frames the objects, not the
    ground they stand on."""
    from pxr import Gf, Usd, UsdGeom  # noqa: E402
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_, UsdGeom.Tokens.render])
    shapes, slabs = Gf.Range3d(), Gf.Range3d()
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Gprim):
            continue
        box = cache.ComputeWorldBound(prim).ComputeAlignedRange()
        if box.IsEmpty():
            continue
        thin, wide = sorted(box.GetSize())[0], sorted(box.GetSize())[1]
        (slabs if thin < wide / 20 else shapes).UnionWith(box)
    return shapes if not shapes.IsEmpty() else slabs


def open_scene(path):
    """Opens a USD stage, lights it if it has no light, and returns the point the
    camera looks at and the orbit radius, from the bounds of its objects."""
    import omni.replicator.core as rep  # noqa: E402
    import omni.usd  # noqa: E402
    from pxr import Gf, UsdLux  # noqa: E402
    if not path:
        fail("No scene: this example needs a USD file from the source input")
    if not os.path.exists(path):
        fail(f"The scene {path} does not exist")
    if not omni.usd.get_context().open_stage(path):
        fail(f"Could not open the USD stage {path}")
    stage = omni.usd.get_context().get_stage()
    if not any(prim.HasAPI(UsdLux.LightAPI) for prim in stage.Traverse()):
        rep.functional.create.dome_light(intensity=300, name="DomeLight")
    box = scene_bounds(stage)
    if box.IsEmpty():
        print("The stage has no bounds; orbiting the origin", flush=True)
        return Gf.Vec3d(0, 0, 0), 5.0
    radius = max((box.GetMax() - box.GetMin()).GetLength() / 2, 0.1)
    print(f"Stage bounds {tuple(round(v, 2) for v in box.GetMin())} to "
          f"{tuple(round(v, 2) for v in box.GetMax())}; the camera orbits {radius * 2.5:.1f} m from the center",
          flush=True)
    return box.GetMidpoint(), radius * 2.5


def orbit(center, radius, fraction, up_axis):
    """Camera position after `fraction` of a turn around `center`, 25 degrees above."""
    angle = 2 * math.pi * fraction + math.pi / 4
    x = radius * math.cos(angle) * math.cos(math.radians(25))
    y = radius * math.sin(angle) * math.cos(math.radians(25))
    z = radius * math.sin(math.radians(25))
    if up_axis == "Y":
        return (center[0] + x, center[1] + z, center[2] + y)
    return (center[0] + x, center[1] + y, center[2] + z)


def gpu_name():
    try:
        return subprocess.check_output(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                                       text=True, timeout=20).strip().splitlines()[0]
    except Exception:  # nvidia-smi missing from the container is not an error
        return "unknown"


def _play(args):
    import isaacsim.core.experimental.utils.app as app_utils  # noqa: E402
    from isaacsim.core.simulation_manager import SimulationManager  # noqa: E402
    SimulationManager.set_physics_dt(1.0 / PHYSICS_HZ)
    app_utils.play()
    _app.update()


def _stop():
    import isaacsim.core.experimental.utils.app as app_utils  # noqa: E402
    app_utils.stop()


def render(args, center, radius, scene, extras=None, on_frame=None):
    """Orbits a camera around `center` while the timeline plays and writes every frame
    as frames/rgb_NNNN.png, then render.json."""
    import carb.settings  # noqa: E402
    import omni.replicator.core as rep  # noqa: E402
    import omni.usd  # noqa: E402
    from pxr import UsdGeom  # noqa: E402

    frames_dir = os.path.join(args.out, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    for name in os.listdir(frames_dir):
        os.remove(os.path.join(frames_dir, name))
    stage = omni.usd.get_context().get_stage()
    up_axis = UsdGeom.GetStageUpAxis(stage)
    center = tuple(center)
    up = (0, 1, 0) if up_axis == "Y" else (0, 0, 1)
    camera = rep.functional.create.camera(position=orbit(center, radius, 0, up_axis), look_at=center,
                                          look_at_up_axis=up, focal_length=18.0, name="OrbitCamera")
    render_product = rep.create.render_product(camera, (args.width, args.height))
    backend = rep.backends.get("DiskBackend")
    backend.initialize(output_dir=frames_dir)
    writer = rep.writers.get("BasicWriter")
    writer.initialize(backend=backend, rgb=True)
    writer.attach(render_product)
    rep.orchestrator.set_capture_on_play(False)
    # Temporal anti-aliasing, accumulated over the subframes of every capture
    carb.settings.get_settings().set("/rtx/post/aa/op", 1)
    subframes = args.subframes or SUBFRAMES[args.renderer]

    print("Writer attached; playing the timeline", flush=True)
    _play(args)
    print(f"Rendering {args.frames} frames at {args.width}x{args.height} with {args.renderer}, "
          f"{subframes} passes per frame, on {gpu_name()}", flush=True)
    first_frame_seconds = None
    loop_started = time.time()
    for frame in range(args.frames):
        rep.functional.modify.pose(camera, position_value=orbit(center, radius, frame / args.frames, up_axis),
                                   look_at_value=center, look_at_up_axis=up)
        rep.orchestrator.step(rt_subframes=subframes, delta_time=1.0 / args.fps, pause_timeline=False)
        if on_frame:
            on_frame(frame)
        if frame == 0:
            first_frame_seconds = round(time.time() - loop_started, 1)
        if frame % 10 == 0 or frame == args.frames - 1:
            print(f"frame {frame + 1}/{args.frames} after {time.time() - loop_started:.1f} s", flush=True)
    rep.orchestrator.wait_until_complete()
    writer.detach()
    render_product.destroy()
    _stop()

    frames = sorted(name for name in os.listdir(frames_dir) if name.endswith(".png"))
    if len(frames) != args.frames:
        fail(f"Expected {args.frames} frames, found {len(frames)} in {frames_dir}")
    manifest = {
        "scene": scene,
        "frames": [f"frames/{name}" for name in frames],
        "frame_count": len(frames),
        "width": args.width,
        "height": args.height,
        "renderer": args.renderer,
        "seconds_per_frame": round((time.time() - loop_started - (first_frame_seconds or 0)) / max(args.frames - 1, 1), 2),
    }
    manifest.update(extras or {})
    write_manifest(args, manifest)
    print(f"Wrote {len(frames)} frames to {frames_dir}", flush=True)


def rigid_bodies(stage):
    from pxr import UsdPhysics  # noqa: E402
    return [str(prim.GetPath()) for prim in stage.Traverse() if prim.HasAPI(UsdPhysics.RigidBodyAPI)]


def simulate(args, scene, extras=None, on_frame=None):
    """Plays the timeline with no camera and no writer: every frame the poses of the
    rigid bodies go to poses.csv, every `--snapshots` frames (and at the end) the stage
    with the bodies where they are goes to snapshots/frame_NNNN.usda."""
    import isaacsim.core.experimental.utils.backend as backend_utils  # noqa: E402
    import omni.replicator.core as rep  # noqa: E402
    import omni.usd  # noqa: E402
    from isaacsim.core.experimental.prims import RigidPrim  # noqa: E402

    stage = omni.usd.get_context().get_stage()
    paths = rigid_bodies(stage)
    if not paths:
        fail("The scene has no rigid bodies (no prim with PhysicsRigidBodyAPI): nothing to simulate")
    snapshots_dir = os.path.join(args.out, "snapshots")
    os.makedirs(snapshots_dir, exist_ok=True)
    for name in os.listdir(snapshots_dir):
        os.remove(os.path.join(snapshots_dir, name))
    poses_path = os.path.join(args.out, "poses.csv")
    rep.orchestrator.set_capture_on_play(False)
    print(f"Simulating {len(paths)} rigid bodies for {args.frames} frames at {args.fps} per second", flush=True)
    # The view before play: wrapping the bodies once the simulation runs zeroes the
    # velocities the scene authored (a thrown ball stops dead)
    bodies = RigidPrim(paths=paths)
    _play(args)
    snapshots = []
    loop_started = time.time()

    def snapshot(frame):
        name = f"snapshots/frame_{frame + 1:04d}.usda"
        positions, orientations = bodies.get_world_poses()
        # The engine keeps the poses in its own buffers: write them into the stage's
        # USD transforms so the exported file shows the bodies where they are
        with backend_utils.use_backend("usd"):
            bodies.set_world_poses(positions, orientations)
        stage.Export(os.path.join(args.out, name))
        snapshots.append(name)

    with open(poses_path, "w", newline="") as handle:
        rows = csv.writer(handle)
        rows.writerow(["frame", "time", "body", "x", "y", "z", "qw", "qx", "qy", "qz"])
        for frame in range(args.frames):
            rep.orchestrator.step(rt_subframes=1, delta_time=1.0 / args.fps, pause_timeline=False)
            positions, orientations = bodies.get_world_poses()
            positions, orientations = positions.numpy(), orientations.numpy()
            t = round((frame + 1) / args.fps, 4)
            for path, p, q in zip(paths, positions, orientations):
                rows.writerow([frame + 1, t, path] + [round(float(v), 5) for v in (*p, *q)])
            if on_frame:
                on_frame(frame)
            if (args.snapshots and (frame + 1) % args.snapshots == 0) or frame == args.frames - 1:
                snapshot(frame)
            if frame % 10 == 0 or frame == args.frames - 1:
                print(f"frame {frame + 1}/{args.frames} after {time.time() - loop_started:.1f} s", flush=True)
    _stop()
    outputs = ["poses.csv"] + snapshots
    manifest = {
        "scene": scene,
        "frames": [],
        "frame_count": args.frames,
        "bodies": len(paths),
        "outputs": [{"path": name, "bytes": os.path.getsize(os.path.join(args.out, name))} for name in outputs],
        "seconds_per_frame": round((time.time() - loop_started) / max(args.frames, 1), 3),
    }
    manifest.update(extras or {})
    write_manifest(args, manifest)
    print(f"Wrote {poses_path} and {len(snapshots)} snapshots", flush=True)


def write_manifest(args, manifest):
    version = ""
    if os.path.exists("/isaac-sim/VERSION"):
        version = open("/isaac-sim/VERSION").read().strip()
    manifest.update({
        "fps": args.fps,
        "engine": {"physx": "PhysX", "newton": "Newton"}[args.engine],
        "gpu": gpu_name(),
        "seconds": round(time.time() - _started, 1),
        "software": f"Isaac Sim {version}" if version else "Isaac Sim",
        "image": args.image,
        "host": socket.gethostname(),
        "delivered_to": args.delivered_to,
        "finished": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
    })
    with open(os.path.join(args.out, "render.json"), "w") as handle:
        json.dump(manifest, handle, indent=2)


def close():
    if _app is not None:
        _app.close()
