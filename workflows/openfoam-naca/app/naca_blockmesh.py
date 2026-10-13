#!/usr/bin/env python3
"""Generate a structured C-grid blockMeshDict around a NACA 4-digit airfoil.

    naca_blockmesh.py --camber 0.02 --camber-pos 0.4 --thickness 0.12 --scale 1 > blockMeshDict

Chord 1 from (0,0) to (1,0), z-extruded 0..0.1 with empty frontAndBack; patches
named like the airFoil2D tutorial (inlet = far-field arc + top/bottom, outlet =
downstream plane, walls = airfoil) so its 0.orig/ freestream BCs apply unchanged.
The angle of attack is set through the freestream velocity, not the geometry.

Topology: 6 blocks — each airfoil side split near 30%% chord (two blocks whose
shared surface vertex keeps the upper and lower airfoil faces from being
vertex-identical, which blockMesh would fuse), plus two wake blocks behind the
sharp trailing edge whose shared cut is intentionally vertex-identical so the
wake stays contiguous. --scale multiplies every cell count (cost grows ~s^2).
"""

import argparse
import math
import sys

R = 8.0       # far-field radius, chords, centered on the trailing edge
WAKE = 12.0   # wake length behind the trailing edge, chords
ZH = 0.1      # z extrusion depth (one cell); forceCoeffs Aref = ZH * chord
G_RAD = 800   # radial expansion ratio (first wall cell ~2e-3 chord at scale 1)
G_WAKE = 30   # streamwise wake expansion ratio
N_POINTS = 120  # airfoil surface resolution for the polyLine edges


def naca4(m, p, t, x):
    """Return (upper, lower) surface points at chordwise position x."""
    yt = 5.0 * t * (0.2969 * math.sqrt(x) - 0.1260 * x - 0.3516 * x ** 2
                    + 0.2843 * x ** 3 - 0.1036 * x ** 4)  # closed trailing edge
    if m <= 0.0:
        yc, dyc = 0.0, 0.0
    elif x < p:
        yc = m / p ** 2 * (2.0 * p * x - x ** 2)
        dyc = 2.0 * m / p ** 2 * (p - x)
    else:
        yc = m / (1.0 - p) ** 2 * ((1.0 - 2.0 * p) + 2.0 * p * x - x ** 2)
        dyc = 2.0 * m / (1.0 - p) ** 2 * (p - x)
    th = math.atan(dyc)
    return ((x - yt * math.sin(th), yc + yt * math.cos(th)),
            (x + yt * math.sin(th), yc - yt * math.cos(th)))


def surface(m, p, t):
    """Cosine-spaced upper and lower surfaces, LE (0,0) to TE (1,0)."""
    upper, lower = [], []
    for i in range(N_POINTS + 1):
        x = 0.5 * (1.0 - math.cos(math.pi * i / N_POINTS))
        up, lo = naca4(m, p, t, x)
        upper.append(up)
        lower.append(lo)
    upper[0] = lower[0] = (0.0, 0.0)
    upper[-1] = lower[-1] = (1.0, 0.0)
    return upper, lower


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camber", type=float, required=True)
    ap.add_argument("--camber-pos", type=float, required=True)
    ap.add_argument("--thickness", type=float, required=True)
    ap.add_argument("--scale", type=int, default=1)
    args = ap.parse_args()

    upper, lower = surface(args.camber, args.camber_pos, args.thickness)
    split = next(i for i, (x, _) in enumerate(upper) if x >= 0.3)

    s = max(1, args.scale)
    n1, n2 = 30 * s, 30 * s   # surface cells LE->split, split->TE (per side)
    nr, nw = 30 * s, 30 * s   # radial cells, wake cells

    c45 = R / math.sqrt(2.0)

    def arcp(deg):  # far-field arc point, circle centered on the TE
        a = math.radians(deg)
        return (1.0 + R * math.cos(a), R * math.sin(a))

    # per-plane vertices (plane z=0 is 0..11, plane z=ZH is 12..23)
    base = [
        (0.0, 0.0),                    # 0  leading edge
        upper[split],                  # 1  upper split point
        (1.0, 0.0),                    # 2  trailing edge
        lower[split],                  # 3  lower split point
        (1.0 - R, 0.0),                # 4  arc, upstream
        (1.0 - c45, c45),              # 5  arc, upper 135deg
        (1.0, R),                      # 6  arc, above TE
        (1.0 - c45, -c45),             # 7  arc, lower 225deg
        (1.0, -R),                     # 8  arc, below TE
        (1.0 + WAKE, 0.0),             # 9  outlet, wake centerline
        (1.0 + WAKE, R),               # 10 outlet, top
        (1.0 + WAKE, -R),              # 11 outlet, bottom
    ]

    out = ["""FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      blockMeshDict;
}

scale   1;
""", "vertices\n("]
    for z in (0.0, ZH):
        for x, y in base:
            out.append("    (%.8f %.8f %.3f)" % (x, y, z))
    out.append(");")

    def hexblock(a, b, c, d, counts, grading):
        return ("    hex (%d %d %d %d %d %d %d %d) (%d %d 1) simpleGrading (%g %g 1)"
                % (a, b, c, d, a + 12, b + 12, c + 12, d + 12,
                   counts[0], counts[1], grading[0], grading[1]))

    out += ["", "blocks", "(",
            hexblock(0, 1, 5, 4, (n1, nr), (1, G_RAD)),    # upper fore
            hexblock(1, 2, 6, 5, (n2, nr), (1, G_RAD)),    # upper aft
            hexblock(0, 4, 7, 3, (nr, n1), (G_RAD, 1)),    # lower fore
            hexblock(3, 7, 8, 2, (nr, n2), (G_RAD, 1)),    # lower aft
            hexblock(2, 9, 10, 6, (nw, nr), (G_WAKE, G_RAD)),  # wake upper
            hexblock(2, 8, 11, 9, (nr, nw), (G_RAD, G_WAKE)),  # wake lower
            ");"]

    def polyline(a, b, pts):
        rows = "\n".join("            (%.8f %.8f %%s)" % (x, y) for x, y in pts)
        return ("    polyLine %d %d\n        (\n%s\n        )"
                % (a, b, rows.replace("%s", "0.000")),
                "    polyLine %d %d\n        (\n%s\n        )"
                % (a + 12, b + 12, rows.replace("%s", "%.3f" % ZH)))

    def arc(a, b, deg):
        x, y = arcp(deg)
        return ("    arc %d %d (%.8f %.8f 0.000)" % (a, b, x, y),
                "    arc %d %d (%.8f %.8f %.3f)" % (a + 12, b + 12, x, y, ZH))

    out += ["", "edges", "("]
    for pair in (polyline(0, 1, upper[1:split]),
                 polyline(1, 2, upper[split + 1:-1]),
                 polyline(0, 3, lower[1:split]),
                 polyline(3, 2, lower[split + 1:-1]),
                 arc(4, 5, 157.5), arc(5, 6, 112.5),
                 arc(4, 7, 202.5), arc(7, 8, 247.5)):
        out += list(pair)
    out.append(");")

    def faces(quads):
        return "\n".join("        (%d %d %d %d)" % q for q in quads)

    out.append("""
boundary
(
    inlet
    {
        type patch;
        faces
        (
%s
        );
    }
    outlet
    {
        type patch;
        faces
        (
%s
        );
    }
    walls
    {
        type wall;
        faces
        (
%s
        );
    }
    frontAndBack
    {
        type empty;
        faces
        (
%s
        );
    }
);
""" % (faces([(4, 5, 17, 16), (5, 6, 18, 17), (4, 7, 19, 16), (7, 8, 20, 19),
              (6, 10, 22, 18), (8, 11, 23, 20)]),
       faces([(9, 10, 22, 21), (9, 11, 23, 21)]),
       faces([(0, 1, 13, 12), (1, 2, 14, 13), (0, 3, 15, 12), (3, 2, 14, 15)]),
       faces([(0, 1, 5, 4), (1, 2, 6, 5), (0, 4, 7, 3), (3, 7, 8, 2),
              (2, 9, 10, 6), (2, 8, 11, 9),
              (12, 13, 17, 16), (13, 14, 18, 17), (12, 16, 19, 15),
              (15, 19, 20, 14), (14, 21, 22, 18), (14, 20, 23, 21)])))

    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
