#!/usr/bin/env python3
"""Render a short physics animation to PNG frames with Isaac Sim, headless.

    python.sh render.py --out DIR [--frames N] [--width W --height H]
                        [--renderer RayTracedLighting|RealTimePathTracing|PathTracing]
                        [--fps F] [--scene PATH.usd]

Runs inside the Isaac Sim container (an Omniverse Kit application) on a GPU. The
built-in scene stacks colored cubes on a ground plane and throws a sphere at them;
--scene opens a USD stage of yours instead. The camera orbits the scene while the
timeline plays, Replicator writes every frame as DIR/frames/rgb_NNNN.png, and
DIR/render.json describes the result for the gallery page.
"""
import argparse
import json
import math
import os
import socket
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", required=True, help="output directory: frames/ and render.json")
parser.add_argument("--frames", type=int, default=90, help="frames to simulate and render")
parser.add_argument("--width", type=int, default=1280)
parser.add_argument("--height", type=int, default=720)
parser.add_argument("--renderer", default="RayTracedLighting",
                    choices=["RayTracedLighting", "RealTimePathTracing", "PathTracing"])
parser.add_argument("--fps", type=int, default=30, help="frames per second of simulated time")
parser.add_argument("--subframes", type=int, default=0,
                    help="render passes accumulated per frame; 0 picks a default for the renderer")
parser.add_argument("--scene", default="", help="a USD stage to render instead of the built-in scene")
parser.add_argument("--image", default="", help="the container image, recorded in render.json")
args, _ = parser.parse_known_args()

frames_dir = os.path.join(args.out, "frames")
os.makedirs(frames_dir, exist_ok=True)
for name in os.listdir(frames_dir):
    os.remove(os.path.join(frames_dir, name))
started = time.time()

# Kit starts here; every omni.* / isaacsim.* import must come after it
from isaacsim import SimulationApp  # noqa: E402

simulation_app = SimulationApp({
    "headless": True,
    "renderer": args.renderer,
    "width": args.width,
    "height": args.height,
})

import carb.settings  # noqa: E402
import isaacsim.core.experimental.utils.app as app_utils  # noqa: E402
import isaacsim.core.experimental.utils.stage as stage_utils  # noqa: E402
import omni.replicator.core as rep  # noqa: E402
import omni.usd  # noqa: E402
from isaacsim.core.experimental.materials import PreviewSurfaceMaterial  # noqa: E402
from isaacsim.core.experimental.objects import Cube, DistantLight, GroundPlane, Sphere  # noqa: E402
from isaacsim.core.experimental.prims import GeomPrim, RigidPrim  # noqa: E402
from isaacsim.core.simulation_manager import SimulationManager  # noqa: E402
from pxr import Gf, Usd, UsdGeom, UsdLux  # noqa: E402

PHYSICS_HZ = 60
BALL_START = (-3.2, -2.0, 1.0)
BALL_VELOCITY = (6.0, 3.8, 2.5)  # thrown at the stack; it arrives after about half a second
# Render passes accumulated per frame: the real-time modes converge their sampled
# lighting over passes (the DLSS denoiser needs the NGX library, which the container
# does not carry), path tracing already takes 64 samples per pass
SUBFRAMES = {"RayTracedLighting": 32, "RealTimePathTracing": 32, "PathTracing": 1}


def build_scene():
    """The built-in scene: a pyramid of cubes and a sphere thrown at it. Returns the
    point the camera looks at, the orbit radius and the sphere."""
    stage_utils.create_new_stage()
    GroundPlane("/World/GroundPlane", positions=[0, 0, 0])
    rep.functional.create.dome_light(intensity=300, parent="/World", name="DomeLight")
    DistantLight("/World/DistantLight").set_intensities(700)

    palette = [(0.91, 0.30, 0.24), (0.95, 0.61, 0.07), (0.18, 0.80, 0.44),
               (0.20, 0.60, 0.86), (0.61, 0.35, 0.71), (0.95, 0.85, 0.30)]
    materials = []
    for i, rgb in enumerate(palette):
        material = PreviewSurfaceMaterial(f"/World/Materials/color_{i}")
        material.set_input_values("diffuseColor", list(rgb))
        material.set_input_values("roughness", [0.4])
        materials.append(material)

    size = 0.4
    index = 0
    for level, per_side in enumerate((4, 3, 2, 1)):
        offset = (per_side - 1) * size / 2
        for row in range(per_side):
            for col in range(per_side):
                cube = Cube(paths=f"/World/Cubes/cube_{index}", sizes=size,
                            positions=[col * size - offset, row * size - offset, size / 2 + level * size])
                cube.apply_visual_materials(materials[index % len(materials)])
                RigidPrim(paths=cube.paths)
                GeomPrim(paths=cube.paths, apply_collision_apis=True)
                index += 1

    sphere = Sphere(paths="/World/Ball", radii=0.45, positions=[list(BALL_START)])
    ball_material = PreviewSurfaceMaterial("/World/Materials/ball")
    ball_material.set_input_values("diffuseColor", [0.92, 0.92, 0.95])
    ball_material.set_input_values("metallic", [1.0])
    ball_material.set_input_values("roughness", [0.15])
    sphere.apply_visual_materials(ball_material)
    ball = RigidPrim(paths=sphere.paths)
    GeomPrim(paths=sphere.paths, apply_collision_apis=True)
    return Gf.Vec3d(0, 0, 1.0), 5.0, ball


def open_scene(path):
    """A user's USD stage: framed from its bounds, lit if it has no light."""
    if not os.path.exists(path):
        sys.exit(f"::error::The scene {path} does not exist")
    if not omni.usd.get_context().open_stage(path):
        sys.exit(f"::error::Could not open the USD stage {path}")
    stage = omni.usd.get_context().get_stage()
    if not any(prim.HasAPI(UsdLux.LightAPI) for prim in stage.Traverse()):
        rep.functional.create.dome_light(intensity=600, name="DomeLight")
    bounds = UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_, UsdGeom.Tokens.render])
    box = bounds.ComputeWorldBound(stage.GetPseudoRoot()).ComputeAlignedRange()
    if box.IsEmpty():
        print("The stage has no bounds; orbiting the origin", flush=True)
        return Gf.Vec3d(0, 0, 0), 5.0, None
    radius = max((box.GetMax() - box.GetMin()).GetLength() / 2, 0.1)
    print(f"Stage bounds {tuple(round(v, 2) for v in box.GetMin())} to "
          f"{tuple(round(v, 2) for v in box.GetMax())}; the camera orbits {radius * 2.5:.1f} m from the center",
          flush=True)
    return box.GetMidpoint(), radius * 2.5, None


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


scene = args.scene or "built-in: a pyramid of cubes and a falling sphere"
print("Isaac Sim is up; building the scene", flush=True)
center, radius, ball = open_scene(args.scene) if args.scene else build_scene()
print("Scene ready; creating the camera and the writer", flush=True)
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

SimulationManager.set_physics_dt(1.0 / PHYSICS_HZ)
print("Writer attached; playing the timeline", flush=True)
app_utils.play()
simulation_app.update()
if ball is not None:
    ball.set_velocities(linear_velocities=[list(BALL_VELOCITY)])

print(f"Rendering {args.frames} frames at {args.width}x{args.height} with {args.renderer}, "
      f"{subframes} passes per frame, on {gpu_name()}", flush=True)
first_frame_seconds = None
loop_started = time.time()
for frame in range(args.frames):
    rep.functional.modify.pose(camera, position_value=orbit(center, radius, frame / args.frames, up_axis),
                               look_at_value=center, look_at_up_axis=up)
    rep.orchestrator.step(rt_subframes=subframes, delta_time=1.0 / args.fps, pause_timeline=False)
    if frame == 0:
        first_frame_seconds = round(time.time() - loop_started, 1)
    if frame % 10 == 0 or frame == args.frames - 1:
        print(f"frame {frame + 1}/{args.frames} after {time.time() - loop_started:.1f} s", flush=True)
rep.orchestrator.wait_until_complete()
writer.detach()
render_product.destroy()
app_utils.stop()

frames = sorted(name for name in os.listdir(frames_dir) if name.endswith(".png"))
seconds = round(time.time() - started, 1)
version = ""
for candidate in ("/isaac-sim/VERSION",):
    if os.path.exists(candidate):
        version = open(candidate).read().strip()
manifest = {
    "scene": scene,
    "frames": [f"frames/{name}" for name in frames],
    "frame_count": len(frames),
    "width": args.width,
    "height": args.height,
    "fps": args.fps,
    "renderer": args.renderer,
    "gpu": gpu_name(),
    "seconds": seconds,
    "seconds_per_frame": round((time.time() - loop_started - (first_frame_seconds or 0)) / max(args.frames - 1, 1), 2),
    "software": f"Isaac Sim {version}" if version else "Isaac Sim",
    "image": args.image,
    "host": socket.gethostname(),
    "finished": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
}
with open(os.path.join(args.out, "render.json"), "w") as handle:
    json.dump(manifest, handle, indent=2)
print(f"Wrote {len(frames)} frames to {frames_dir} in {seconds} s", flush=True)
simulation_app.close()
if len(frames) != args.frames:
    sys.exit(f"::error::Expected {args.frames} frames, found {len(frames)} in {frames_dir}")
