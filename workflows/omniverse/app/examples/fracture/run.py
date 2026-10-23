#!/usr/bin/env python3
"""Fracture: a wall prefractured into chunks, hit by a steel ball.

The chunks of scene.usda are rigid bodies held together by fixed joints that break
above a force; the ball's throw is its physics:velocity. The camera circles the wall
while the physics plays and every frame goes to a PNG. At the end the joints that
broke are counted into render.json. A scene from the source input replaces the wall.
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
joints = [UsdPhysics.Joint(prim) for prim in stage.Traverse() if prim.IsA(UsdPhysics.Joint)]


def broken():
    # PhysX disables a joint that exceeded its break force or torque
    return sum(1 for joint in joints if joint.GetJointEnabledAttr().Get() is False)


kitrun.render(args, center, radius,
              scene="fracture: a prefractured wall and a projectile" if args.scene == bundled else args.scene,
              extras={"joints": len(joints), "broken_joints": broken()})
print(f"{broken()} of {len(joints)} joints broke", flush=True)
kitrun.close()
