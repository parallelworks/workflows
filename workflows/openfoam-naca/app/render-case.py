#!/usr/bin/env pvpython
"""Render the fields of a solved NACA airfoil case to PNG images with ParaView.

    pvpython --force-offscreen-rendering render-case.py --case <dir with case.foam> --out <images dir>
             [--params params.in] [--results results.out] [--width 1400] [--height 875]

Reads the last time step of the OpenFOAM case through ParaView's reader (a
reconstructed case, or the processor* directories when reconstructPar left
none) and writes, in the output directory:

    pressure.png     p (kinematic pressure) around the airfoil
    velocity.png     |U| around the airfoil
    streamlines.png  streamlines seeded upstream, colored by |U|
    turbulence.png   nut, the Spalart-Allmaras eddy viscosity (wake and boundary layer)
    wake.png         |U| over the wake, four chords downstream
    mesh.png         the C-grid cells around the airfoil
    manifest.json    the images written, with the camera box of each

Every image carries the design read from --params (NACA digits, angle of
attack) and the coefficients read from --results in its top-left corner. The
case is one cell deep in z and is looked at from +z with a parallel
projection, so an image is a true plan view at the given width:height ratio.

Needs ParaView 5.10 or newer; the images are rendered offscreen (pvpython of the
official binaries falls back to OSMesa when no display is available). A field
that is missing from the case is skipped with a message, never a failure; the
exit status is non-zero only when nothing could be rendered.
"""

import argparse
import json
import math
import os
import sys

from paraview.simple import *  # noqa: F401,F403  (pvpython's API)
from paraview import simple as pvs


# preset names, newest first (ParaView 6 dropped the "(matplotlib)" suffix)
VIRIDIS = ("Viridis", "Viridis (matplotlib)")
INFERNO = ("Inferno", "Inferno (matplotlib)")
COOL_WARM = ("Cool to Warm",)


def read_pairs(path):
    """{name: value} from a '<value> <name>' per line file (Dakota style)."""
    values = {}
    if not path or not os.path.isfile(path):
        return values
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    values[parts[1]] = float(parts[0])
                except ValueError:
                    continue
    return values


def design_label(params, results):
    """'NACA 2412, alpha 5.0 deg, Cd 0.0222, Cl 0.722' from the two files."""
    bits = []
    m, p, t = params.get("max_camber"), params.get("camber_position"), params.get("thickness")
    if None not in (m, p, t):
        digits = (m * 100, p * 10, t * 100)
        if all(abs(d - round(d)) < 1e-6 for d in digits):
            bits.append("NACA %d%d%02d" % tuple(int(round(d)) for d in digits))
        else:
            bits.append("camber %.1f%% at %.0f%% chord, thickness %.1f%%" % digits)
    if "angle_of_attack" in params:
        bits.append("alpha %.1f deg" % params["angle_of_attack"])
    if "drag_coefficient" in results:
        bits.append("Cd %.4f" % results["drag_coefficient"])
    if "neg_lift_coefficient" in results:
        bits.append("Cl %.3f" % -results["neg_lift_coefficient"])
    return ", ".join(bits)


def case_type(case_dir):
    """'Reconstructed Case' when the last time step is in the case root,
    'Decomposed Case' when only the processor* directories have it."""
    times = []
    for name in os.listdir(case_dir):
        try:
            times.append((float(name), name))
        except ValueError:
            continue
    has_processors = os.path.isdir(os.path.join(case_dir, "processor0"))
    if times:
        last = max(times)[1]
        if os.path.isdir(os.path.join(case_dir, last)) and os.listdir(os.path.join(case_dir, last)):
            return "Reconstructed Case"
    return "Decomposed Case" if has_processors else "Reconstructed Case"


def set_if(proxy, name, value):
    """Set a proxy property that exists in this ParaView version, else ignore."""
    try:
        if name in proxy.ListProperties():
            setattr(proxy, name, value)
            return True
    except Exception:
        pass
    return False


def apply_preset(lut, *names):
    """Apply the first color map preset this ParaView version knows by name."""
    for name in names:
        try:
            if lut.ApplyPreset(name, True):
                return name
        except Exception:
            continue
    return None


def available(prop):
    try:
        return list(prop.GetAvailable())
    except Exception:
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True, help="OpenFOAM case directory (holds case.foam)")
    ap.add_argument("--out", required=True, help="directory for the PNG images")
    ap.add_argument("--params", default="", help="params.in of the design (for the label)")
    ap.add_argument("--results", default="", help="results.out of the case (for the label)")
    ap.add_argument("--width", type=int, default=1400)
    ap.add_argument("--height", type=int, default=875)
    args = ap.parse_args()

    case_dir = os.path.abspath(args.case)
    foam = os.path.join(case_dir, "case.foam")
    if not os.path.isfile(foam):
        open(foam, "w").close()
    os.makedirs(args.out, exist_ok=True)

    label = design_label(read_pairs(args.params), read_pairs(args.results))
    print("render-case: %s (%s)" % (case_dir, label or "no design label"))

    # Show() resets the camera on the view's first render unless told not to,
    # which would undo the plan-view camera set below (every ParaView trace
    # starts with this call for the same reason)
    try:
        pvs._DisableFirstRenderCameraReset()
    except Exception:
        pass
    reader = pvs.OpenFOAMReader(FileName=foam)
    set_if(reader, "CaseType", case_type(case_dir))
    reader.UpdatePipelineInformation()
    regions = available(reader.GetProperty("MeshRegions"))
    arrays = available(reader.GetProperty("CellArrays"))
    print("render-case: regions %s, arrays %s" % (regions, arrays))
    wanted_regions = [r for r in ("internalMesh", "patch/walls") if r in regions]
    if "internalMesh" not in wanted_regions:
        sys.exit("render-case: the case has no internalMesh region")
    reader.MeshRegions = wanted_regions
    reader.CellArrays = [a for a in ("p", "U", "nut", "nuTilda") if a in arrays]
    set_if(reader, "Createcelltopointfiltereddata", 1)
    set_if(reader, "CreateCelltoPoint", 1)
    set_if(reader, "Decomposepolyhedra", 1)
    times = list(reader.TimestepValues) if hasattr(reader, "TimestepValues") else []
    last = times[-1] if times else 0.0
    print("render-case: time steps %s, rendering t = %g" % (times, last))
    scene = pvs.GetAnimationScene()
    scene.UpdateAnimationUsingDataTimeSteps()
    scene.AnimationTime = last
    reader.UpdatePipeline(last)

    bounds = reader.GetDataInformation().GetBounds()
    z_mid = 0.5 * (bounds[4] + bounds[5])
    aspect = float(args.width) / float(args.height)

    # the internal mesh (fields) and the airfoil wall (outline) as two sources
    internal = pvs.ExtractBlock(Input=reader)
    if not set_if(internal, "Selectors", ["/Root/internalMesh"]):
        set_if(internal, "BlockIndices", [1])
    walls = None
    if "patch/walls" in wanted_regions:
        walls = pvs.ExtractBlock(Input=reader)
        if not set_if(walls, "Selectors", ["/Root/boundary/walls"]):
            walls = None
    merged = pvs.MergeBlocks(Input=internal)
    merged.UpdatePipeline(last)
    point_arrays = [merged.PointData[i].GetName() for i in range(len(merged.PointData))]
    cell_arrays = [merged.CellData[i].GetName() for i in range(len(merged.CellData))]
    print("render-case: point arrays %s, cell arrays %s" % (point_arrays, cell_arrays))
    assoc = "POINTS" if point_arrays else "CELLS"
    have = set(point_arrays) | set(cell_arrays)

    view = pvs.GetActiveViewOrCreate("RenderView")
    view.ViewSize = [args.width, args.height]
    view.ViewTime = last
    view.OrientationAxesVisibility = 0
    view.InteractionMode = "2D"
    set_if(view, "UseColorPaletteForBackground", 0)
    set_if(view, "BackgroundColorMode", "Single Color")
    view.Background = [1.0, 1.0, 1.0]
    view.CameraParallelProjection = 1
    view.CameraViewUp = [0.0, 1.0, 0.0]

    def look_at(x0, x1, yc=0.0):
        """Parallel camera showing x0..x1 at the image's aspect, centered at yc."""
        half_w = 0.5 * (x1 - x0)
        half_h = half_w / aspect
        xc = 0.5 * (x0 + x1)
        view.CameraFocalPoint = [xc, yc, z_mid]
        view.CameraPosition = [xc, yc, z_mid + 10.0]
        view.CameraParallelScale = half_h
        return [x0, x1, yc - half_h, yc + half_h]

    def box_range(name, x0, x1, y0, y1):
        """Data range of a field inside a box: the far field would otherwise
        set the color scale, hiding the gradients around the airfoil."""
        clip = pvs.Clip(Input=merged)
        clip.ClipType = "Box"
        set_if(clip, "Invert", 1)
        set_if(clip, "Crinkleclip", 1)
        clip.ClipType.Position = [x0, y0, bounds[4] - 1.0]
        clip.ClipType.Length = [x1 - x0, y1 - y0, bounds[5] - bounds[4] + 2.0]
        clip.UpdatePipeline(last)
        data = clip.PointData if assoc == "POINTS" else clip.CellData
        arr = data[name]
        rng = arr.GetRange(-1) if arr.GetNumberOfComponents() > 1 else arr.GetRange()
        pvs.Delete(clip)
        return rng

    text = pvs.Text(Text=label) if label else None
    text_display = None
    if text is not None:
        text_display = pvs.Show(text, view)
        text_display.Color = [0.0, 0.0, 0.0]
        text_display.FontSize = 20
        set_if(text_display, "WindowLocation", "Upper Left Corner")
        set_if(text_display, "FontFamily", "Arial")

    outline_display = None
    if walls is not None:
        outline_display = pvs.Show(walls, view)
        outline_display.SetRepresentationType("Wireframe")
        pvs.ColorBy(outline_display, None)
        outline_display.AmbientColor = [0.0, 0.0, 0.0]
        outline_display.DiffuseColor = [0.0, 0.0, 0.0]
        outline_display.LineWidth = 2.0

    manifest = {"case": case_dir, "time": last, "label": label, "images": {}}

    def save(name, camera_box):
        path = os.path.join(args.out, name + ".png")
        look_at(camera_box[0], camera_box[1], 0.5 * (camera_box[2] + camera_box[3]))
        pvs.Render(view)
        pvs.SaveScreenshot(path, view, ImageResolution=[args.width, args.height])
        manifest["images"][name] = {"file": name + ".png", "box": camera_box}
        print("render-case: wrote %s" % path)

    def color_bar(lut, title):
        bar = pvs.GetScalarBar(lut, view)
        bar.Title = title
        bar.ComponentTitle = ""
        bar.TitleColor = [0.0, 0.0, 0.0]
        bar.LabelColor = [0.0, 0.0, 0.0]
        bar.TitleFontSize = 18
        bar.LabelFontSize = 16
        set_if(bar, "Orientation", "Horizontal")
        set_if(bar, "WindowLocation", "Lower Center")
        set_if(bar, "ScalarBarLength", 0.4)
        bar.Visibility = 1
        return bar

    def field_image(name, array, title, presets, x0, x1, component=None,
                    log_scale=False, invert=False):
        if array not in have:
            print("render-case: no %s in the case, skipping %s.png" % (array, name))
            return
        box = look_at(x0, x1)
        display = pvs.Show(merged, view)
        display.SetRepresentationType("Surface")
        if component:
            pvs.ColorBy(display, (assoc, array, component))
        else:
            pvs.ColorBy(display, (assoc, array))
        lut = pvs.GetColorTransferFunction(array)
        apply_preset(lut, *presets)
        if invert:
            lut.InvertTransferFunction()
        lo, hi = box_range(array, box[0], box[1], box[2], box[3])
        # a field spanning orders of magnitude (the eddy viscosity: near zero
        # in the free stream, large in the wake) is shown in log scale over its
        # top three decades, so the boundary layer and the wake both read
        if log_scale and hi > 0:
            lo = max(lo, hi * 1e-3)
            lut.RescaleTransferFunction(lo, hi)
            lut.MapControlPointsToLogSpace()
            lut.UseLogScale = 1
        else:
            lut.UseLogScale = 0
            lut.MapControlPointsToLinearSpace()
            lut.RescaleTransferFunction(lo, hi)
        bar = color_bar(lut, title)
        save(name, box)
        bar.Visibility = 0
        if invert:
            lut.InvertTransferFunction()
        pvs.Hide(merged, view)

    near = (-0.45, 1.65)
    field_image("pressure", "p", "p (kinematic pressure, m2/s2)", COOL_WARM, *near)
    field_image("velocity", "U", "|U| (m/s)", VIRIDIS, *near, component="Magnitude")
    field_image("turbulence", "nut", "nut (eddy viscosity, m2/s, log scale)", INFERNO, *near,
                log_scale=True, invert=True)
    field_image("wake", "U", "|U| (m/s)", VIRIDIS, -1.0, 7.0, component="Magnitude")

    if "U" in have:
        box = look_at(*near)
        tracer = pvs.StreamTracer(Input=merged, SeedType="Line")
        tracer.Vectors = [assoc, "U"]
        tracer.SeedType.Point1 = [-0.45, box[2], z_mid]
        tracer.SeedType.Point2 = [-0.45, box[3], z_mid]
        tracer.SeedType.Resolution = 70
        tracer.IntegrationDirection = "FORWARD"
        tracer.MaximumStreamlineLength = 4.0
        set_if(tracer, "MaximumSteps", 4000)
        display = pvs.Show(tracer, view)
        pvs.ColorBy(display, ("POINTS", "U", "Magnitude"))
        display.LineWidth = 1.5
        lut = pvs.GetColorTransferFunction("U")
        apply_preset(lut, *VIRIDIS)
        lut.MapControlPointsToLinearSpace()
        lut.UseLogScale = 0
        lut.RescaleTransferFunction(*box_range("U", box[0], box[1], box[2], box[3]))
        bar = color_bar(lut, "|U| (m/s) along streamlines")
        save("streamlines", box)
        bar.Visibility = 0
        pvs.Hide(tracer, view)

    box = look_at(-0.3, 1.5)
    display = pvs.Show(merged, view)
    display.SetRepresentationType("Wireframe")
    pvs.ColorBy(display, None)
    display.AmbientColor = [0.45, 0.45, 0.45]
    display.DiffuseColor = [0.45, 0.45, 0.45]
    display.LineWidth = 1.0
    save("mesh", box)
    pvs.Hide(merged, view)

    # the manifest is written last: its presence means every image is complete
    with open(os.path.join(args.out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    if not manifest["images"]:
        print("render-case: nothing was rendered")
        finish(1)
    print("render-case: %d images in %s" % (len(manifest["images"]), os.path.abspath(args.out)))
    finish(0)


def finish(code):
    """Leave without the interpreter's teardown: once a render window exists,
    the exit of pvpython has hung in the software renderer's thread teardown
    (futex wait after the image was written, 16 llvmpipe threads; gcpsmall,
    2026-10-08). Every file is closed by now, so nothing is lost."""
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


if __name__ == "__main__":
    main()
