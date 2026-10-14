#!/usr/bin/env python3
"""Generate a structured blockMeshDict for the planar-expansion case (spec.md).

    expansion_blockmesh.py --l 2 --a 0 --b 0 --scale 1 > system/blockMeshDict
    expansion_blockmesh.py --step --scale 1 ...               (sharp step)
    expansion_blockmesh.py --step --inlet-length 0 ...   (Gartling placement)

All lengths in units of h. Inlet channel height h (lower wall y = 1, upper
wall y = 2), outlet channel height 2h (lower wall y = 0, upper wall y = 2).
The transition wall is the cubic Bezier of spec.md from (0, 1) to (l, 0) with
control points P0 = (0,1), P1 = (a*l, 1), P2 = ((1-b)*l, 0), P3 = (l, 0):
a = b = 0 is the straight ramp (the curve stays on y = 1 - x/l). --step emits
the sharp-step geometry instead: vertical step wall at x = 0 from y = 0 to
y = 1, inlet blocks A/B upstream of the step when --inlet-length > 0, or the
inflow plane directly at the step lip when --inlet-length 0 (Gartling's
placement; then there is no loss-in plane). One cell deep in z (empty patch).

Sidecars: --topo-set PATH also writes a topoSetDict selecting the loss planes
x = plane_in and x = plane_out as the faceZones lossIn and lossOut (boxToFace
on thin boxes; blockMesh cannot take faceZones directly), and --inlet-centres
PATH writes the y face-centre positions of the inlet patch, from which the
simulator writes the exact parabolic inlet profile.

Two layouts, because blockMesh needs matching division counts on shared edges
and the step stacks blocks in y while the ramp does not:

  ramp:  A [-IL, PIN] y [1,2]   B [PIN, 0] y [1,2]   C [0, l] y [bezier, 2]
         D [l, POUT] y [0,2]    E [POUT, OL] y [0,2]
         every block 2*NY cells in y: one count serves the [1,2] side edges
         of A/B and the [0,2] side edges of C/D/E, so the transition block
         stays conformal and cells stretch smoothly through it. Inlet face
         centres at y = 1 + (i + 1/2)/(2*NY).

  step:  A [-IL, PIN] y [1,2]   B [PIN, 0] y [1,2]    (skipped when IL = 0)
         C1 [0, POUT] y [0,1]   C2 [0, POUT] y [1,2]   (left face of C1 = the
         step wall; left face of C2 = the inflow plane when IL = 0)
         D1 [POUT, OL] y [0,1]  D2 [POUT, OL] y [1,2]
         NY cells per h of height; the shared y = 1 edges all carry matching
         counts. Inlet face centres at y = 1 + (i + 1/2)/NY.

The frontAndBack (empty) patch lists the two horizontal z-plane quads of every
block, not vertical edge faces: in the step layout the y = 1 edge between C1
and C2 is internal, so a vertical quad over it is not a boundary face (that
was the blockMesh failure). mesh_scale multiplies every cell count.
"""

import argparse
import math
import sys

ZH = 1.0          # z extrusion depth, one cell (cancels in flux-weighted means)


def bezier(l, a, b, t):
    """Point on the cubic transition-wall Bezier at parameter t (spec.md)."""
    x = (3.0 * (1 - t) ** 2 * t * a + 3.0 * (1 - t) * t ** 2 * (1.0 - b)
         + t ** 3) * l
    y = (1 - t) ** 2 * (1.0 + 2.0 * t)
    return x, y


class MeshWriter:
    """Collect vertices/blocks/edges/patches, emit a blockMeshDict."""

    def __init__(self):
        self.verts = []     # [(x, y)] in the z = 0 plane
        self.blocks = []    # (v0, v1, v2, v3, nx, ny, gx): LL, LR, UR, UL
        self.edges = []     # (i, j, [(x, y), ...]) polyLine, z = 0 plane
        self.patches = []   # (name, type, quads or None): None = frontAndBack

    def v(self, x, y):
        self.verts.append((x, y))
        return len(self.verts) - 1

    def hexblock(self, v0, v1, v2, v3, nx, ny, gx=1.0):
        self.blocks.append((v0, v1, v2, v3, nx, ny, gx))

    def emit(self):
        nv = len(self.verts)
        out = ["""FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      blockMeshDict;
}

scale   1;
""", "vertices\n("]
        for x, y in self.verts:
            out.append("    (%.8f %.8f 0)" % (x, y))
        for x, y in self.verts:
            out.append("    (%.8f %.8f %.3f)" % (x, y, ZH))
        out.append(");")

        out += ["", "blocks", "("]
        for v0, v1, v2, v3, nx, ny, gx in self.blocks:
            out.append("    hex (%d %d %d %d %d %d %d %d) (%d %d 1) "
                       "simpleGrading (%g 1 1)"
                       % (v0, v1, v2, v3, v0 + nv, v1 + nv, v2 + nv, v3 + nv,
                          nx, ny, gx))
        out.append(");")

        out += ["", "edges", "("]
        for i, j, pts in self.edges:
            out.append("    polyLine %d %d" % (i, j))
            out.append("    (")
            out += ["        (%.8f %.8f 0)" % p for p in pts]
            out.append("    )")
            out.append("    polyLine %d %d" % (i + nv, j + nv))
            out.append("    (")
            out += ["        (%.8f %.8f %.3f)" % (p[0], p[1], ZH) for p in pts]
            out.append("    )")
        out.append(");")

        def vfaces(quads):
            return "\n".join("            (%d %d %d %d)"
                             % (i, j, j + nv, i + nv) for i, j in quads)

        def hfaces():
            """The two z-plane quads of every block: true boundary faces in
            both layouts, unlike vertical quads over internal edges."""
            quads = []
            for v0, v1, v2, v3, _, _, _ in self.blocks:
                quads.append((v0, v1, v2, v3))
                quads.append((v0 + nv, v1 + nv, v2 + nv, v3 + nv))
            return "\n".join("            (%d %d %d %d)" % q for q in quads)

        out += ["", "boundary", "("]
        for name, ptype, quads in self.patches:
            body = hfaces() if quads is None else vfaces(quads)
            out += ["    %s" % name, "    {",
                    "        type %s;" % ptype, "        faces", "        (",
                    body, "        );", "    }"]
        out += [");"]

        sys.stdout.write("\n".join(out) + "\n")


def write_toposet(path, pin, pout):
    """Thin boxToFace selections of the two loss planes, then faceZones."""
    acts = []
    for name, x in (("lossIn", pin), ("lossOut", pout)):
        acts.append(
            "    { name %s; type faceSet; action new; source boxToFace;\n"
            "      box (%.6f -1 -0.01) (%.6f 3 %.3f); }\n"
            "    { name %s; type faceZoneSet; action new;\n"
            "      source setToFaceZone; faceSet %s; }"
            % (name, x - 0.01, x + 0.01, ZH + 0.01, name, name))
    with open(path, "w") as f:
        f.write("""FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      topoSetDict;
}

actions
(
%s
);
""" % "".join(acts))


def write_inlet_centres(path, n):
    """y positions of the inlet patch face centres, bottom to top."""
    with open(path, "w") as f:
        for i in range(n):
            f.write("%.10f\n" % (1.0 + (i + 0.5) / n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--l", type=float, default=2.0, help="transition length l/h")
    ap.add_argument("--a", type=float, default=0.0, help="top rounding a")
    ap.add_argument("--b", type=float, default=0.0, help="bottom rounding b")
    ap.add_argument("--step", action="store_true",
                    help="sharp-step geometry (validation / baseline)")
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--inlet-length", type=float, default=5.0)
    ap.add_argument("--outlet-length", type=float, default=60.0)
    ap.add_argument("--plane-in", type=float, default=-2.0)
    ap.add_argument("--plane-out", type=float, default=40.0)
    ap.add_argument("--topo-set", default=None,
                    help="also write a topoSetDict for the loss faceZones here")
    ap.add_argument("--inlet-centres", default=None,
                    help="also write the inlet face-centre y positions here")
    args = ap.parse_args()

    IL, OL = args.inlet_length, args.outlet_length
    PIN, POUT = args.plane_in, args.plane_out
    s = max(1, args.scale)
    NY = 32 * s                       # cells per h of height

    if not (0 < POUT < OL):
        sys.exit("need 0 < plane-out < outlet-length (got %g, %g)"
                 % (POUT, OL))
    if args.step:
        if IL < 0:
            sys.exit("inlet-length must be >= 0 (got %g)" % IL)
        if IL > 0 and not (-IL < PIN < 0):
            sys.exit("need -inlet-length < plane-in < 0 (got %g, %g)"
                     % (IL, PIN))
    else:
        if not (-IL < PIN < 0):
            sys.exit("need -inlet-length < plane-in < 0 (got %g, %g)"
                     % (IL, PIN))
        if not (0 < args.l < POUT):
            sys.exit("need 0 < l < plane-out (got %g)" % args.l)
        if not (0 <= args.a <= 0.9 and 0 <= args.b <= 0.9):
            sys.exit("need 0 <= a, b <= 0.9 (got %g, %g)" % (args.a, args.b))

    m = MeshWriter()
    xA, xB, xE = 20 * s, 15 * s, 24 * s  # x cell counts, inlet blocks + far out

    if args.step:
        v00 = m.v(0.0, 0)
        v21, v22 = m.v(0.0, 1), m.v(0.0, 2)
        vP0, vP1, vP2 = m.v(POUT, 0), m.v(POUT, 1), m.v(POUT, 2)
        vO0, vO1, vO2 = m.v(OL, 0), m.v(OL, 1), m.v(OL, 2)
        nC, nD = 120 * s, xE             # x cells [0, POUT] and [POUT, OL]
        m.hexblock(v00, vP0, vP1, v21, nC, NY)          # C1 below the step lip
        m.hexblock(v21, vP1, vP2, v22, nC, NY)          # C2 in line with B
        m.hexblock(vP0, vO0, vO1, vP1, nD, NY, 3.0)     # D1
        m.hexblock(vP1, vO1, vO2, vP2, nD, NY, 3.0)     # D2
        lower = [(v00, vP0), (vP0, vO0)]
        upper = [(v22, vP2), (vP2, vO2)]
        if IL > 0:                       # inlet channel upstream of the step
            vI1, vI2 = m.v(-IL, 1), m.v(-IL, 2)
            vN1, vN2 = m.v(PIN, 1), m.v(PIN, 2)
            m.hexblock(vI1, vN1, vN2, vI2, xA, NY)      # A
            m.hexblock(vN1, v21, v22, vN2, xB, NY)      # B
            lower = [(vI1, vN1), (vN1, v21)] + lower
            upper = [(vI2, vN2), (vN2, v22)] + upper
            inlet = [(vI1, vI2)]
        else:                            # Gartling: inflow at the step lip
            inlet = [(v21, v22)]
        m.patches = [
            ("inlet", "patch", inlet),
            ("outlet", "patch", [(vO0, vO1), (vO1, vO2)]),
            ("lowerWall", "wall", lower),
            ("stepWall", "wall", [(v00, v21)]),
            ("upperWall", "wall", upper),
            ("frontAndBack", "empty", None),
        ]
        n_inlet = NY
    else:
        l = args.l
        v01, v11, v21 = m.v(-IL, 1), m.v(PIN, 1), m.v(0.0, 1)
        v02, v12, v22 = m.v(-IL, 2), m.v(PIN, 2), m.v(0.0, 2)
        vl0, vl2 = m.v(l, 0), m.v(l, 2)
        vP0, vP2 = m.v(POUT, 0), m.v(POUT, 2)
        vO0, vO2 = m.v(OL, 0), m.v(OL, 2)
        nT = max(24, min(120, int(12 * l))) * s         # transition x cells
        nD = max(30, min(120, int(3 * (POUT - l)))) * s  # [l, POUT] x cells
        ny2 = 2 * NY
        m.hexblock(v01, v11, v12, v02, xA, ny2)         # A
        m.hexblock(v11, v21, v22, v12, xB, ny2)         # B
        m.hexblock(v21, vl0, vl2, v22, nT, ny2)         # C, Bezier bottom
        m.hexblock(vl0, vP0, vP2, vl2, nD, ny2, 2.0)    # D
        m.hexblock(vP0, vO0, vO2, vP2, xE, ny2, 3.0)    # E
        n_pts = max(30, int(12 * l))
        m.edges.append((v21, vl0,
                        [bezier(l, args.a, args.b, k / n_pts)
                         for k in range(1, n_pts)]))
        m.patches = [
            ("inlet", "patch", [(v01, v02)]),
            ("outlet", "patch", [(vO0, vO2)]),
            ("lowerWall", "wall",
             [(v01, v11), (v11, v21), (v21, vl0), (vl0, vP0), (vP0, vO0)]),
            ("upperWall", "wall",
             [(v02, v12), (v12, v22), (v22, vl2), (vl2, vP2), (vP2, vO2)]),
            ("frontAndBack", "empty", None),
        ]
        n_inlet = ny2

    m.emit()

    if args.topo_set:
        pin = PIN if IL > 0 else None
        if pin is None:
            # lossIn does not exist at IL = 0; rewrite with only lossOut
            with open(args.topo_set, "w") as f:
                f.write("""FoamFile
{{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      topoSetDict;
}}

actions
(
    {{ name lossOut; type faceSet; action new; source boxToFace;
      box ({pout:.6f} -1 -0.01) ({pout2:.6f} 3 {zh:.3f}); }}
    {{ name lossOut; type faceZoneSet; action new;
      source setToFaceZone; faceSet lossOut; }}
);
""".format(pout=POUT - 0.01, pout2=POUT + 0.01, zh=ZH + 0.01))
        else:
            write_toposet(args.topo_set, PIN, POUT)
    if args.inlet_centres:
        write_inlet_centres(args.inlet_centres, n_inlet)


if __name__ == "__main__":
    main()
