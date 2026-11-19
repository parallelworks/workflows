"""Opens a USD stage in the running Kit app and keeps it current while it changes on disk.

    isaac-sim.sh --exec "stage-follow.py /path/to/study.usda"

Started by isaac-sim-gui.sh when it is given a stage. Waits for the file to exist, opens
it, frames it in the viewport, then every few seconds reloads any layer of the stage
whose file changed (the root layer when a design is added, a design file when it is
rewritten) and frames the stage again when it grew. A layer with unsaved edits made in
the app is left alone, with a warning, so the follower never discards someone's work.
Opening another stage from the File menu ends the following.
"""

import asyncio
import os
import sys

import carb
import omni.kit.app
import omni.usd

POLL_S = 3.0


def frame(stage):
    try:
        from omni.kit.viewport.utility import frame_viewport_prims, get_active_viewport
        viewport = get_active_viewport()
        if viewport is not None:
            frame_viewport_prims(viewport, [str(stage.GetDefaultPrim().GetPath())])
            return
    except Exception as error:  # older Kit: fall back to the command
        carb.log_warn(f"stage-follow: viewport framing: {error}")
    try:
        import omni.kit.commands
        from omni.kit.viewport.utility import get_active_viewport
        viewport = get_active_viewport()
        omni.kit.commands.execute("FramePrimsCommand", prim_to_move=viewport.camera_path,
                                  prims_to_frame=[str(stage.GetDefaultPrim().GetPath())])
    except Exception as error:
        carb.log_warn(f"stage-follow: could not frame the stage: {error}")


def mtimes(stage):
    found = {}
    for layer in stage.GetUsedLayers():
        path = layer.realPath
        if path and os.path.isfile(path):
            found[path] = (os.stat(path).st_mtime_ns, layer)
    return found


async def follow(path):
    app = omni.kit.app.get_app()
    for _ in range(30):
        await app.next_update_async()
    while not os.path.isfile(path):
        carb.log_info(f"stage-follow: waiting for {path}")
        await asyncio.sleep(POLL_S)
    context = omni.usd.get_context()
    await context.open_stage_async(path)
    for _ in range(10):
        await app.next_update_async()
    stage = context.get_stage()
    frame(stage)
    root = os.path.realpath(path)
    print(f"stage-follow: following {root}", flush=True)
    seen = {p: m for p, (m, _) in mtimes(stage).items()}
    count = len(stage.GetPrimAtPath("/World/Designs").GetChildren()) if stage.GetPrimAtPath("/World/Designs") else 0
    while True:
        await asyncio.sleep(POLL_S)
        stage = context.get_stage()
        if stage is None or os.path.realpath(stage.GetRootLayer().realPath or "") != root:
            print("stage-follow: another stage is open; no longer following", flush=True)
            return
        changed = False
        for p, (m, layer) in mtimes(stage).items():
            if seen.get(p) == m:
                continue
            if layer.dirty:
                carb.log_warn(f"stage-follow: {p} changed on disk but has unsaved edits here; not reloaded")
            else:
                layer.Reload()
                changed = True
            seen[p] = m
        if changed:
            for _ in range(2):
                await app.next_update_async()
            stage = context.get_stage()
            seen = {p: m for p, (m, _) in mtimes(stage).items()}
            designs = stage.GetPrimAtPath("/World/Designs")
            now = len(designs.GetChildren()) if designs else 0
            print(f"stage-follow: reloaded; {now} designs", flush=True)
            if now != count:
                frame(stage)
                count = now


if len(sys.argv) < 2:
    carb.log_error("stage-follow: usage: stage-follow.py <stage.usda>")
else:
    asyncio.ensure_future(follow(sys.argv[1]))
