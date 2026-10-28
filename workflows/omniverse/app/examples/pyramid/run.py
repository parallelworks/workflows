#!/usr/bin/env python3
"""The pyramid: thirty colored blocks stacked on a floor and a steel ball thrown at them.

The scene is scene.usda beside this script (the ball's throw is its physics:velocity);
the camera circles it while the physics plays and every frame goes to a PNG. A scene
from the source input replaces the bundled one.
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
    # The scene as a file to read, edit and hand back as the source input
    shutil.copy(args.scene, os.path.join(args.out, "scene.usda"))
kitrun.render(args, center, radius, scene="pyramid: thirty blocks and a ball" if args.scene == bundled else args.scene)
kitrun.close()
