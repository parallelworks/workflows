#!/usr/bin/env python3
"""Physics only: the scene is simulated, nothing is rendered.

Every frame the pose of every rigid body goes to poses.csv, and every N frames (and
at the end) the stage with the bodies where they are goes to snapshots/frame_NNNN.usda,
to open in any USD tool, and the joints that came apart are counted into render.json.
The scene is the one from the source input, or else the fracture example's wall and
projectile.
"""
import os
import shutil
import sys

sys.path.insert(0, os.environ.get("OMNIVERSE_APP") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
import kitrun  # noqa: E402

bundled = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fracture", "scene.usda"))
args = kitrun.parse_args(__doc__, scene_default=bundled)
kitrun.start(args)
kitrun.open_scene(args.scene)
if args.scene == bundled:
    shutil.copy(args.scene, os.path.join(args.out, "scene.usda"))
kitrun.simulate(args, scene="fracture: a prefractured wall and a projectile" if args.scene == bundled else args.scene)
kitrun.close()
