#!/usr/bin/env python3
"""Fracture: a wall prefractured into chunks, hit by a steel ball.

The chunks of scene.usda are rigid bodies held together by fixed joints that break
above a force; the ball's throw is its physics:velocity. The camera circles the wall
while the physics plays and every frame goes to a PNG. At the end every joint is
checked: the two anchor points it held together, where their bodies ended up; the ones
that came apart are the broken bonds, counted into render.json with their paths. A
scene from the source input replaces the wall.
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
from isaacsim.core.experimental.prims import RigidPrim  # noqa: E402
from pxr import Gf, UsdPhysics  # noqa: E402

SEPARATION = 0.01  # meters between a joint's two anchors before it counts as broken

stage = omni.usd.get_context().get_stage()
joints = []
for prim in stage.Traverse():
    if not prim.IsA(UsdPhysics.Joint):
        continue
    joint = UsdPhysics.Joint(prim)
    body0 = [str(t) for t in joint.GetBody0Rel().GetTargets()]
    body1 = [str(t) for t in joint.GetBody1Rel().GetTargets()]
    joints.append((str(prim.GetPath()), body0[0] if body0 else None, body1[0] if body1 else None,
                   Gf.Vec3d(joint.GetLocalPos0Attr().Get() or (0, 0, 0)), Gf.Vec3d(joint.GetLocalPos1Attr().Get() or (0, 0, 0))))
bodies = sorted({b for _, b0, b1, _, _ in joints for b in (b0, b1) if b})
# The view before play: wrapping the bodies afterwards zeroes the velocities the scene authored
view = RigidPrim(paths=bodies) if bodies else None


def broken_bonds():
    if view is None:
        return {"joints": 0, "broken_joints": 0, "broken": []}
    positions, orientations = view.get_world_poses()
    positions, orientations = positions.numpy(), orientations.numpy()
    index = {path: i for i, path in enumerate(bodies)}

    def anchor(body, local):
        if body is None:
            return local  # a joint to the world: the anchor is in world coordinates
        p, q = positions[index[body]], orientations[index[body]]
        return Gf.Vec3d(*map(float, p)) + Gf.Quatd(float(q[0]), Gf.Vec3d(*map(float, q[1:]))).Transform(local)

    broken = sorted(path for path, b0, b1, l0, l1 in joints if (anchor(b0, l0) - anchor(b1, l1)).GetLength() > SEPARATION)
    return {"joints": len(joints), "broken_joints": len(broken), "broken": broken}


kitrun.render(args, center, radius,
              scene="fracture: a prefractured wall and a projectile" if args.scene == bundled else args.scene,
              extras=broken_bonds)
result = broken_bonds()
print(f"{result['broken_joints']} of {result['joints']} joints broke", flush=True)
kitrun.close()
