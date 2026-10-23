#!/usr/bin/env python3
"""Build a USD scene from a manifest, headless: meshes and robots imported, placed and
given physics, written out with everything they reference beside them.

    python.sh build.py --manifest FILE --source DIR --out DIR

The manifest (YAML or JSON) names the scene and lists its objects; every `file` is
relative to the source directory:

    scene: yard.usda          # the file written to DIR (default scene.usda)
    up_axis: Z                # Z (default) or Y
    ground: true              # a ground plane (default true)
    objects:
      - name: crate           # the prim /World/crate
        file: parts/crate.obj # .obj .stl .fbx .gltf .glb: converted; .usd*: referenced;
                              # .urdf, .xml (MJCF): imported as a robot
        position: [0, 0, 1]   # meters
        rotation: [0, 0, 30]  # degrees about X, Y, Z
        scale: 1              # a number or [x, y, z]
        physics: rigid        # rigid (falls, collides), static (collides, fixed) or none
        collision: convexHull # convexHull, convexDecomposition, boundingCube, boundingSphere
        mass: 5               # kg; else the density (kg/m3, default 1000) sets it
        velocity: [2, 0, 0]   # m/s, an initial throw
        color: [0.8, 0.2, 0.2]
      - name: arm
        file: robots/arm.urdf
        fix_base: true        # robots: bolted to the world, or free

DIR/build.json summarizes what was built. Runs inside the Isaac Sim container.
"""
import argparse
import asyncio
import json
import os
import shutil
import sys
import time

MESH_EXTENSIONS = (".obj", ".stl", ".fbx", ".gltf", ".glb")
USD_EXTENSIONS = (".usd", ".usda", ".usdc", ".usdz")
COLLISION = {"convexHull": "convexHull", "convexDecomposition": "convexDecomposition",
             "boundingCube": "boundingCube", "boundingSphere": "boundingSphere"}

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--manifest", required=True, help="the manifest file (YAML or JSON)")
parser.add_argument("--source", required=True, help="the directory the manifest's files are relative to")
parser.add_argument("--out", required=True, help="output directory: the scene, assets/ and build.json")
parser.add_argument("--tag", default="", help="ignored; lets a cleanup script find this process")
args, _ = parser.parse_known_args()
started = time.time()


def fail(message):
    print(f"::error::{message}", flush=True)
    sys.exit(1)


def load_manifest(path):
    text = open(path).read()
    try:
        import yaml
        data = yaml.safe_load(text)
    except ImportError:
        data = json.loads(text)
    except Exception as error:
        fail(f"The manifest {path} is not valid YAML or JSON: {error}")
    if not isinstance(data, dict) or not isinstance(data.get("objects"), list) or not data["objects"]:
        fail(f"The manifest {path} must be a mapping with an 'objects' list")
    for index, obj in enumerate(data["objects"]):
        if not isinstance(obj, dict) or not obj.get("file"):
            fail(f"Object {index + 1} of the manifest has no 'file'")
        obj.setdefault("name", os.path.splitext(os.path.basename(obj["file"]))[0])
        obj["name"] = "".join(c if c.isalnum() or c == "_" else "_" for c in str(obj["name"]))
        if obj["name"][0].isdigit():
            obj["name"] = "_" + obj["name"]
        if not os.path.exists(os.path.join(args.source, obj["file"])):
            fail(f"{obj['file']} (object {obj['name']}) is not in the source {args.source}")
    names = [obj["name"] for obj in data["objects"]]
    if len(set(names)) != len(names):
        fail(f"Object names must be unique, got {names}")
    return data


manifest = load_manifest(args.manifest)
scene_name = manifest.get("scene") or "scene.usda"
if not scene_name.lower().endswith(".usda"):
    fail(f"The scene must be a .usda file name (its asset paths are made relative in the text), got {scene_name}")
assets_dir = os.path.join(args.out, "assets")
if os.path.isdir(assets_dir):
    shutil.rmtree(assets_dir)
os.makedirs(assets_dir)

# Kit starts here; every omni.* / isaacsim.* import must come after it
from isaacsim import SimulationApp  # noqa: E402

simulation_app = SimulationApp({"headless": True})

import omni.replicator.core as rep  # noqa: E402
import omni.usd  # noqa: E402
from isaacsim.core.experimental.utils.app import enable_extension  # noqa: E402
import isaacsim.core.experimental.utils.stage as stage_utils  # noqa: E402
from isaacsim.core.experimental.materials import PreviewSurfaceMaterial  # noqa: E402
from isaacsim.core.experimental.objects import DistantLight, GroundPlane  # noqa: E402
from pxr import Gf, Usd, UsdGeom, UsdPhysics, UsdShade  # noqa: E402

enable_extension("omni.kit.asset_converter")
import omni.kit.asset_converter  # noqa: E402

stage_utils.create_new_stage()
stage = omni.usd.get_context().get_stage()
up_axis = str(manifest.get("up_axis", "Z")).upper()
UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y if up_axis == "Y" else UsdGeom.Tokens.z)
UsdGeom.SetStageMetersPerUnit(stage, 1.0)
world = UsdGeom.Xform.Define(stage, "/World")
stage.SetDefaultPrim(world.GetPrim())
physics_scene = UsdPhysics.Scene.Define(stage, "/World/PhysicsScene")
physics_scene.CreateGravityDirectionAttr().Set(Gf.Vec3f(0, -1, 0) if up_axis == "Y" else Gf.Vec3f(0, 0, -1))
physics_scene.CreateGravityMagnitudeAttr().Set(9.81)
if manifest.get("ground", True):
    GroundPlane("/World/GroundPlane", positions=[0, 0, 0])
rep.functional.create.dome_light(intensity=300, parent="/World", name="DomeLight")
DistantLight("/World/DistantLight").set_intensities(700)


async def convert(source, target):
    context = omni.kit.asset_converter.AssetConverterContext()
    context.ignore_materials = False
    context.use_meter_as_world_unit = True
    task = omni.kit.asset_converter.get_instance().create_converter_task(source, target, lambda *_: None, context)
    return await task.wait_until_finished()


def import_robot(obj, source, target_dir):
    ext = os.path.splitext(source)[1].lower()
    if ext == ".urdf":
        enable_extension("isaacsim.asset.importer.urdf")
        from isaacsim.asset.importer.urdf import URDFImporter, URDFImporterConfig
        config = URDFImporterConfig(urdf_path=source, usd_path=target_dir, fix_base=obj.get("fix_base"),
                                    collision_from_visuals=True, merge_fixed_joints=False)
        return URDFImporter(config).import_urdf()
    enable_extension("isaacsim.asset.importer.mjcf")
    from isaacsim.asset.importer.mjcf import MJCFImporter, MJCFImporterConfig
    config = MJCFImporterConfig(mjcf_path=source, usd_path=target_dir, fix_base=obj.get("fix_base"))
    return MJCFImporter(config).import_mjcf()


def vector(value, name, default):
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return (float(value),) * 3
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        fail(f"{name} must be three numbers, got {value!r}")
    return tuple(float(v) for v in value)


def place(prim, obj):
    xform = UsdGeom.XformCommonAPI(prim)
    xform.SetTranslate(Gf.Vec3d(*vector(obj.get("position"), "position", (0.0, 0.0, 0.0))))
    xform.SetRotate(Gf.Vec3f(*vector(obj.get("rotation"), "rotation", (0.0, 0.0, 0.0))))
    xform.SetScale(Gf.Vec3f(*vector(obj.get("scale"), "scale", (1.0, 1.0, 1.0))))


def apply_physics(prim, obj):
    mode = str(obj.get("physics", "rigid")).lower()
    if mode not in ("rigid", "static", "none"):
        fail(f"{obj['name']}: physics must be rigid, static or none, got {mode}")
    if mode == "none":
        return 0
    approximation = COLLISION.get(obj.get("collision", "convexHull"))
    if approximation is None:
        fail(f"{obj['name']}: collision must be one of {', '.join(COLLISION)}")
    meshes = 0
    for child in Usd.PrimRange(prim):
        if child.IsA(UsdGeom.Gprim):
            UsdPhysics.CollisionAPI.Apply(child)
            if child.IsA(UsdGeom.Mesh):
                UsdPhysics.MeshCollisionAPI.Apply(child).CreateApproximationAttr().Set(approximation)
            meshes += 1
    if meshes == 0:
        fail(f"{obj['name']}: {obj['file']} holds no geometry to collide with")
    if mode == "static":
        return 0
    body = UsdPhysics.RigidBodyAPI.Apply(prim)
    mass = UsdPhysics.MassAPI.Apply(prim)
    if obj.get("mass") is not None:
        mass.CreateMassAttr().Set(float(obj["mass"]))
    else:
        mass.CreateDensityAttr().Set(float(obj.get("density", 1000.0)))
    if obj.get("velocity") is not None:
        body.CreateVelocityAttr().Set(Gf.Vec3f(*vector(obj["velocity"], "velocity", (0.0, 0.0, 0.0))))
    return 1


def paint(prim, obj, index):
    if obj.get("color") is None:
        return
    rgb = vector(obj["color"], "color", (0.5, 0.5, 0.5))
    material = PreviewSurfaceMaterial(f"/World/Materials/color_{index}")
    material.set_input_values("diffuseColor", list(rgb))
    material.set_input_values("roughness", [0.4])
    UsdShade.MaterialBindingAPI.Apply(prim).Bind(
        UsdShade.Material(stage.GetPrimAtPath(f"/World/Materials/color_{index}")),
        bindingStrength=UsdShade.Tokens.strongerThanDescendants)


summary = []
bodies = 0
for index, obj in enumerate(manifest["objects"]):
    source = os.path.join(args.source, obj["file"])
    ext = os.path.splitext(source)[1].lower()
    name = obj["name"]
    print(f"{name}: {obj['file']}", flush=True)
    if ext in MESH_EXTENSIONS:
        asset = os.path.join(assets_dir, f"{name}.usd")
        if not asyncio.get_event_loop().run_until_complete(convert(source, asset)):
            fail(f"{name}: the asset converter could not convert {obj['file']}")
        kind = "mesh"
    elif ext in USD_EXTENSIONS:
        asset = os.path.join(assets_dir, f"{name}{ext}")
        shutil.copy(source, asset)
        kind = "usd"
    elif ext in (".urdf", ".xml"):
        asset = import_robot(obj, source, os.path.join(assets_dir, name))
        if not asset or not os.path.exists(asset):
            fail(f"{name}: the robot importer wrote nothing for {obj['file']}")
        kind = "robot"
    else:
        fail(f"{name}: {obj['file']} is not a mesh ({', '.join(MESH_EXTENSIONS)}), a USD file or a robot (.urdf, .xml)")
    # The asset goes under a child prim: a converted file brings transform ops of its
    # own, and the placement must not collide with them
    prim = stage.DefinePrim(f"/World/{name}", "Xform")
    stage.DefinePrim(f"/World/{name}/geometry", "Xform").GetReferences().AddReference(asset)
    place(prim, obj)
    paint(prim, obj, index)
    if kind == "robot":
        count = len([p for p in Usd.PrimRange(prim) if p.HasAPI(UsdPhysics.RigidBodyAPI)])
        physics = f"articulation, {count} links"
    else:
        count = apply_physics(prim, obj)
        physics = str(obj.get("physics", "rigid"))
    bodies += count
    summary.append({"name": name, "file": obj["file"], "kind": kind, "asset": os.path.relpath(asset, args.out),
                    "physics": physics})

scene_path = os.path.join(args.out, scene_name)
stage.GetRootLayer().Export(scene_path)
# The assets are referenced by absolute path while building; the written scene keeps
# them beside it, so the directory moves as a whole
text = open(scene_path).read().replace(f"@{assets_dir}/", "@./assets/")
open(scene_path, "w").write(text)
joints = len([p for p in stage.Traverse() if p.IsA(UsdPhysics.Joint)])
with open(os.path.join(args.out, "build.json"), "w") as handle:
    json.dump({"scene": scene_name, "objects": summary, "rigid_bodies": bodies, "joints": joints,
               "up_axis": up_axis, "seconds": round(time.time() - started, 1)}, handle, indent=2)
print(f"Wrote {scene_path}: {len(summary)} objects, {bodies} rigid bodies, {joints} joints", flush=True)
simulation_app.close()
