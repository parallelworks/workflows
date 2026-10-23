#!/usr/bin/env python3
"""Turn blast-fracture's chunks into the fracture example's USD scene.

    python3 make-scene.py chunks.obj scene.usda [--strength PA] [--density KG_M3]

Every chunk becomes a rigid body with a convex-hull collider; every pair of chunks that
share a cut face gets a fixed joint at the face's centroid, breaking at the face's area
times --strength (a tensile strength in pascals). A steel ball with an initial velocity
is thrown at the wall, which stands on a ground plane. Needs the pxr module
(pip install usd-core).
"""
import argparse
import math
from collections import defaultdict

from pxr import Gf, Sdf, Usd, UsdGeom, UsdLux, UsdPhysics, UsdShade, Vt

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("chunks")
parser.add_argument("scene")
parser.add_argument("--strength", type=float, default=400000.0, help="tensile strength of the bonds, Pa")
parser.add_argument("--density", type=float, default=2400.0, help="the material's density, kg/m3")
parser.add_argument("--ball-radius", type=float, default=0.18)
parser.add_argument("--ball-density", type=float, default=7800.0)
parser.add_argument("--ball-start", type=float, nargs=3, default=(0.25, -2.6, 0.7))
parser.add_argument("--ball-velocity", type=float, nargs=3, default=(-0.6, 9.0, 0.6))
args = parser.parse_args()


def read_chunks(path):
    chunks, verts, current, material = [], [], None, "exterior"
    for line in open(path):
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "g":
            current = {"name": parts[1], "faces": []}
            chunks.append(current)
        elif parts[0] == "v":
            verts.append(tuple(float(v) for v in parts[1:4]))
        elif parts[0] == "usemtl":
            material = parts[1]
        elif parts[0] == "f":
            ids = [int(p.split("/")[0]) - 1 for p in parts[1:]]
            current["faces"].append((ids, material))
    return verts, chunks


def plane_key(a, b, c):
    """A hashable plane: the unit normal (signs folded) and the offset, rounded."""
    u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    v = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
    n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
    length = math.sqrt(sum(x * x for x in n))
    if length == 0:
        return None, 0.0
    n = tuple(x / length for x in n)
    offset = sum(n[i] * a[i] for i in range(3))
    # The two chunks see the face with opposite normals: fold the sign
    if n[0] < 0 or (n[0] == 0 and (n[1] < 0 or (n[1] == 0 and n[2] < 0))):
        n, offset = tuple(-x for x in n), -offset
    return tuple(round(x, 3) for x in n), round(offset, 3), length / 2


verts, chunks = read_chunks(args.chunks)
stage = Usd.Stage.CreateNew(args.scene)
UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
UsdGeom.SetStageMetersPerUnit(stage, 1.0)
stage.SetTimeCodesPerSecond(60)
world = UsdGeom.Xform.Define(stage, "/World")
stage.SetDefaultPrim(world.GetPrim())
scene = UsdPhysics.Scene.Define(stage, "/World/PhysicsScene")
scene.CreateGravityDirectionAttr().Set(Gf.Vec3f(0, 0, -1))
scene.CreateGravityMagnitudeAttr().Set(9.81)

ground = UsdGeom.Mesh.Define(stage, "/World/GroundPlane/CollisionMesh")
ground.CreatePointsAttr([Gf.Vec3f(-15, -15, 0), Gf.Vec3f(15, -15, 0), Gf.Vec3f(15, 15, 0), Gf.Vec3f(-15, 15, 0)])
ground.CreateFaceVertexCountsAttr([4])
ground.CreateFaceVertexIndicesAttr([0, 1, 2, 3])
ground.CreateNormalsAttr([Gf.Vec3f(0, 0, 1)] * 4)
ground.CreateExtentAttr([Gf.Vec3f(-15, -15, 0), Gf.Vec3f(15, 15, 0)])
UsdPhysics.CollisionAPI.Apply(ground.GetPrim())
UsdGeom.Xform.Define(stage, "/World/GroundPlane")
dome = UsdLux.DomeLight.Define(stage, "/World/DomeLight")
dome.CreateIntensityAttr(300)
sun = UsdLux.DistantLight.Define(stage, "/World/DistantLight")
sun.CreateIntensityAttr(700)
sun.CreateAngleAttr(1.0)
UsdGeom.Xformable(sun).AddRotateXYZOp().Set(Gf.Vec3f(35, 25, 0))


def material(path, rgb, roughness=0.6, metallic=0.0):
    mat = UsdShade.Material.Define(stage, path)
    shader = UsdShade.Shader.Define(stage, path + "/Shader")
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgb))
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(roughness)
    shader.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(metallic)
    mat.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    return mat


concrete = material("/World/Materials/concrete", (0.72, 0.70, 0.66))
UsdShade.MaterialBindingAPI.Apply(ground.GetPrim()).Bind(material("/World/Materials/ground", (0.33, 0.42, 0.52), roughness=0.8))
rubble = material("/World/Materials/rubble", (0.58, 0.55, 0.50), roughness=0.9)
steel = material("/World/Materials/steel", (0.92, 0.92, 0.95), roughness=0.15, metallic=1.0)

faces_by_plane = defaultdict(list)
for index, chunk in enumerate(chunks):
    path = f"/World/Wall/chunk_{index}"
    mesh = UsdGeom.Mesh.Define(stage, path)
    used = sorted({i for ids, _ in chunk["faces"] for i in ids})
    remap = {v: n for n, v in enumerate(used)}
    points = [Gf.Vec3f(*verts[v]) for v in used]
    counts, indices, normals, interior = [], [], [], []
    for face_number, (ids, kind) in enumerate(chunk["faces"]):
        a, b, c = (verts[i] for i in ids[:3])
        key = plane_key(a, b, c)
        if key[0] is None:
            continue
        normal, offset, area = key
        counts.append(len(ids))
        indices.extend(remap[i] for i in ids)
        u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
        v = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
        n = Gf.Vec3f(u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]).GetNormalized()
        normals.extend([n] * len(ids))
        if kind == "interior":
            centroid = tuple(sum(p[k] for p in (a, b, c)) / 3 for k in range(3))
            faces_by_plane[(normal, offset)].append((index, area, centroid))
            interior.append(face_number)
    mesh.CreatePointsAttr(points)
    mesh.CreateFaceVertexCountsAttr(counts)
    mesh.CreateFaceVertexIndicesAttr(indices)
    mesh.CreateNormalsAttr(normals)
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.faceVarying)
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    lo = Gf.Vec3f(*(min(p[k] for p in points) for k in range(3)))
    hi = Gf.Vec3f(*(max(p[k] for p in points) for k in range(3)))
    mesh.CreateExtentAttr([lo, hi])
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(concrete)
    if interior:
        subset = UsdGeom.Subset.CreateGeomSubset(mesh, "interior", UsdGeom.Tokens.face, Vt.IntArray(interior),
                                                 familyName="materialBind")
        UsdShade.MaterialBindingAPI.Apply(subset.GetPrim()).Bind(rubble)
    UsdPhysics.RigidBodyAPI.Apply(mesh.GetPrim())
    UsdPhysics.CollisionAPI.Apply(mesh.GetPrim())
    UsdPhysics.MeshCollisionAPI.Apply(mesh.GetPrim()).CreateApproximationAttr().Set(UsdPhysics.Tokens.convexHull)
    UsdPhysics.MassAPI.Apply(mesh.GetPrim()).CreateDensityAttr().Set(args.density)

# A cut plane is shared by the two chunks it separates: one bond per pair, at the
# centroid of their shared face, breaking at the face's area times the strength
bonds = 0
for (normal, offset), faces in faces_by_plane.items():
    by_chunk = defaultdict(lambda: [0.0, [0.0, 0.0, 0.0]])
    for index, area, centroid in faces:
        entry = by_chunk[index]
        entry[0] += area
        for k in range(3):
            entry[1][k] += centroid[k] * area
    members = sorted(by_chunk)
    if len(members) < 2:
        continue
    for i in range(len(members)):
        for j in range(i + 1, len(members)):
            a, b = members[i], members[j]
            area = min(by_chunk[a][0], by_chunk[b][0])
            if area < 1e-4:
                continue
            total = by_chunk[a][0] + by_chunk[b][0]
            centroid = Gf.Vec3f(*((by_chunk[a][1][k] + by_chunk[b][1][k]) / total for k in range(3)))
            joint = UsdPhysics.FixedJoint.Define(stage, f"/World/Wall/Bonds/bond_{a}_{b}")
            joint.CreateBody0Rel().SetTargets([Sdf.Path(f"/World/Wall/chunk_{a}")])
            joint.CreateBody1Rel().SetTargets([Sdf.Path(f"/World/Wall/chunk_{b}")])
            joint.CreateLocalPos0Attr().Set(centroid)
            joint.CreateLocalPos1Attr().Set(centroid)
            joint.CreateLocalRot0Attr().Set(Gf.Quatf(1, 0, 0, 0))
            joint.CreateLocalRot1Attr().Set(Gf.Quatf(1, 0, 0, 0))
            joint.CreateBreakForceAttr().Set(float(area * args.strength))
            joint.CreateBreakTorqueAttr().Set(float(area * args.strength * 0.2))
            bonds += 1

ball = UsdGeom.Sphere.Define(stage, "/World/Ball")
ball.CreateRadiusAttr(args.ball_radius)
r = args.ball_radius
ball.CreateExtentAttr([Gf.Vec3f(-r, -r, -r), Gf.Vec3f(r, r, r)])
UsdGeom.Xformable(ball).AddTranslateOp().Set(Gf.Vec3d(*args.ball_start))
UsdShade.MaterialBindingAPI.Apply(ball.GetPrim()).Bind(steel)
body = UsdPhysics.RigidBodyAPI.Apply(ball.GetPrim())
body.CreateVelocityAttr().Set(Gf.Vec3f(*args.ball_velocity))
UsdPhysics.CollisionAPI.Apply(ball.GetPrim())
UsdPhysics.MassAPI.Apply(ball.GetPrim()).CreateDensityAttr().Set(args.ball_density)
stage.GetRootLayer().Save()
print(f"{len(chunks)} chunks, {bonds} bonds, a {4 / 3 * math.pi * r ** 3 * args.ball_density:.0f} kg ball -> {args.scene}")
