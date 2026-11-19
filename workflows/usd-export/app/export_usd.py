"""Exports solved openfoam-naca cases to an OpenUSD stage the Omniverse desktop follows.

    python export_usd.py --source DIR --stage-dir DIR [--format F] [--columns N] [--follow-minutes M]

Every case directory under DIR (a directory holding case/case.foam, as openfoam-naca,
doe-openfoam and dakota-openfoam leave them) that has a results.out becomes one design
file, <stage-dir>/designs/<id>.usdc: the flow on the mid plane around the airfoil (the
solver's points, with velocity, pressure and eddy viscosity as primvars, colored by
textures resampled from the fields), the airfoil extruded across the plane and colored
by its pressure coefficient, streamlines seeded upstream, and a label with the design
and its coefficients. <stage-dir>/study.usda references every design on a grid in the
order they arrived, with a legend, lights and a "field" variant set on /World that
switches the field every design shows. The study is
rewritten whole after each new design, under a lock, so a desktop that reloads it on
change shows designs as they are exported.

With --follow-minutes M the export keeps scanning DIR for cases that finish, and stops
when none has finished for M minutes or, for a doe-openfoam study, when its results.csv
exists and every case has finished. Values are the raw fields of the last time step
plus their colors; colors use fixed ranges scaled by the freestream, so designs compare.
"""

import argparse
import fcntl
import glob
import hashlib
import io
import json
import math
import os
import re
import sys
import time

import numpy as np
from vtkmodules.util.numpy_support import vtk_to_numpy
import vtkmodules.vtkCommonCore as cc
import vtkmodules.vtkCommonDataModel as dm
import vtkmodules.vtkCommonExecutionModel as em
import vtkmodules.vtkFiltersCore as fc
import vtkmodules.vtkFiltersFlowPaths as fp
import vtkmodules.vtkFiltersGeneral as fg
import vtkmodules.vtkFiltersSources as fsrc
import vtkmodules.vtkIOGeometry as iog
from pxr import Gf, Kind, Sdf, Usd, UsdGeom, UsdLux, UsdShade, Vt

# The plane around the airfoil that every design shows, in chords
BOX = (-0.6, 2.4, -0.9, 0.9)
GAP = (0.7, 0.9)
SPAN = 0.5
LABEL_H = 0.30
SEEDS = 16
TEX_W = 2048
NU_DEFAULT = 1e-5
UINF_DEFAULT = 10.0

FIELDS = {
    "velocity": {"title": "Velocity magnitude / freestream", "range": (0.0, 1.6), "map": "turbo"},
    "pressure": {"title": "Pressure coefficient Cp", "range": (-2.5, 1.0), "map": "coolwarm", "center": 0.0},
    "turbulence": {"title": "Eddy viscosity ratio, log10(nut / nu)", "range": (-1.0, 3.0), "map": "viridis"},
}

# Colormap control points in sRGB
MAPS = {
    "turbo": [(0.190, 0.072, 0.232), (0.276, 0.421, 0.891), (0.158, 0.736, 0.923), (0.197, 0.949, 0.595),
              (0.644, 0.990, 0.234), (0.948, 0.837, 0.213), (0.981, 0.501, 0.128), (0.857, 0.199, 0.025),
              (0.480, 0.016, 0.011)],
    "coolwarm": [(0.230, 0.299, 0.754), (0.406, 0.537, 0.934), (0.602, 0.731, 0.999), (0.788, 0.845, 0.939),
                 (0.930, 0.820, 0.761), (0.967, 0.657, 0.537), (0.887, 0.413, 0.324), (0.706, 0.016, 0.150)],
    "viridis": [(0.267, 0.005, 0.329), (0.283, 0.141, 0.458), (0.254, 0.265, 0.530), (0.207, 0.372, 0.553),
                (0.164, 0.471, 0.558), (0.128, 0.567, 0.551), (0.135, 0.659, 0.518), (0.267, 0.749, 0.441),
                (0.478, 0.821, 0.318), (0.741, 0.873, 0.150), (0.993, 0.906, 0.144)],
}


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def to_linear(srgb):
    srgb = np.asarray(srgb, dtype=np.float64)
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


def normalize(values, lo, hi, center=None):
    """Positions on the color map for values on [lo, hi], clamped. With a center, each side
    of it fills half the map, so a diverging map shows the center (Cp = 0, the
    freestream) as its neutral middle on an asymmetric range."""
    v = np.asarray(values, dtype=np.float64)
    if center is None:
        t = (v - lo) / (hi - lo)
    else:
        t = np.where(v < center, 0.5 * (v - lo) / (center - lo), 0.5 + 0.5 * (v - center) / (hi - center))
    return np.clip(t, 0.0, 1.0)


def colormap(name, values, lo, hi, linear=True, center=None):
    """Colors for values on [lo, hi] (clamped), linear RGB for USD, sRGB for images."""
    table = np.asarray(MAPS[name])
    t = normalize(values, lo, hi, center)
    x = np.linspace(0.0, 1.0, len(table))
    rgb = np.stack([np.interp(t, x, table[:, k]) for k in range(3)], axis=-1)
    return to_linear(rgb) if linear else rgb


def prim_name(text):
    name = re.sub(r"[^A-Za-z0-9_]", "_", text).strip("_") or "design"
    return name if not name[0].isdigit() else "d_" + name


# Reading a case

def read_pairs(path):
    """'<value> <name>' lines (params.in, results.out) as a dict of floats."""
    values = {}
    if os.path.isfile(path):
        for line in open(path):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    values[parts[1]] = float(parts[0])
                except ValueError:
                    pass
    return values


def freestream(case_root):
    """|U| of the uniform initial field and nu, from the case files."""
    uinf, nu = UINF_DEFAULT, NU_DEFAULT
    try:
        text = open(os.path.join(case_root, "0", "U")).read()
        match = re.search(r"internalField\s+uniform\s+\(\s*([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s*\)", text)
        if match:
            uinf = math.sqrt(sum(float(v) ** 2 for v in match.groups())) or UINF_DEFAULT
    except OSError:
        pass
    try:
        text = open(os.path.join(case_root, "constant", "transportProperties")).read()
        match = re.search(r"^\s*nu\s+(?:\[[^\]]*\]\s*)?([-\d.eE+]+)\s*;", text, re.M)
        if match:
            nu = float(match.group(1))
    except OSError:
        pass
    return uinf, nu


def blocks(data):
    """Leaf datasets of the reader's output by name."""
    found = {}
    it = data.NewTreeIterator()
    it.VisitOnlyLeavesOn()
    it.InitTraversal()
    while not it.IsDoneWithTraversal():
        name = it.GetCurrentMetaData().Get(dm.vtkCompositeDataSet.NAME())
        found[name] = it.GetCurrentDataObject()
        it.GoToNextItem()
    return found


def read_foam(foam):
    reader = iog.vtkOpenFOAMReader()
    reader.SetFileName(foam)
    reader.UpdateInformation()
    reader.CreateCellToPointOn()
    reader.EnableAllCellArrays()
    patches = [reader.GetPatchArrayName(i) for i in range(reader.GetNumberOfPatchArrays())]
    walls = [p for p in patches if p.split("/")[-1] == "walls"]
    for patch in patches:
        reader.SetPatchArrayStatus(patch, int(patch == "internalMesh" or patch in walls))
    times = reader.GetTimeValues()
    if times is None or times.GetNumberOfTuples() == 0:
        raise RuntimeError(f"{foam}: no time steps")
    last = times.GetValue(times.GetNumberOfTuples() - 1)
    reader.UpdateTimeStep(last)
    reader.Update()
    found = blocks(reader.GetOutput())
    mesh = found.get("internalMesh")
    wall = found.get("walls")
    if mesh is None or wall is None:
        raise RuntimeError(f"{foam}: no internalMesh or walls patch (found {sorted(found)})")
    return mesh, wall, last


def box_function(z_lo, z_hi):
    box = dm.vtkBox()
    box.SetBounds(BOX[0], BOX[1], BOX[2], BOX[3], z_lo, z_hi)
    return box


def mid_plane(mesh):
    z = 0.5 * (mesh.GetBounds()[4] + mesh.GetBounds()[5])
    plane = dm.vtkPlane()
    plane.SetOrigin(0, 0, z)
    plane.SetNormal(0, 0, 1)
    return plane, z


def slice_mesh(mesh):
    plane, z = mid_plane(mesh)
    cut = fc.vtkCutter()
    cut.SetInputData(mesh)
    cut.SetCutFunction(plane)
    clip = fc.vtkClipPolyData()
    clip.SetInputConnection(cut.GetOutputPort())
    clip.SetClipFunction(box_function(z - 1, z + 1))
    clip.InsideOutOn()
    clean = fc.vtkCleanPolyData()
    clean.SetInputConnection(clip.GetOutputPort())
    clean.Update()
    return clean.GetOutput()


def airfoil_contour(wall, mesh):
    """The airfoil outline on the mid plane, ordered, with p at each point."""
    plane, _ = mid_plane(mesh)
    cut = fc.vtkCutter()
    cut.SetInputData(wall)
    cut.SetCutFunction(plane)
    strip = fc.vtkStripper()
    strip.SetInputConnection(cut.GetOutputPort())
    strip.JoinContiguousSegmentsOn()
    strip.Update()
    out = strip.GetOutput()
    pts = vtk_to_numpy(out.GetPoints().GetData())[:, :2]
    p = vtk_to_numpy(out.GetPointData().GetArray("p"))
    best = None
    lines = out.GetLines()
    lines.InitTraversal()
    ids = cc.vtkIdList()
    while lines.GetNextCell(ids):
        loop = [ids.GetId(i) for i in range(ids.GetNumberOfIds())]
        if best is None or len(loop) > len(best):
            best = loop
    if best is None:
        raise RuntimeError("the walls patch has no outline on the mid plane")
    if best[0] == best[-1]:
        best = best[:-1]
    return pts[best], p[best]


def streamlines(mesh, uinf_dir):
    _, z = mid_plane(mesh)
    seeds = fsrc.vtkLineSource()
    x0 = BOX[0] + 0.15
    seeds.SetPoint1(x0, -0.55 + x0 * uinf_dir[1] / max(uinf_dir[0], 1e-6), z)
    seeds.SetPoint2(x0, 0.55 + x0 * uinf_dir[1] / max(uinf_dir[0], 1e-6), z)
    seeds.SetResolution(SEEDS - 1)
    tracer = fp.vtkStreamTracer()
    tracer.SetInputData(mesh)
    tracer.SetSourceConnection(seeds.GetOutputPort())
    tracer.SetInputArrayToProcess(0, 0, 0, dm.vtkDataObject.FIELD_ASSOCIATION_POINTS, "U")
    tracer.SetIntegratorTypeToRungeKutta45()
    tracer.SetIntegrationDirectionToForward()
    tracer.SetMaximumPropagation(8.0)
    tracer.SetInitialIntegrationStep(0.1)
    tracer.SetMaximumNumberOfSteps(6000)
    clip = fc.vtkClipPolyData()
    clip.SetInputConnection(tracer.GetOutputPort())
    clip.SetClipFunction(box_function(z - 1, z + 1))
    clip.InsideOutOn()
    strip = fc.vtkStripper()
    strip.SetInputConnection(clip.GetOutputPort())
    strip.JoinContiguousSegmentsOn()
    strip.Update()
    out = strip.GetOutput()
    if out.GetNumberOfPoints() == 0:
        return [], []
    pts = vtk_to_numpy(out.GetPoints().GetData())
    u = vtk_to_numpy(out.GetPointData().GetArray("U"))
    curves, speeds = [], []
    lines = out.GetLines()
    lines.InitTraversal()
    ids = cc.vtkIdList()
    while lines.GetNextCell(ids):
        idx = [ids.GetId(i) for i in range(ids.GetNumberOfIds())]
        if len(idx) >= 4:
            curves.append(pts[idx, :2])
            speeds.append(np.linalg.norm(u[idx], axis=1))
    return curves, speeds


def fill_invalid(values, valid, rounds=8):
    """Spreads valid pixels into the invalid ones next to them (the airfoil's inside),
    so the texture filtering at the wall does not blend in a placeholder color."""
    values = np.where(valid, values, 0.0)
    valid = valid.copy()
    for _ in range(rounds):
        total = np.zeros_like(values)
        count = np.zeros(values.shape)
        for axis, shift in ((0, 1), (0, -1), (1, 1), (1, -1)):
            total += np.roll(values * valid, shift, axis=axis)
            count += np.roll(valid, shift, axis=axis)
        grow = ~valid & (count > 0)
        values[grow] = total[grow] / count[grow]
        valid |= grow
    return values


def field_images(mesh, uinf, nu):
    """The fields resampled on a TEX_W-wide grid over BOX on the mid plane: one image of
    values per field, row 0 at the bottom of the box."""
    _, z = mid_plane(mesh)
    w = TEX_W
    h = int(round(TEX_W * (BOX[3] - BOX[2]) / (BOX[1] - BOX[0])))
    resample = fc.vtkResampleToImage()
    resample.SetInputDataObject(mesh)
    resample.UseInputBoundsOff()
    resample.SetSamplingBounds(BOX[0], BOX[1], BOX[2], BOX[3], z, z)
    resample.SetSamplingDimensions(w, h, 1)
    resample.Update()
    pd = resample.GetOutput().GetPointData()
    valid = vtk_to_numpy(pd.GetArray("vtkValidPointMask")).reshape(h, w).astype(bool)
    u = vtk_to_numpy(pd.GetArray("U")).reshape(h, w, 3)
    p = vtk_to_numpy(pd.GetArray("p")).reshape(h, w)
    nut = vtk_to_numpy(pd.GetArray("nut")).reshape(h, w) if pd.GetArray("nut") is not None else np.zeros((h, w))
    q = 0.5 * uinf * uinf
    return {
        "velocity": fill_invalid(np.linalg.norm(u, axis=2) / uinf, valid),
        "pressure": fill_invalid(p / q, valid),
        "turbulence": fill_invalid(np.log10(np.maximum(nut, 1e-12) / nu), valid),
    }


def polys(data):
    """Face vertex counts and indices of a polydata's polygons, every face wound
    counterclockwise seen from +z: the cutter leaves either winding, and the renderer
    shows a material's emission on the front face only."""
    conn = data.GetPolys()
    offsets = vtk_to_numpy(conn.GetOffsetsArray()).astype(np.int64)
    indices = vtk_to_numpy(conn.GetConnectivityArray()).astype(np.int32).copy()
    xy = vtk_to_numpy(data.GetPoints().GetData())[:, :2]
    counts = np.diff(offsets)
    nxt = np.arange(len(indices)) + 1
    nxt[offsets[1:] - 1] = offsets[:-1]
    a, b = xy[indices], xy[indices[nxt]]
    area = np.add.reduceat(a[:, 0] * b[:, 1] - b[:, 0] * a[:, 1], offsets[:-1])
    for f in np.nonzero(area < 0)[0]:
        indices[offsets[f]:offsets[f + 1]] = indices[offsets[f]:offsets[f + 1]][::-1].copy()
    return counts.astype(np.int32), indices


def read_case(case_dir):
    root = os.path.join(case_dir, "case")
    mesh, wall, last = read_foam(os.path.join(root, "case.foam"))
    uinf, nu = freestream(root)
    plane = slice_mesh(mesh)
    pts = vtk_to_numpy(plane.GetPoints().GetData())[:, :2]
    pd = plane.GetPointData()
    u = vtk_to_numpy(pd.GetArray("U"))
    p = vtk_to_numpy(pd.GetArray("p"))
    nut = vtk_to_numpy(pd.GetArray("nut")) if pd.GetArray("nut") is not None else np.zeros(len(p))
    counts, indices = polys(plane)
    contour, p_wall = airfoil_contour(wall, mesh)
    alpha = math.radians(read_pairs(os.path.join(case_dir, "params.in")).get("angle_of_attack", 0.0))
    curves, speeds = streamlines(mesh, (math.cos(alpha), math.sin(alpha)))
    q = 0.5 * uinf * uinf
    return {
        "time": last, "uinf": uinf, "nu": nu,
        "points": pts, "counts": counts, "indices": indices,
        "U": u, "p": p, "nut": nut,
        "scalars": {
            "velocity": np.linalg.norm(u, axis=1) / uinf,
            "pressure": p / q,
            "turbulence": np.log10(np.maximum(nut, 1e-12) / nu),
        },
        "images": field_images(mesh, uinf, nu),
        "contour": contour, "cp_wall": p_wall / q,
        "curves": curves, "speeds": [s / uinf for s in speeds],
    }


# Writing USD
#
# Colors reach the renderer as textures: Omniverse RTX shades a UsdPreviewSurface whose
# emissiveColor comes from a UsdUVTexture, and ignored a UsdPrimvarReader feeding it.
# The field planes and labels are emissive with ior 1 (no reflection), so they show the
# colormap's colors exactly and without sampling noise whatever the lighting.

def texture_material(stage, path, image, diffuse=False, emission=1.0):
    material = UsdShade.Material.Define(stage, path)
    shader = UsdShade.Shader.Define(stage, path.AppendChild("Surface"))
    shader.CreateIdAttr("UsdPreviewSurface")
    st = UsdShade.Shader.Define(stage, path.AppendChild("ST"))
    st.CreateIdAttr("UsdPrimvarReader_float2")
    st.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")
    tex = UsdShade.Shader.Define(stage, path.AppendChild("Image"))
    tex.CreateIdAttr("UsdUVTexture")
    tex.CreateInput("file", Sdf.ValueTypeNames.Asset).Set(image)
    tex.CreateInput("sourceColorSpace", Sdf.ValueTypeNames.Token).Set("sRGB")
    tex.CreateInput("wrapS", Sdf.ValueTypeNames.Token).Set("clamp")
    tex.CreateInput("wrapT", Sdf.ValueTypeNames.Token).Set("clamp")
    tex.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(st.ConnectableAPI(), "result")
    rgb = tex.CreateOutput("rgb", Sdf.ValueTypeNames.Float3)
    if diffuse:
        shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(rgb)
        shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.55)
    else:
        shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(0, 0, 0))
        shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(1.0)
        shader.CreateInput("ior", Sdf.ValueTypeNames.Float).Set(1.0)
    if emission > 0:
        if emission != 1.0:
            tex.CreateInput("scale", Sdf.ValueTypeNames.Float4).Set(Gf.Vec4f(emission, emission, emission, 1))
        shader.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(rgb)
    material.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    return material


def flat_material(stage, path, rgb):
    material = UsdShade.Material.Define(stage, path)
    shader = UsdShade.Shader.Define(stage, path.AppendChild("Surface"))
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(0, 0, 0))
    shader.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgb))
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(1.0)
    shader.CreateInput("ior", Sdf.ValueTypeNames.Float).Set(1.0)
    material.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    return material


def quad(stage, path, x0, y0, x1, y1, z, material):
    mesh = UsdGeom.Mesh.Define(stage, path)
    mesh.CreatePointsAttr([Gf.Vec3f(x0, y0, z), Gf.Vec3f(x1, y0, z), Gf.Vec3f(x1, y1, z), Gf.Vec3f(x0, y1, z)])
    mesh.CreateFaceVertexCountsAttr([4])
    mesh.CreateFaceVertexIndicesAttr([0, 1, 2, 3])
    mesh.CreateNormalsAttr([Gf.Vec3f(0, 0, 1)] * 4)
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    st = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
    st.Set([Gf.Vec2f(0, 0), Gf.Vec2f(1, 0), Gf.Vec2f(1, 1), Gf.Vec2f(0, 1)])
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
    mesh.CreateExtentAttr([Gf.Vec3f(x0, y0, z), Gf.Vec3f(x1, y1, z)])
    return mesh


def extent(points):
    lo, hi = points.min(axis=0), points.max(axis=0)
    return [Gf.Vec3f(*map(float, lo)), Gf.Vec3f(*map(float, hi))]


def vec3(points, z=0.0):
    if points.shape[1] == 2:
        points = np.column_stack([points, np.full(len(points), z)])
    return Vt.Vec3fArray.FromNumpy(np.ascontiguousarray(points, dtype=np.float32))


def triangulate(contour):
    """Triangles of the airfoil section (a simple polygon) by ear clipping, wound
    counterclockwise seen from +z."""
    pts = np.asarray(contour, dtype=np.float64)
    order = list(range(len(pts)))
    area = 0.5 * np.sum(pts[:, 0] * np.roll(pts[:, 1], -1) - np.roll(pts[:, 0], -1) * pts[:, 1])
    if area < 0:
        order.reverse()

    def cross(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    def inside(p, a, b, c):
        return cross(a, b, p) > 0 and cross(b, c, p) > 0 and cross(c, a, p) > 0

    tris = []
    guard = 0
    while len(order) > 3 and guard < 4 * len(pts) * len(pts):
        guard += 1
        n = len(order)
        for k in range(n):
            i, j, m = order[k - 1], order[k], order[(k + 1) % n]
            a, b, c = pts[i], pts[j], pts[m]
            if cross(a, b, c) <= 1e-14:
                continue
            if any(inside(pts[q], a, b, c) for q in order if q not in (i, j, m)):
                continue
            tris += [i, j, m]
            del order[k]
            break
        else:
            break
    if len(order) == 3:
        tris += order
    return tris


def publish_image(img, directory, stem):
    """Writes a PIL image as <directory>/<stem>-<hash>.png, named by its content, removes
    the stem's other versions and returns the file name. A renderer that has an image
    loaded never sees that file change: RTX keeps showing what it loaded when a texture
    is rewritten in place under a stage it reloads. A changed image is a new file, which
    the rewritten layer that names it brings in. Written to a temporary file and
    renamed, so a reader never sees part of one."""
    buffer = io.BytesIO()
    img.save(buffer, format="PNG")
    data = buffer.getvalue()
    name = f"{stem}-{hashlib.sha1(data).hexdigest()[:12]}.png"
    path = os.path.join(directory, name)
    if not os.path.isfile(path):
        tmp = os.path.join(directory, f".{name}.tmp")
        with open(tmp, "wb") as out:
            out.write(data)
        os.replace(tmp, path)
    for old in glob.glob(os.path.join(glob.escape(directory), glob.escape(stem) + "-*.png")) + \
            [os.path.join(directory, stem + ".png")]:
        if os.path.basename(old) != name and os.path.isfile(old):
            os.remove(old)
    return name


def save_png(directory, stem, rgb):
    from PIL import Image
    img = Image.fromarray(np.clip(np.round(np.asarray(rgb) * 255), 0, 255).astype(np.uint8))
    return publish_image(img, directory, stem)


def write_design(stage_dir, prim, design_id, data, params, results, label_image):
    """designs/<prim>.usdc and its textures under textures/<prim>/."""
    tex_dir = os.path.join(stage_dir, "textures", prim)
    os.makedirs(tex_dir, exist_ok=True)
    images = {}
    for name, spec in FIELDS.items():
        image = data["images"][name]
        images[name] = save_png(tex_dir, name, colormap(spec["map"], image, *spec["range"], linear=False,
                                                        center=spec.get("center"))[::-1])
    strip = colormap("coolwarm", np.concatenate([data["cp_wall"], data["cp_wall"][:1]]),
                     *FIELDS["pressure"]["range"], linear=False, center=FIELDS["pressure"]["center"])
    images["airfoil"] = save_png(tex_dir, "airfoil", np.repeat(strip[np.newaxis], 8, axis=0))

    path = os.path.join(stage_dir, "designs", "." + prim + ".tmp.usdc")
    if os.path.exists(path):
        os.remove(path)
    stage = Usd.Stage.CreateNew(path)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = UsdGeom.Xform.Define(stage, "/Design")
    stage.SetDefaultPrim(root.GetPrim())
    Usd.ModelAPI(root).SetKind(Kind.Tokens.component)
    info = {"design": design_id, "freestream_speed": float(data["uinf"]), "time": float(data["time"])}
    info.update({k: float(v) for k, v in params.items()})
    info.update({k: float(v) for k, v in results.items()})
    root.GetPrim().SetCustomData(info)

    looks = Sdf.Path("/Design/Looks")
    rel = f"../textures/{prim}/"
    field_looks = {name: texture_material(stage, looks.AppendChild("Field_" + name), rel + images[name])
                   for name in FIELDS}

    # The flow on the mid plane: the solver's points with the raw fields as primvars, the
    # colors from the resampled textures; /World's field variant switches the material
    pts = data["points"]
    mesh = UsdGeom.Mesh.Define(stage, "/Design/Field")
    mesh.CreatePointsAttr(vec3(pts))
    mesh.CreateFaceVertexCountsAttr(Vt.IntArray.FromNumpy(data["counts"]))
    mesh.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(data["indices"]))
    mesh.CreateNormalsAttr(Vt.Vec3fArray([Gf.Vec3f(0, 0, 1)] * len(pts)))
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    mesh.CreateDoubleSidedAttr(True)
    mesh.CreateExtentAttr(extent(np.column_stack([pts, np.zeros(len(pts))])))
    api = UsdGeom.PrimvarsAPI(mesh)
    st = np.column_stack([(pts[:, 0] - BOX[0]) / (BOX[1] - BOX[0]), (pts[:, 1] - BOX[2]) / (BOX[3] - BOX[2])])
    api.CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex).Set(
        Vt.Vec2fArray.FromNumpy(st.astype(np.float32)))
    for name in FIELDS:
        api.CreatePrimvar(name, Sdf.ValueTypeNames.FloatArray, UsdGeom.Tokens.vertex).Set(
            Vt.FloatArray.FromNumpy(data["scalars"][name].astype(np.float32)))
    api.CreatePrimvar("U", Sdf.ValueTypeNames.Vector3fArray, UsdGeom.Tokens.vertex).Set(
        Vt.Vec3fArray.FromNumpy(data["U"].astype(np.float32)))
    api.CreatePrimvar("p", Sdf.ValueTypeNames.FloatArray, UsdGeom.Tokens.vertex).Set(
        Vt.FloatArray.FromNumpy(data["p"].astype(np.float32)))
    api.CreatePrimvar("nut", Sdf.ValueTypeNames.FloatArray, UsdGeom.Tokens.vertex).Set(
        Vt.FloatArray.FromNumpy(data["nut"].astype(np.float32)))
    mesh.GetPrim().SetCustomData({"fields": {name: {"title": spec["title"], "range": Gf.Vec2d(*spec["range"]),
                                                    "colormap": spec["map"]} for name, spec in FIELDS.items()}})
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(field_looks["velocity"])

    # The airfoil: the section extruded across the plane, its sides colored by Cp
    contour = data["contour"]
    n = len(contour)
    lo = np.column_stack([contour, np.full(n, -SPAN / 2)])
    hi = np.column_stack([contour, np.full(n, SPAN / 2)])
    ring = np.vstack([contour, contour[:1]])
    lo_r = np.column_stack([ring, np.full(n + 1, -SPAN / 2)])
    hi_r = np.column_stack([ring, np.full(n + 1, SPAN / 2)])
    side_faces = [k for i in range(n) for k in (i, i + 1, n + 2 + i, n + 1 + i)]
    tris = triangulate(contour)
    base = 2 * (n + 1)
    cap_faces = [base + k for t in range(0, len(tris), 3) for k in (tris[t + 2], tris[t + 1], tris[t])]
    cap_faces += [base + n + k for k in tris]
    airfoil = UsdGeom.Mesh.Define(stage, "/Design/Airfoil")
    all_pts = np.vstack([lo_r, hi_r, lo, hi])
    airfoil.CreatePointsAttr(vec3(all_pts))
    airfoil.CreateFaceVertexCountsAttr([4] * n + [3] * (len(cap_faces) // 3))
    airfoil.CreateFaceVertexIndicesAttr(side_faces + cap_faces)
    airfoil.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    airfoil.CreateExtentAttr(extent(all_pts))
    u = (np.arange(n + 1) + 0.5) / (n + 1)
    st = np.vstack([np.column_stack([u, np.full(n + 1, 0.5)])] * 2 + [np.full((2 * n, 2), [0.0, 0.0])])
    UsdGeom.PrimvarsAPI(airfoil).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray,
                                               UsdGeom.Tokens.vertex).Set(Vt.Vec2fArray.FromNumpy(st.astype(np.float32)))
    UsdGeom.PrimvarsAPI(airfoil).CreatePrimvar("Cp", Sdf.ValueTypeNames.FloatArray, UsdGeom.Tokens.vertex).Set(
        Vt.FloatArray.FromNumpy(np.concatenate([data["cp_wall"], data["cp_wall"][:1]] * 2 +
                                               [np.zeros(2 * n)]).astype(np.float32)))
    UsdShade.MaterialBindingAPI.Apply(airfoil.GetPrim()).Bind(
        texture_material(stage, looks.AppendChild("Airfoil"), rel + images["airfoil"], diffuse=True, emission=0.5))

    # Streamlines just above the plane
    if data["curves"]:
        curves = UsdGeom.BasisCurves.Define(stage, "/Design/Streamlines")
        curves.CreateTypeAttr(UsdGeom.Tokens.linear)
        curves.CreateCurveVertexCountsAttr([len(c) for c in data["curves"]])
        cpts = np.vstack(data["curves"])
        curves.CreatePointsAttr(vec3(cpts, z=0.004))
        curves.CreateWidthsAttr(Vt.FloatArray([0.007]))
        curves.SetWidthsInterpolation(UsdGeom.Tokens.constant)
        curves.CreateExtentAttr(extent(np.column_stack([cpts, np.full(len(cpts), 0.004)])))
        curves.CreateDisplayColorPrimvar(UsdGeom.Tokens.constant).Set([Gf.Vec3f(0.92, 0.93, 0.95)])
        UsdShade.MaterialBindingAPI.Apply(curves.GetPrim()).Bind(
            flat_material(stage, looks.AppendChild("Streamlines"), (0.92, 0.93, 0.95)))

    if label_image:
        quad(stage, "/Design/Label", BOX[0], BOX[3] + 0.04, BOX[1], BOX[3] + 0.04 + LABEL_H, 0.0,
             texture_material(stage, looks.AppendChild("Label"), label_image))
    stage.GetRootLayer().Save()
    final = os.path.join(stage_dir, "designs", prim + ".usdc")
    os.replace(path, final)
    return os.path.relpath(final, stage_dir)


# Labels and legend as images

def font(size):
    from PIL import ImageFont
    for name in ("DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default(size=size)


def naca_name(params):
    try:
        m = round(params["max_camber"] * 100)
        p = round(params["camber_position"] * 10) if m else 0
        t = round(params["thickness"] * 100)
        return f"NACA {m}{p}{t:02d}"
    except KeyError:
        return "NACA"


def write_label(directory, stem, design_id, params, results):
    from PIL import Image, ImageDraw
    w = 1600
    h = int(w * LABEL_H / (BOX[1] - BOX[0]))
    img = Image.new("RGB", (w, h), (24, 26, 30))
    draw = ImageDraw.Draw(img)
    cd = results.get("drag_coefficient")
    cl = -results["neg_lift_coefficient"] if "neg_lift_coefficient" in results else None
    alpha = params.get("angle_of_attack")
    head = naca_name(params) + (f" at {alpha:.1f} deg" if alpha is not None else "")
    tail = "     ".join(s for s in [f"Cl {cl:.3f}" if cl is not None else "", f"Cd {cd:.4f}" if cd else "",
                                    f"L/D {cl / cd:.1f}" if cl is not None and cd else ""] if s)
    big, small = font(int(h * 0.36)), font(int(h * 0.27))
    draw.text((28, h * 0.30), head, font=big, fill=(240, 242, 245), anchor="lm")
    draw.text((w - 28, h * 0.30), design_id, font=small, fill=(150, 156, 168), anchor="rm")
    draw.text((28, h * 0.74), tail, font=small, fill=(205, 210, 218), anchor="lm")
    return publish_image(img, directory, stem)


def write_legend(directory, stem, spec):
    from PIL import Image, ImageDraw
    w, h = 1600, 260
    img = Image.new("RGB", (w, h), (24, 26, 30))
    draw = ImageDraw.Draw(img)
    lo, hi = spec["range"]
    center = spec.get("center")
    m = 90  # room for the end labels, centered on the bar's ends
    bar = colormap(spec["map"], np.linspace(0.0, 1.0, w - 2 * m), 0.0, 1.0, linear=False)
    for i, c in enumerate(bar):
        draw.line([(m + i, 70), (m + i, 150)], fill=tuple(int(255 * v) for v in c))
    if center is None:
        ticks = [lo + k * (hi - lo) / 4 for k in range(5)]
    else:
        ticks = [lo, (lo + center) / 2, center, (center + hi) / 2, hi]
    for value, t in zip(ticks, normalize(ticks, lo, hi, center)):
        x = m + t * (w - 2 * m - 1)
        draw.line([(x, 150), (x, 165)], fill=(220, 222, 226), width=3)
        draw.text((x, 170), f"{value:g}", font=font(46), fill=(240, 242, 245), anchor="mt")
    draw.text((m, 14), spec["title"], font=font(44), fill=(240, 242, 245))
    return publish_image(img, directory, stem)


# The study

def lock(stage_dir):
    handle = open(os.path.join(stage_dir, ".lock"), "w")
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def load_manifest(stage_dir):
    path = os.path.join(stage_dir, "designs.json")
    return json.load(open(path)) if os.path.isfile(path) else []


def current_image(stage_dir, sub, stem):
    """The file name publish_image gave the stem's image in <stage_dir>/<sub>."""
    found = sorted(glob.glob(os.path.join(glob.escape(os.path.join(stage_dir, sub)), glob.escape(stem) + "-*.png")),
                   key=os.path.getmtime)
    return os.path.basename(found[-1]) if found else stem + ".png"


def write_study(stage_dir, manifest, columns):
    tile_w = BOX[1] - BOX[0] + GAP[0]
    tile_h = BOX[3] - BOX[2] + LABEL_H + GAP[1]
    tmp = os.path.join(stage_dir, ".study.tmp.usda")
    if os.path.exists(tmp):
        os.remove(tmp)
    layer = Sdf.Layer.CreateNew(tmp)
    stage = Usd.Stage.Open(layer)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    world = UsdGeom.Xform.Define(stage, "/World")
    stage.SetDefaultPrim(world.GetPrim())
    layer.customLayerData = {"designs": len(manifest), "exported_by": "usd-export"}

    lights = UsdGeom.Scope.Define(stage, "/World/Lights")
    dome = UsdLux.DomeLight.Define(stage, lights.GetPath().AppendChild("Dome"))
    dome.CreateIntensityAttr(800.0)
    sun = UsdLux.DistantLight.Define(stage, lights.GetPath().AppendChild("Sun"))
    sun.CreateIntensityAttr(2500.0)
    sun.CreateAngleAttr(1.0)
    UsdGeom.XformCommonAPI(sun).SetRotate(Gf.Vec3f(35, 0, 30))

    designs = UsdGeom.Xform.Define(stage, "/World/Designs")
    rows = max(1, math.ceil(len(manifest) / columns))
    for entry in manifest:
        slot = entry["slot"]
        col, row = slot % columns, slot // columns
        prim = UsdGeom.Xform.Define(stage, designs.GetPath().AppendChild(entry["prim"]))
        prim.GetPrim().GetReferences().AddReference("./" + entry["file"])
        UsdGeom.XformCommonAPI(prim).SetTranslate(Gf.Vec3d(col * tile_w, -row * tile_h, 0.0))

    legend = UsdGeom.Xform.Define(stage, "/World/Legend")
    looks = Sdf.Path("/World/Legend/Looks")
    legend_w = (BOX[1] - BOX[0]) * 0.9
    legend_h = legend_w * 260 / 1600
    y = BOX[2] - (rows - 1) * tile_h - 0.4 - legend_h
    for k, name in enumerate(FIELDS):
        x0 = k * tile_w + BOX[0]
        quad(stage, legend.GetPath().AppendChild(name), x0, y, x0 + legend_w, y + legend_h, 0.0,
             texture_material(stage, looks.AppendChild(name), "./legend/" + current_image(stage_dir, "legend", name)))

    # One switch for the field every design shows: select /World, Variants, field
    vset = world.GetPrim().GetVariantSets().AddVariantSet("field")
    for name in FIELDS:
        vset.AddVariant(name)
        vset.SetVariantSelection(name)
        with vset.GetVariantEditContext():
            for entry in manifest:
                design = designs.GetPath().AppendChild(entry["prim"])
                over = stage.OverridePrim(design.AppendChild("Field"))
                UsdShade.MaterialBindingAPI.Apply(over).GetDirectBindingRel().SetTargets(
                    [design.AppendPath(Sdf.Path("Looks/Field_" + name))])
    vset.SetVariantSelection("velocity")

    layer.Save()
    os.replace(tmp, os.path.join(stage_dir, "study.usda"))


def find_cases(source):
    """Case directories under source: those holding case/case.foam (or params.in, which
    a case has before its mesh exists), at most four levels down."""
    found = []
    source = os.path.abspath(source)
    base = source.rstrip("/").count("/")
    for dirpath, dirnames, filenames in os.walk(source):
        depth = dirpath.count("/") - base
        if os.path.isfile(os.path.join(dirpath, "case", "case.foam")) or (
                "params.in" in filenames and dirpath != source):
            found.append(dirpath)
            dirnames[:] = []
            continue
        if depth >= 4:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if not d.startswith((".", "processor")) and d not in ("case", "images")]
    return sorted(found, key=lambda d: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", d)])


def case_state(case_dir):
    if os.path.isfile(os.path.join(case_dir, "results.out")):
        return "solved"
    if os.path.isfile(os.path.join(case_dir, "exit_code")):
        return "failed"
    return "pending"


def export_case(case_dir, source, stage_dir, manifest, columns, reader):
    rel = os.path.relpath(case_dir, source)
    design_id = os.path.basename(os.path.abspath(source)) if rel == "." else rel
    prim = prim_name(design_id)
    params = read_pairs(os.path.join(case_dir, "params.in"))
    results = read_pairs(os.path.join(case_dir, "results.out"))
    started = time.time()
    data = reader(case_dir)
    label = write_label(os.path.join(stage_dir, "labels"), prim, design_id, params, results)
    file = write_design(stage_dir, prim, design_id, data, params, results, "../labels/" + label)
    with lock(stage_dir):
        manifest[:] = load_manifest(stage_dir)
        entry = next((e for e in manifest if e["prim"] == prim), None)
        if entry is None:
            entry = {"prim": prim, "slot": len(manifest)}
            manifest.append(entry)
        entry.update({"design": design_id, "case_dir": os.path.abspath(case_dir), "file": file,
                      "params": params, "results": results})
        tmp = os.path.join(stage_dir, ".designs.json.tmp")
        json.dump(manifest, open(tmp, "w"), indent=1)
        os.replace(tmp, os.path.join(stage_dir, "designs.json"))
        write_study(stage_dir, manifest, columns)
    log(f"exported {design_id}: {len(data['points'])} points, {len(data['curves'])} streamlines, "
        f"{time.time() - started:.1f} s -> {file}")


# A format is a reader from one case directory to the pieces write_design draws: the
# plane's points, faces, raw fields and field images, the airfoil, the streamlines.
FORMATS = {"openfoam-naca": read_case}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--source", required=True, help="a case directory, or a directory of cases")
    parser.add_argument("--stage-dir", required=True, help="where study.usda and designs/ go")
    parser.add_argument("--format", choices=sorted(FORMATS), default="openfoam-naca",
                        help="the solver output the cases hold")
    parser.add_argument("--columns", type=int, default=4, help="designs per row of the grid")
    parser.add_argument("--follow-minutes", type=float, default=0,
                        help="keep exporting cases as they finish until none has for this long")
    parser.add_argument("--poll-seconds", type=float, default=10)
    args = parser.parse_args()

    if not os.path.isdir(args.source):
        sys.exit(f"::error::The results directory {args.source} does not exist")
    for sub in ("designs", "labels", "legend", "textures"):
        os.makedirs(os.path.join(args.stage_dir, sub), exist_ok=True)
    manifest = load_manifest(args.stage_dir)
    with lock(args.stage_dir):
        for name, spec in FIELDS.items():
            write_legend(os.path.join(args.stage_dir, "legend"), name, spec)
        write_study(args.stage_dir, manifest, args.columns)
    log(f"stage {os.path.join(args.stage_dir, 'study.usda')}, source {args.source}")

    done, failed, errors = set(), set(), 0
    last_change = time.time()
    while True:
        cases = find_cases(args.source)
        for case_dir in cases:
            if case_dir in done or case_dir in failed:
                continue
            state = case_state(case_dir)
            if state == "failed":
                failed.add(case_dir)
                log(f"skipped {case_dir}: the solver failed (exit_code without results.out)")
                last_change = time.time()
            elif state == "solved":
                try:
                    export_case(case_dir, args.source, args.stage_dir, manifest, args.columns,
                                FORMATS[args.format])
                except Exception as error:  # one unreadable case must not stop the study
                    errors += 1
                    log(f"::warning::{case_dir}: {error}")
                    failed.add(case_dir)
                done.add(case_dir)
                last_change = time.time()
        pending = [c for c in cases if c not in done and c not in failed]
        study_closed = os.path.isfile(os.path.join(args.source, "results.csv")) and not pending
        idle = time.time() - last_change
        if args.follow_minutes <= 0 or study_closed or idle > args.follow_minutes * 60:
            break
        time.sleep(args.poll_seconds)

    exported = len(done) - errors
    log(f"{exported} designs exported, {len(failed)} skipped, {len(pending)} still pending")
    if exported == 0 and not load_manifest(args.stage_dir):
        sys.exit(f"::error::No solved case under {args.source}: nothing to show")


if __name__ == "__main__":
    main()
