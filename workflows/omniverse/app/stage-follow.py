"""Opens a USD stage in the running Kit app and keeps it current while it changes on disk.

    isaac-sim.sh --exec "stage-follow.py /path/to/study.usda"

Started by isaac-sim-gui.sh when it is given a stage. Waits for the file to exist, opens
it, frames it in the viewport, then every few seconds reloads any layer of the stage
whose file changed (the study when a design is added, a design file when it is
rewritten) and frames the stage again when it grew. Opening another stage from the File
menu ends the following.

The stage the app shows has an in-memory root layer with the study as its sublayer. Kit
writes its own settings into the root layer of whatever it opens, and a field picked in
the Property panel is written there too; with the study as the root, the first such
edit would leave it with unsaved changes, which a reload would discard. Under the
in-memory root, those edits stay in place while the study reloads beneath them. A file
layer with unsaved edits (the edit target moved onto it) is left alone, with a warning.
"""

import asyncio
import os
import sys

import carb
import omni.kit.app
import omni.usd
from pxr import Sdf, Usd

POLL_S = 3.0


def follow_stage(path):
    """An in-memory stage over the study, with its up axis, units and default prim."""
    study = Sdf.Layer.FindOrOpen(path)
    name = os.path.basename(os.path.dirname(os.path.realpath(path))) or "study"
    stage = Usd.Stage.CreateInMemory(f"{name}.usda")
    root = stage.GetRootLayer()
    root.subLayerPaths.append(path)
    for key in ("upAxis", "metersPerUnit", "defaultPrim"):
        if study is not None and study.pseudoRoot.HasInfo(key):
            root.pseudoRoot.SetInfo(key, study.pseudoRoot.GetInfo(key))
    return stage


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


def aim(stage):
    """Points the perspective camera down at the stage from its front (-y) side, about 30
    degrees off vertical, so a grid of designs on the z = 0 plane reads like a table.
    Framing afterwards keeps this direction."""
    try:
        import omni.kit.commands
        from omni.kit.viewport.utility import get_active_viewport
        from pxr import Gf, UsdGeom
        viewport = get_active_viewport()
        box = UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_]) \
            .ComputeWorldBound(stage.GetDefaultPrim()).ComputeAlignedRange()
        if viewport is None or box.IsEmpty() or UsdGeom.GetStageUpAxis(stage) != UsdGeom.Tokens.z:
            return
        center, size = box.GetMidpoint(), box.GetSize()
        reach = max(size[0], size[1], 1e-3)
        eye = center + Gf.Vec3d(0.0, -0.55 * reach, reach)
        view = Gf.Matrix4d().SetLookAt(eye, center, Gf.Vec3d(0.0, 0.0, 1.0))
        omni.kit.commands.execute("TransformPrimCommand", path=str(viewport.camera_path),
                                  new_transform_matrix=view.GetInverse())
    except Exception as error:
        carb.log_warn(f"stage-follow: could not aim the camera: {error}")


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
    ok, error = await context.attach_stage_async(follow_stage(path))
    if not ok:
        carb.log_error(f"stage-follow: could not open {path}: {error}")
        return
    for _ in range(10):
        await app.next_update_async()
    stage = context.get_stage()
    aim(stage)
    frame(stage)
    root = stage.GetRootLayer().identifier
    print(f"stage-follow: following {os.path.realpath(path)}", flush=True)
    seen = {p: m for p, (m, _) in mtimes(stage).items()}
    count = len(stage.GetPrimAtPath("/World/Designs").GetChildren()) if stage.GetPrimAtPath("/World/Designs") else 0
    while True:
        await asyncio.sleep(POLL_S)
        stage = context.get_stage()
        if stage is None or stage.GetRootLayer().identifier != root:
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
