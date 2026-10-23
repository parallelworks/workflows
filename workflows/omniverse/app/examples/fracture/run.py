#!/usr/bin/env python3
"""Fracture: a wall prefractured into chunks, hit by a steel ball.

The chunks of scene.usda are rigid bodies held together by fixed joints that break
above a force; the ball's throw is its physics:velocity. The camera circles the wall
while the physics plays and every frame goes to a PNG. The joints PhysX breaks are
counted from its simulation events into render.json. A scene from the source input
replaces the wall.
"""
import os
import shutil
import sys

sys.path.insert(0, os.environ.get("OMNIVERSE_APP") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
import kitrun  # noqa: E402

bundled = kitrun.beside(__file__, "scene.usda")
args = kitrun.parse_args(__doc__, scene_default=bundled)
kitrun.start(args)
center, radius = kitrun.open_scene(args.scene)
if args.scene == bundled:
    shutil.copy(args.scene, os.path.join(args.out, "scene.usda"))

import omni.usd  # noqa: E402
from pxr import UsdPhysics  # noqa: E402

stage = omni.usd.get_context().get_stage()
joints = [prim for prim in stage.Traverse() if prim.IsA(UsdPhysics.Joint)]
broken = []
subscription = None
if args.engine == "physx" and joints:
    # PhysX reports a break as a simulation event; the USD joint itself stays as authored
    import omni.physx  # noqa: E402
    from omni.physx.bindings._physx import SimulationEvent  # noqa: E402

    def on_event(event):
        if event.type == int(SimulationEvent.JOINT_BREAK):
            path = event.payload.get("jointPath")
            try:
                from pxr import PhysicsSchemaTools
                path = str(PhysicsSchemaTools.decodeSdfPath(path[0], path[1]))
            except Exception:
                path = str(path)
            broken.append(path)

    subscription = omni.physx.get_physx_interface().get_simulation_event_stream_v2().create_subscription_to_pop(on_event)


def report(frame):
    if frame % 10 == 9:
        print(f"{len(broken)} of {len(joints)} joints broken after frame {frame + 1}", flush=True)


kitrun.render(args, center, radius,
              scene="fracture: a prefractured wall and a projectile" if args.scene == bundled else args.scene,
              extras={"joints": len(joints), "broken_joints": len(broken), "broken": sorted(broken)},
              on_frame=report)
print(f"{len(broken)} of {len(joints)} joints broke", flush=True)
subscription = None
kitrun.close()
