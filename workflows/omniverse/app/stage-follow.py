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

Two hints in the stage's customLayerData, which usd-export's flow.usda carries: pw:view
(eye and target, in stage units) places the camera there in place of framing the stage,
and pw:play starts the timeline over the stage's time range, looping.

    stage-follow.py <stage.usda> --controls

also answers a streamed web viewer (omni.kit.livestream.messaging): a "pw:control"
message with action play, pause, wall (value: a variant of /World's "wall" set), view
(back to the pw:view hint) or state gets a "pw:state" reply, and a reload sends one
unasked. The state is one JSON string field, "json": playing, the wall variant and its
choices, the design and /World's customData. The streaming plugin drops replies until
it counts the viewer as connected, a few hundred milliseconds after the video starts,
so a viewer asks for the state until the first reply arrives.
"""

import asyncio
import json
import os
import sys

import carb
import omni.kit.app
import omni.usd
from pxr import Sdf, Usd

POLL_S = 3.0


STAGE_INFO = ("upAxis", "metersPerUnit", "defaultPrim", "startTimeCode", "endTimeCode", "timeCodesPerSecond",
              "framesPerSecond")


def copy_info(study, root):
    """The followed layer's stage metadata onto the in-memory root, which is what Kit and
    the timeline read."""
    for key in STAGE_INFO:
        if study is not None and study.pseudoRoot.HasInfo(key):
            root.pseudoRoot.SetInfo(key, study.pseudoRoot.GetInfo(key))


def follow_stage(path):
    """An in-memory stage over the study, with its up axis, units, default prim and time
    range."""
    study = Sdf.Layer.FindOrOpen(path)
    name = os.path.basename(os.path.dirname(os.path.realpath(path))) or "study"
    stage = Usd.Stage.CreateInMemory(f"{name}.usda")
    root = stage.GetRootLayer()
    root.subLayerPaths.append(path)
    copy_info(study, root)
    return stage


def hints(path):
    layer = Sdf.Layer.FindOrOpen(path)
    return dict(layer.customLayerData) if layer is not None else {}


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


def look(stage, view):
    """Puts the perspective camera at the pw:view hint's eye, looking at its target, up
    along the stage's up axis, with the orbit pivot on the target and a near clip close
    enough for a close look at a model one unit across."""
    try:
        import omni.kit.commands
        from omni.kit.viewport.utility import get_active_viewport
        from pxr import Gf, UsdGeom
        viewport = get_active_viewport()
        if viewport is None:
            return
        up = Gf.Vec3d(0, 0, 1) if UsdGeom.GetStageUpAxis(stage) == UsdGeom.Tokens.z else Gf.Vec3d(0, 1, 0)
        eye, target = Gf.Vec3d(*view["eye"]), Gf.Vec3d(*view["target"])
        matrix = Gf.Matrix4d().SetLookAt(eye, target, up)
        omni.kit.commands.execute("TransformPrimCommand", path=str(viewport.camera_path),
                                  new_transform_matrix=matrix.GetInverse())
        camera = stage.GetPrimAtPath(viewport.camera_path)
        with Usd.EditContext(stage, stage.GetSessionLayer()):
            UsdGeom.Camera(camera).GetClippingRangeAttr().Set(Gf.Vec2f(0.01, 1.0e5))
            pivot = camera.GetAttribute("omni:kit:centerOfInterest")
            if pivot:
                pivot.Set(Gf.Vec3d(0, 0, -(target - eye).GetLength()))
    except Exception as error:
        carb.log_warn(f"stage-follow: could not place the camera: {error}")


def play(stage):
    """Plays the stage's time range in a loop."""
    try:
        import omni.timeline
        timeline = omni.timeline.get_timeline_interface()
        rate = stage.GetTimeCodesPerSecond()
        timeline.set_time_codes_per_second(rate)
        timeline.set_start_time(stage.GetStartTimeCode() / rate)
        timeline.set_end_time(stage.GetEndTimeCode() / rate)
        timeline.set_looping(True)
        timeline.play()
    except Exception as error:
        carb.log_warn(f"stage-follow: could not start the timeline: {error}")


def stage_state(path, playing=None):
    """The viewer's state as one JSON string. The timeline applies play and pause on the
    next update, so a reply to either passes the requested state as playing."""
    stage = omni.usd.get_context().get_stage()
    world = stage.GetPrimAtPath("/World") if stage else None
    state = {"playing": False, "wall": "", "walls": [], "design": hints(path).get("design", ""), "info": {}}
    try:
        from omni.timeline import get_timeline_interface
        state["playing"] = bool(get_timeline_interface().is_playing()) if playing is None else playing
    except Exception:
        pass
    if world:
        sets = world.GetVariantSets()
        if sets.HasVariantSet("wall"):
            wall = sets.GetVariantSet("wall")
            state["wall"], state["walls"] = wall.GetVariantSelection(), list(wall.GetVariantNames())
        state["info"] = {k: v for k, v in world.GetCustomData().items() if isinstance(v, (bool, int, float, str))}
    return {"json": json.dumps(state)}


def enable_controls(path):
    """Answers the web viewer's pw:control messages; returns a function that sends the
    state unasked."""
    manager = omni.kit.app.get_app().get_extension_manager()
    if not manager.is_extension_enabled("omni.kit.livestream.messaging"):
        manager.set_extension_enabled_immediate("omni.kit.livestream.messaging", True)
    import carb.eventdispatcher
    import omni.kit.livestream.messaging as messaging

    @messaging.observe_and_dispatch("pw:control", response_name="pw:state")
    def control(event, action="state", value="", **_):
        print(f"stage-follow: control {action} {value}".rstrip(), flush=True)
        stage = omni.usd.get_context().get_stage()
        try:
            from omni.timeline import get_timeline_interface
            timeline = get_timeline_interface()
            if action == "play":
                timeline.play()
            elif action == "pause":
                timeline.pause()
            elif action == "wall" and stage and stage.GetPrimAtPath("/World"):
                wall = stage.GetPrimAtPath("/World").GetVariantSets().GetVariantSet("wall")
                if value in wall.GetVariantNames():
                    wall.SetVariantSelection(value)
            elif action == "view" and "pw:view" in hints(path):
                look(stage, hints(path)["pw:view"])
        except Exception as error:
            carb.log_warn(f"stage-follow: control {action}: {error}")
        return stage_state(path, playing={"play": True, "pause": False}.get(action))

    messaging.register_event_type_to_send("pw:state")
    print("stage-follow: answering pw:control messages from a streamed viewer", flush=True)
    return lambda: carb.eventdispatcher.get_eventdispatcher().dispatch_event("pw:state", payload=stage_state(path))


def mtimes(stage):
    found = {}
    for layer in stage.GetUsedLayers():
        path = layer.realPath
        if path and os.path.isfile(path):
            found[path] = (os.stat(path).st_mtime_ns, layer)
    return found


async def follow(path, controls=False):
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
    hint = hints(path)
    if "pw:view" in hint:
        look(stage, hint["pw:view"])
    else:
        aim(stage)
        frame(stage)
    if hint.get("pw:play"):
        play(stage)
    root = stage.GetRootLayer().identifier
    print(f"stage-follow: following {os.path.realpath(path)}", flush=True)
    send_state = None
    if controls:
        try:
            send_state = enable_controls(path)
        except Exception as error:
            carb.log_error(f"stage-follow: no web controls: {error}")
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
            copy_info(Sdf.Layer.FindOrOpen(path), stage.GetRootLayer())
            if send_state:
                send_state()
            seen = {p: m for p, (m, _) in mtimes(stage).items()}
            designs = stage.GetPrimAtPath("/World/Designs")
            if not designs:
                print(f"stage-follow: reloaded; {hints(path).get('design', 'the stage')} shown", flush=True)
                continue
            now = len(designs.GetChildren())
            print(f"stage-follow: reloaded; {now} designs", flush=True)
            if now != count:
                frame(stage)
                count = now


if len(sys.argv) < 2:
    carb.log_error("stage-follow: usage: stage-follow.py <stage.usda> [--controls]")
else:
    asyncio.ensure_future(follow(sys.argv[1], controls="--controls" in sys.argv[2:]))
