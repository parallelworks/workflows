#!/usr/bin/env python3
"""A scene of yours, opened as it is.

The USD file from the source input is framed from the bounds of its objects (a floor
is ignored), lit with a dome light when it has no light, and its timeline played, so
any physics or animation in the file runs during the frames; the joints that came
apart, if it has any, are counted into render.json.
"""
import os
import sys

sys.path.insert(0, os.environ.get("OMNIVERSE_APP") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
import kitrun  # noqa: E402

args = kitrun.parse_args(__doc__)
kitrun.start(args)
center, radius = kitrun.open_scene(args.scene)
kitrun.render(args, center, radius, scene=args.scene)
kitrun.close()
