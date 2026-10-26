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
JOINT_SEPARATION = 0.01  # meters a joint's two anchors drift apart, beyond their rest distance, before it counts as broken

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


def check_engine(stage, engine):
    """Newton takes joints only inside an articulation; a scene whose joints connect free
    bodies (the bonds of a fractured mesh) makes it refuse the whole stage and simulate
    nothing, with an error in the log and no other sign."""
    if engine != "newton":
        return
    from pxr import UsdPhysics  # noqa: E402

    def articulated(path):
        prim = stage.GetPrimAtPath(path)
        while prim and prim.IsValid():
            if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
                return True
            prim = prim.GetParent()
        return False

    loose = []
    for prim in stage.Traverse():
        if not prim.IsA(UsdPhysics.Joint):
            continue
        joint = UsdPhysics.Joint(prim)
        bodies = [str(t) for rel in (joint.GetBody0Rel(), joint.GetBody1Rel()) for t in rel.GetTargets()]
        if bodies and not any(articulated(b) for b in bodies):
            loose.append(str(prim.GetPath()))
    if loose:
        fail(f"Newton simulates joints only inside an articulation (a robot); this scene has {len(loose)} joints "
             f"between free bodies (the bonds of a fractured mesh): run it with PhysX")


def check_started(engine):
    """The manager logs a failed Newton start as a warning and plays on with nothing moving."""
    if engine != "newton":
        return
    import isaacsim.physics.newton  # noqa: E402
    newton_stage = isaacsim.physics.newton.acquire_stage()
    if newton_stage is None or not getattr(newton_stage, "initialized", False):
        fail("Newton did not initialize for this scene; its error is in the output above")


def _stop():
    import isaacsim.core.experimental.utils.app as app_utils  # noqa: E402
    app_utils.stop()


def rigid_bodies(stage):
    from pxr import UsdPhysics  # noqa: E402
    return [str(prim.GetPath()) for prim in stage.Traverse() if prim.HasAPI(UsdPhysics.RigidBodyAPI)]


def watch_joints(stage, view=None, paths=None):
    """The stage's joints, watched from before play. Returns None when it has none, else
    a function that, called later, tells which came apart. A joint holds two anchor
    points, one on each body; the distance between them where the bodies ended up is
    compared with the distance at rest, and a drift above JOINT_SEPARATION means the
    joint broke (a hinge keeps its distance; so does a fixed-base robot's root joint,
    whose anchors sit apart by the robot's placement). `view` and `paths`, a RigidPrim
    over the bodies and its paths, are reused when the caller has them."""
    from isaacsim.core.experimental.prims import RigidPrim  # noqa: E402
    from pxr import Gf, Usd, UsdGeom, UsdPhysics  # noqa: E402

    joints = []
    for prim in stage.Traverse():
        if not prim.IsA(UsdPhysics.Joint):
            continue
        joint = UsdPhysics.Joint(prim)
        body0 = [str(t) for t in joint.GetBody0Rel().GetTargets()]
        body1 = [str(t) for t in joint.GetBody1Rel().GetTargets()]
        joints.append((str(prim.GetPath()), body0[0] if body0 else None, body1[0] if body1 else None,
                       Gf.Vec3d(joint.GetLocalPos0Attr().Get() or (0, 0, 0)),
                       Gf.Vec3d(joint.GetLocalPos1Attr().Get() or (0, 0, 0))))
    if not joints:
        return None
    rigid = set(rigid_bodies(stage))
    bodies = sorted({b for _, b0, b1, _, _ in joints for b in (b0, b1) if b and b in rigid})
    if view is None:
        paths = bodies
        # The view before play: wrapping the bodies afterwards zeroes the velocities the scene authored
        view = RigidPrim(paths=paths) if paths else None
    index = {path: i for i, path in enumerate(paths or [])}

    def at_rest(body, local, xforms):
        if body is None:
            return local  # a joint to the world: the anchor is in world coordinates
        return xforms.GetLocalToWorldTransform(stage.GetPrimAtPath(body)).Transform(local)

    xforms = UsdGeom.XformCache(Usd.TimeCode.Default())
    try:
        rest = {path: (at_rest(b0, l0, xforms) - at_rest(b1, l1, xforms)).GetLength() for path, b0, b1, l0, l1 in joints}
    except Exception as error:  # a joint naming a body the stage lacks is the scene's problem, not the run's
        print(f"::warning::The joints will not be checked: {error}", flush=True)
        return None
    print(f"Watching {len(joints)} joints between {len(bodies)} bodies", flush=True)

    def broken():
        positions = orientations = None
        if view is not None and index:
            positions, orientations = view.get_world_poses()
            positions, orientations = positions.numpy(), orientations.numpy()
        xforms = UsdGeom.XformCache(Usd.TimeCode.Default())

        def anchor(body, local):
            if body in index:
                p, q = positions[index[body]], orientations[index[body]]
                return Gf.Vec3d(*map(float, p)) + Gf.Quatd(float(q[0]), Gf.Vec3d(*map(float, q[1:]))).Transform(local)
            # The world, or a body the engine does not move (a static collider): where the stage puts it
            return at_rest(body, local, xforms)

        try:
            apart = sorted(path for path, b0, b1, l0, l1 in joints
                           if (anchor(b0, l0) - anchor(b1, l1)).GetLength() - rest[path] > JOINT_SEPARATION)
        except Exception as error:  # a scene's joints are not worth losing its frames over
            print(f"::warning::The joints could not be checked: {error}", flush=True)
            return {}
        print(f"{len(apart)} of {len(joints)} joints broke", flush=True)
        return {"joints": len(joints), "broken_joints": len(apart), "broken": apart}

    return broken


def render(args, center, radius, scene, extras=None, on_frame=None):
    """Orbits a camera around `center` while the timeline plays and writes every frame
    as frames/rgb_NNNN.png, then render.json, with the joints that broke when the scene
    has any. `extras` (a dict, or a function called once the frames are done) goes into
    render.json."""
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

    check_engine(stage, args.engine)
    joints = watch_joints(stage)
    print("Writer attached; playing the timeline", flush=True)
    _play(args)
    check_started(args.engine)
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
    if callable(extras):
        extras = extras()
    manifest = {
        "scene": scene,
        "frames": [f"frames/{name}" for name in frames],
        "frame_count": len(frames),
        "width": args.width,
        "height": args.height,
        "renderer": args.renderer,
        "seconds_per_frame": round((time.time() - loop_started - (first_frame_seconds or 0)) / max(args.frames - 1, 1), 2),
    }
    if joints:
        manifest.update(joints())
    manifest.update(extras or {})
    write_manifest(args, manifest)
    print(f"Wrote {len(frames)} frames to {frames_dir}", flush=True)


def simulate(args, scene, extras=None, on_frame=None):
    """Plays the timeline with no camera and no writer: every frame the poses of the
    rigid bodies go to poses.csv, every `--snapshots` frames (and at the end) the stage
    with the bodies where they are goes to snapshots/frame_NNNN.usda; render.json tells
    the joints that broke when the scene has any."""
    import omni.replicator.core as rep  # noqa: E402
    import omni.usd  # noqa: E402
    from isaacsim.core.experimental.prims import RigidPrim  # noqa: E402
    from pxr import Gf, Usd, UsdGeom  # noqa: E402

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
    check_engine(stage, args.engine)
    print(f"Simulating {len(paths)} rigid bodies for {args.frames} frames at {args.fps} per second", flush=True)
    # The view before play: wrapping the bodies once the simulation runs zeroes the
    # velocities the scene authored (a thrown ball stops dead)
    bodies = RigidPrim(paths=paths)
    joints = watch_joints(stage, view=bodies, paths=paths)
    _play(args)
    check_started(args.engine)
    snapshots = []
    loop_started = time.time()

    def snapshot(frame):
        name = f"snapshots/frame_{frame + 1:04d}.usda"
        target = os.path.join(args.out, name)
        # The live stage keeps the initial poses (PhysX and Newton keep theirs in their
        # own buffers or in Fabric), so the flattened export gets the bodies' poses written
        # into it as a stage of its own: writing them into the live stage through the
        # view tears an articulation's links off their joints
        stage.Export(target)
        positions, orientations = bodies.get_world_poses()
        positions, orientations = positions.numpy(), orientations.numpy()
        snap = Usd.Stage.Open(target)
        cache = UsdGeom.XformCache()
        for path, p, q in zip(paths, positions, orientations):  # parents first, as traversed
            xform = UsdGeom.Xformable(snap.GetPrimAtPath(path))
            if not xform:
                continue
            world = (Gf.Matrix4d().SetRotate(Gf.Quatd(float(q[0]), Gf.Vec3d(*map(float, q[1:]))))
                     * Gf.Matrix4d().SetTranslate(Gf.Vec3d(*map(float, p))))
            scale = Gf.Transform(xform.GetLocalTransformation()).GetScale()
            local = Gf.Matrix4d().SetScale(scale) * world * cache.GetParentToWorldTransform(xform.GetPrim()).GetInverse()
            xform.MakeMatrixXform().Set(local)
            cache.Clear()
        snap.GetRootLayer().Save()
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
    if joints:
        manifest.update(joints())
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
