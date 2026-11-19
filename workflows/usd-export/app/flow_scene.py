"""One design's flow in 3D, animated: <stage-dir>/flow.usda.

The airfoil becomes a wing section mounted on a wall, colored by its pressure
coefficient; streamtubes colored by speed run past it across the span; tracer particles
ride the solved velocity field in an 8 second loop; the wall behind is dark or a field
slice (velocity, pressure or eddy viscosity, switched by the "wall" variant on /World). The
openfoam-naca cases are two-dimensional, one cell across the span, so every span station
sees the same flow: the tubes and particles are the mid-plane solution placed at several
stations, and a particle moves at the local solved speed, slowed so that one chord at
the freestream speed takes FLOW["seconds_per_chord"] seconds.

The scene is Y up (lift up, span along z), unlike study.usda. flow.usda is small (lights,
the time range, the view and autoplay hints that the desktop's stage-follow reads) and
sublayers flow/<design>-<hash>.usdc, which holds the geometry and the particle samples.
"""

import math
import os

import numpy as np
from vtkmodules.util.numpy_support import vtk_to_numpy
import vtkmodules.vtkCommonCore as cc
import vtkmodules.vtkCommonDataModel as dm
import vtkmodules.vtkFiltersCore as fc
import vtkmodules.vtkFiltersFlowPaths as fp
import vtkmodules.vtkFiltersSources as fsrc
from pxr import Gf, Sdf, Usd, UsdGeom, UsdLux, UsdShade, Vt

import export_usd as ex

FLOW = {
    "wall_z": -0.85,             # the wall the wing is mounted on
    "tip_z": 0.80,               # the wing's free end
    "seeds": 36,                 # streamlines traced from upstream
    "seed_half_height": 0.55,    # seeds span this far either side of the freestream line
    "tube_z": (-0.45, 0.30),
    "tube_every": 3,             # every third seed gets a tube at each tube station
    "tube_radius": 0.0045,
    "tube_sides": 8,
    "tube_step": 0.012,          # tube rings this far apart, in chords
    "particle_z": 3,             # particle paths per seed, at random span stations
    "slots": 16,                 # particles per path over one loop
    "fps": 24,
    "seconds": 8.0,
    "seconds_per_chord": 1.2,
    "particle_width": 0.012,
    "color_bands": 16,           # tracer colors: the speed colormap in this many bands
    "wall_rgb": (0.02, 0.022, 0.026),
    "wall_top": 1.75,            # the wall reaches above the field box, for the label and legends
}

# The flow view's own color ranges, narrower than the study's so one design's flow uses
# the whole colormap; its legends are written beside the scene
SPECS = {
    "velocity": {"title": "Speed / freestream", "range": (0.6, 1.4), "map": "turbo"},
    "pressure": {"title": "Pressure coefficient Cp", "range": (-1.5, 1.0), "map": "coolwarm", "center": 0.0},
    "turbulence": dict(ex.FIELDS["turbulence"]),
}


def traced(mesh, alpha):
    """Streamlines on the mid plane from seeds upstream across the freestream line, more
    of them near the airfoil: (points [n, 2], speed [n]) per line, clipped to BOX."""
    _, z = ex.mid_plane(mesh)
    x0 = ex.BOX[0] + 0.05
    slope = math.tan(alpha)
    s = np.linspace(-1.0, 1.0, FLOW["seeds"])
    ys = FLOW["seed_half_height"] * np.sign(s) * np.abs(s) ** 1.4 + x0 * slope
    seeds = dm.vtkPolyData()
    points = cc.vtkPoints()
    for y in ys:
        points.InsertNextPoint(x0, float(y), z)
    seeds.SetPoints(points)
    tracer = fp.vtkStreamTracer()
    tracer.SetInputData(mesh)
    tracer.SetSourceData(seeds)
    tracer.SetInputArrayToProcess(0, 0, 0, dm.vtkDataObject.FIELD_ASSOCIATION_POINTS, "U")
    tracer.SetIntegratorTypeToRungeKutta45()
    tracer.SetIntegrationDirectionToForward()
    tracer.SetMaximumPropagation(10.0)
    tracer.SetInitialIntegrationStep(0.05)
    tracer.SetMaximumNumberOfSteps(20000)
    clip = fc.vtkClipPolyData()
    clip.SetInputConnection(tracer.GetOutputPort())
    clip.SetClipFunction(ex.box_function(z - 1, z + 1))
    clip.InsideOutOn()
    strip = fc.vtkStripper()
    strip.SetInputConnection(clip.GetOutputPort())
    strip.JoinContiguousSegmentsOn()
    strip.Update()
    out = strip.GetOutput()
    if out.GetNumberOfPoints() == 0:
        return []
    pts = vtk_to_numpy(out.GetPoints().GetData())[:, :2]
    u = vtk_to_numpy(out.GetPointData().GetArray("U"))
    lines = []
    cells = out.GetLines()
    cells.InitTraversal()
    ids = cc.vtkIdList()
    while cells.GetNextCell(ids):
        idx = [ids.GetId(i) for i in range(ids.GetNumberOfIds())]
        if len(idx) >= 8:
            lines.append((pts[idx], np.linalg.norm(u[idx], axis=1)))
    return lines


def resample(points, speed, step):
    """The line at even arc-length spacing, its speed, and the cumulative time a particle
    moving at the local speed takes to get to each point (chord lengths over the speed's
    units; times the freestream speed, it is in chords traveled at the freestream)."""
    seg = np.linalg.norm(np.diff(points, axis=0), axis=1)
    keep = np.concatenate([[True], seg > 1e-9])
    points, speed = points[keep], speed[keep]
    s = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))])
    if s[-1] <= step:
        return None
    grid = np.arange(0.0, s[-1], step)
    xy = np.column_stack([np.interp(grid, s, points[:, 0]), np.interp(grid, s, points[:, 1])])
    v = np.maximum(np.interp(grid, s, speed), 1e-3)
    dt = np.diff(grid) / (0.5 * (v[1:] + v[:-1]))
    return xy, v, np.concatenate([[0.0], np.cumsum(dt)])


def speed_coord(v, uinf):
    lo, hi = SPECS["velocity"]["range"]
    return np.clip((v / uinf - lo) / (hi - lo), 0.002, 0.998)


def tubes(lines, uinf):
    """Tube meshes around the lines at each tube station: points, normals, st (speed on u),
    face counts and indices, faces wound outward."""
    k = FLOW["tube_sides"]
    theta = 2 * math.pi * np.arange(k) / k
    pts, nrm, st, faces = [], [], [], []
    base = 0
    for z in FLOW["tube_z"]:
        for xy, v, _ in lines[::FLOW["tube_every"]]:
            n = len(xy)
            t = np.gradient(xy, axis=0)
            t /= np.maximum(np.linalg.norm(t, axis=1)[:, None], 1e-12)
            n1 = np.column_stack([-t[:, 1], t[:, 0], np.zeros(n)])
            ring = np.cos(theta)[None, :, None] * n1[:, None, :] + \
                np.sin(theta)[None, :, None] * np.array([0.0, 0.0, 1.0])[None, None, :]
            center = np.column_stack([xy, np.full(n, z)])
            pts.append((center[:, None, :] + FLOW["tube_radius"] * ring).reshape(-1, 3))
            nrm.append(ring.reshape(-1, 3))
            u = np.repeat(speed_coord(v, uinf), k)
            st.append(np.column_stack([u, np.full(n * k, 0.5)]))
            i = np.arange(n - 1)[:, None]
            j = np.arange(k)[None, :]
            a = base + i * k + j
            b = base + i * k + (j + 1) % k
            c = base + (i + 1) * k + (j + 1) % k
            d = base + (i + 1) * k + j
            faces.append(np.stack([a, b, c, d], axis=-1).reshape(-1))
            base += n * k
    faces = np.concatenate(faces).astype(np.int32)
    return np.vstack(pts), np.vstack(nrm), np.vstack(st), faces


def particles(lines, uinf, rng):
    """Particle positions, alive flags and speed coordinates per frame. Each path is a
    line placed at a span station; its slots are released one period apart (with a
    random phase), so the loop is seamless, and a particle past the end of its line is
    not alive."""
    frames = int(round(FLOW["fps"] * FLOW["seconds"]))
    loop = FLOW["seconds"]
    period = loop / FLOW["slots"]
    tau = np.arange(frames) / FLOW["fps"]
    span = (FLOW["wall_z"] + 0.03, FLOW["tip_z"] + 0.12)
    pos, wid, st = [], [], []
    for xy, v, travel in lines:
        anim = travel * uinf * FLOW["seconds_per_chord"]
        for _ in range(FLOW["particle_z"]):
            z = rng.uniform(*span)
            phase = rng.uniform(0, period)
            age = (tau[:, None] - np.arange(FLOW["slots"])[None, :] * period - phase) % loop
            alive = age <= anim[-1]
            a = np.minimum(age, anim[-1])
            x = np.interp(a, anim, xy[:, 0])
            y = np.interp(a, anim, xy[:, 1])
            pos.append(np.stack([x, y, np.full_like(x, z)], axis=-1))
            wid.append(alive)
            st.append(speed_coord(np.interp(a, anim, v), uinf))
    pos = np.concatenate(pos, axis=1)
    wid = np.concatenate(wid, axis=1)
    st = np.concatenate(st, axis=1)
    return frames, pos.astype(np.float32), wid, st.astype(np.float32)


def wing(stage, path, contour, material_path, tip_material):
    """The section extruded from the wall to the tip, with smooth sides colored along the
    contour, and a flat tip cap of its own."""
    z0, z1 = FLOW["wall_z"], FLOW["tip_z"]
    n = len(contour)
    ring = np.vstack([contour, contour[:1]])
    area = 0.5 * np.sum(contour[:, 0] * np.roll(contour[:, 1], -1) - np.roll(contour[:, 0], -1) * contour[:, 1])
    tangent = np.gradient(np.vstack([contour[-1:], contour, contour[:1]]), axis=0)[1:-1]
    normal = np.column_stack([tangent[:, 1], -tangent[:, 0]]) * (1 if area > 0 else -1)
    normal /= np.maximum(np.linalg.norm(normal, axis=1)[:, None], 1e-12)
    normal = np.vstack([normal, normal[:1]])
    points = np.vstack([np.column_stack([ring, np.full(n + 1, z0)]), np.column_stack([ring, np.full(n + 1, z1)])])
    normals = np.vstack([np.column_stack([normal, np.zeros(n + 1)])] * 2)
    if area > 0:
        faces = [q for i in range(n) for q in (i, i + 1, n + 2 + i, n + 1 + i)]
    else:
        faces = [q for i in range(n) for q in (i, n + 1 + i, n + 2 + i, i + 1)]
    u = (np.arange(n + 1) + 0.5) / (n + 1)
    st = np.vstack([np.column_stack([u, np.full(n + 1, 0.5)])] * 2)
    mesh = UsdGeom.Mesh.Define(stage, path)
    mesh.CreatePointsAttr(ex.vec3(points))
    mesh.CreateFaceVertexCountsAttr([4] * n)
    mesh.CreateFaceVertexIndicesAttr(faces)
    mesh.CreateNormalsAttr(ex.vec3(normals))
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    mesh.CreateExtentAttr(ex.extent(points))
    UsdGeom.PrimvarsAPI(mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray,
                                            UsdGeom.Tokens.vertex).Set(Vt.Vec2fArray.FromNumpy(st.astype(np.float32)))
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(UsdShade.Material(stage.GetPrimAtPath(material_path)))

    tris = ex.triangulate(contour)
    cap = np.column_stack([contour, np.full(n, z1)])
    tip = UsdGeom.Mesh.Define(stage, path + "Tip")
    tip.CreatePointsAttr(ex.vec3(cap))
    tip.CreateFaceVertexCountsAttr([3] * (len(tris) // 3))
    tip.CreateFaceVertexIndicesAttr(tris)
    tip.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    tip.CreateDoubleSidedAttr(True)
    tip.CreateExtentAttr(ex.extent(cap))
    UsdShade.MaterialBindingAPI.Apply(tip.GetPrim()).Bind(tip_material)
    return mesh


def write_flow(stage_dir, prim, design_id, case_dir, data, params, results, label_image, mesh=None):
    """Writes flow/<prim>-<hash>.usdc and flow.usda for one design and returns the data
    layer's name. data is read_case's result; mesh is the solver's mesh, read again when
    not given."""
    flow_dir = os.path.join(stage_dir, "flow")
    os.makedirs(flow_dir, exist_ok=True)
    if mesh is None:
        mesh, _, _ = ex.read_foam(os.path.join(case_dir, "case", "case.foam"))
    uinf = data["uinf"]
    alpha = math.radians(params.get("angle_of_attack", 0.0))
    rng = np.random.default_rng(7)
    lines = [r for r in (resample(p, v, FLOW["tube_step"]) for p, v in traced(mesh, alpha)) if r is not None]
    if not lines:
        raise RuntimeError(f"{case_dir}: no streamlines through the field")

    # Images: the field slices, the speed colormap, the airfoil's Cp strip
    images = {}
    for name, spec in SPECS.items():
        images[name] = ex.save_png(flow_dir, name,
                                   ex.colormap(spec["map"], data["images"][name], *spec["range"], linear=False,
                                               center=spec.get("center"))[::-1])
        images["legend-" + name] = ex.write_legend(flow_dir, "legend-" + name, spec)
    speed = SPECS["velocity"]
    ramp = ex.colormap(speed["map"], np.linspace(*speed["range"], 512), *speed["range"], linear=False)
    images["speed"] = ex.save_png(flow_dir, "speed", np.repeat(ramp[np.newaxis], 4, axis=0))
    cp = SPECS["pressure"]
    strip = ex.colormap(cp["map"], np.concatenate([data["cp_wall"], data["cp_wall"][:1]]),
                        *cp["range"], linear=False, center=cp["center"])
    images["airfoil"] = ex.save_png(flow_dir, "airfoil", np.repeat(strip[np.newaxis], 8, axis=0))

    frames, ppos, pwid, pst = particles(lines, uinf, rng)
    tpts, tnrm, tst, tfaces = tubes(lines, uinf)

    tmp = os.path.join(flow_dir, f".{prim}.tmp.usdc")
    if os.path.exists(tmp):
        os.remove(tmp)
    stage = Usd.Stage.CreateNew(tmp)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    stage.SetStartTimeCode(0)
    stage.SetEndTimeCode(frames - 1)
    stage.SetTimeCodesPerSecond(FLOW["fps"])
    stage.SetFramesPerSecond(FLOW["fps"])
    world = UsdGeom.Xform.Define(stage, "/World")
    stage.SetDefaultPrim(world.GetPrim())
    info = {"design": design_id, "freestream_speed": float(uinf)}
    info.update({k: float(v) for k, v in params.items()})
    info.update({k: float(v) for k, v in results.items()})
    world.GetPrim().SetCustomData(info)
    looks = Sdf.Path("/World/Looks")
    field_looks = {name: ex.texture_material(stage, looks.AppendChild("Wall_" + name), "./" + images[name],
                                             emission=0.8)
                   for name in SPECS}
    plain = UsdShade.Material.Define(stage, looks.AppendChild("Wall_none"))
    shader = UsdShade.Shader.Define(stage, plain.GetPath().AppendChild("Surface"))
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*FLOW["wall_rgb"]))
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.7)
    plain.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    ex.texture_material(stage, looks.AppendChild("Airfoil"), "./" + images["airfoil"], diffuse=True, emission=0.35)
    speed_look = ex.texture_material(stage, looks.AppendChild("Speed"), "./" + images["speed"], diffuse=True,
                                     emission=0.6)

    tip_look = UsdShade.Material.Define(stage, looks.AppendChild("Tip"))
    tip_shader = UsdShade.Shader.Define(stage, tip_look.GetPath().AppendChild("Surface"))
    tip_shader.CreateIdAttr("UsdPreviewSurface")
    tip_shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(0.55, 0.57, 0.6))
    tip_shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.5)
    tip_look.CreateSurfaceOutput().ConnectToSource(tip_shader.ConnectableAPI(), "surface")
    UsdGeom.Xform.Define(stage, "/World/Model")
    wing(stage, "/World/Model/Wing", data["contour"], looks.AppendChild("Airfoil"), tip_look)

    tube_mesh = UsdGeom.Mesh.Define(stage, "/World/Streamtubes")
    tube_mesh.CreatePointsAttr(ex.vec3(tpts))
    tube_mesh.CreateFaceVertexCountsAttr(Vt.IntArray.FromNumpy(np.full(len(tfaces) // 4, 4, dtype=np.int32)))
    tube_mesh.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(tfaces))
    tube_mesh.CreateNormalsAttr(ex.vec3(tnrm))
    tube_mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    tube_mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    tube_mesh.CreateExtentAttr(ex.extent(tpts))
    UsdGeom.PrimvarsAPI(tube_mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex) \
        .Set(Vt.Vec2fArray.FromNumpy(tst.astype(np.float32)))
    UsdShade.MaterialBindingAPI.Apply(tube_mesh.GetPrim()).Bind(speed_look)

    # Tracers: a point instancer of small spheres, one prototype per band of the speed
    # colormap (RTX draws a Points prim's spheres with texture coordinates of its own, so
    # a per-point color has to be a prototype); each frame sets the positions, the band of
    # every particle and the ones hidden because they are past the end of their line
    bands = FLOW["color_bands"]
    tracers = UsdGeom.PointInstancer.Define(stage, "/World/Tracers")
    protos = UsdGeom.Scope.Define(stage, "/World/Tracers/Prototypes")
    colors = ex.colormap(speed["map"], (np.arange(bands) + 0.5) / bands, 0.0, 1.0)
    targets = []
    for b in range(bands):
        look = UsdShade.Material.Define(stage, looks.AppendChild(f"Tracer_{b:02d}"))
        shader = UsdShade.Shader.Define(stage, look.GetPath().AppendChild("Surface"))
        shader.CreateIdAttr("UsdPreviewSurface")
        rgb = Gf.Vec3f(*map(float, colors[b]))
        shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(rgb)
        shader.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).Set(rgb * 0.6)
        shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.4)
        look.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
        sphere = UsdGeom.Sphere.Define(stage, protos.GetPath().AppendChild(f"Band_{b:02d}"))
        sphere.CreateRadiusAttr(FLOW["particle_width"] / 2)
        sphere.CreateExtentAttr([Gf.Vec3f(-FLOW["particle_width"] / 2), Gf.Vec3f(FLOW["particle_width"] / 2)])
        UsdShade.MaterialBindingAPI.Apply(sphere.GetPrim()).Bind(look)
        targets.append(sphere.GetPath())
    tracers.CreatePrototypesRel().SetTargets(targets)
    count = ppos.shape[1]
    tracers.CreateIdsAttr(Vt.Int64Array.FromNumpy(np.arange(count, dtype=np.int64)))
    pos_attr = tracers.CreatePositionsAttr()
    idx_attr = tracers.CreateProtoIndicesAttr()
    hide_attr = tracers.CreateInvisibleIdsAttr()
    band = np.minimum((pst * bands).astype(np.int32), bands - 1)
    for f in range(frames):
        pos_attr.Set(Vt.Vec3fArray.FromNumpy(ppos[f]), f)
        idx_attr.Set(Vt.IntArray.FromNumpy(band[f]), f)
        hide_attr.Set(Vt.Int64Array.FromNumpy(np.nonzero(~pwid[f])[0].astype(np.int64)), f)
    lo = ppos.reshape(-1, 3).min(axis=0) - FLOW["particle_width"]
    hi = ppos.reshape(-1, 3).max(axis=0) + FLOW["particle_width"]
    tracers.CreateExtentAttr([Gf.Vec3f(*map(float, lo)), Gf.Vec3f(*map(float, hi))])
    # Omniverse RTX's own primvar: the particles and tubes cast no shadows on the wing
    for gprim in [tube_mesh.GetPrim()] + [stage.GetPrimAtPath(t) for t in targets]:
        UsdGeom.PrimvarsAPI(gprim).CreatePrimvar("doNotCastShadows", Sdf.ValueTypeNames.Bool,
                                                UsdGeom.Tokens.constant).Set(True)

    # The wall the wing is mounted on: dark, or a field slice over BOX (the "wall"
    # variant); above the field, the design's label and the legends
    wall_z = FLOW["wall_z"]
    ex.quad(stage, "/World/Backdrop", ex.BOX[0], ex.BOX[2], ex.BOX[1], FLOW["wall_top"], wall_z - 0.002,
            plain).CreateDoubleSidedAttr(True)
    wall = ex.quad(stage, "/World/Wall", ex.BOX[0], ex.BOX[2], ex.BOX[1], ex.BOX[3], wall_z, plain)
    wall.CreateDoubleSidedAttr(True)
    y0 = ex.BOX[3] + 0.06
    if label_image:
        ex.quad(stage, "/World/Label", ex.BOX[0], y0, ex.BOX[1], y0 + ex.LABEL_H, wall_z,
                ex.texture_material(stage, looks.AppendChild("Label"), label_image))
    y0 += ex.LABEL_H + 0.04
    gap = 0.06
    width = (ex.BOX[1] - ex.BOX[0] - 2 * gap) / 3
    height = width * 260 / 1600
    UsdGeom.Xform.Define(stage, "/World/Legend")
    for k, name in enumerate(SPECS):
        x0 = ex.BOX[0] + k * (width + gap)
        ex.quad(stage, "/World/Legend/" + name, x0, y0, x0 + width, y0 + height, wall_z,
                ex.texture_material(stage, looks.AppendChild("Legend_" + name), "./" + images["legend-" + name]))

    # What the wall shows: nothing (dark), or a field slice
    vset = world.GetPrim().GetVariantSets().AddVariantSet("wall")
    for name in ("none",) + tuple(ex.FIELDS):
        vset.AddVariant(name)
        vset.SetVariantSelection(name)
        with vset.GetVariantEditContext():
            UsdShade.MaterialBindingAPI.Apply(stage.OverridePrim("/World/Wall")).GetDirectBindingRel().SetTargets(
                [looks.AppendChild("Wall_" + name)])
    vset.SetVariantSelection("none")
    stage.GetRootLayer().Save()
    del stage

    with open(tmp, "rb") as handle:
        import hashlib
        digest = hashlib.sha1(handle.read()).hexdigest()[:12]
    name = f"{prim}-{digest}.usdc"
    os.replace(tmp, os.path.join(flow_dir, name))
    write_root(stage_dir, name, frames, design_id)
    for old in os.listdir(flow_dir):
        if old.endswith(".usdc") and old != name:
            os.remove(os.path.join(flow_dir, old))
    return name


def write_root(stage_dir, data_layer, frames, design_id):
    """flow.usda: the lights, the time range and the desktop's hints, over the data layer."""
    tmp = os.path.join(stage_dir, ".flow.tmp.usda")
    if os.path.exists(tmp):
        os.remove(tmp)
    layer = Sdf.Layer.CreateNew(tmp)
    layer.subLayerPaths.append("./flow/" + data_layer)
    stage = Usd.Stage.Open(layer)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    stage.SetStartTimeCode(0)
    stage.SetEndTimeCode(frames - 1)
    stage.SetTimeCodesPerSecond(FLOW["fps"])
    stage.SetFramesPerSecond(FLOW["fps"])
    stage.SetDefaultPrim(stage.OverridePrim("/World"))
    layer.customLayerData = {
        "exported_by": "usd-export",
        "design": design_id,
        "pw:view": {"eye": Gf.Vec3d(-0.72, 1.3, 2.95), "target": Gf.Vec3d(0.75, 0.42, -0.45)},
        "pw:play": True,
    }
    lights = UsdGeom.Scope.Define(stage, "/World/Lights")
    dome = UsdLux.DomeLight.Define(stage, lights.GetPath().AppendChild("Dome"))
    dome.CreateIntensityAttr(300.0)
    dome.CreateColorAttr(Gf.Vec3f(0.26, 0.28, 0.32))
    key = UsdLux.DistantLight.Define(stage, lights.GetPath().AppendChild("Key"))
    key.CreateIntensityAttr(3000.0)
    key.CreateAngleAttr(2.0)
    UsdGeom.XformCommonAPI(key).SetRotate(Gf.Vec3f(-45, -30, 0))

    layer.Save()
    os.replace(tmp, os.path.join(stage_dir, "flow.usda"))
