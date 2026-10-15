#!/bin/bash
# openfoam-expansion simulator: one design in params.in -> results.out in the
# case directory. Contracts copied from openfoam-naca/app/simulator.sh:
#   params.in   lines "<value> <name>": the design parameters of
#               app/design-parameters.txt plus run settings (reynolds,
#               mesh_scale, inlet_length, outlet_length, plane_in, plane_out,
#               sharp_step)
#   results.out lines "<value> <label>", loss_coefficient first, then the
#               diagnostics; nonzero exit status when the case fails
# Geometry: h = 1 (inlet channel y in [1,2], outlet y in [0,2]), U_b = 1,
# Re = U_b * 2h / nu  =>  nu = 2 / Re. K = (p0_in - p0_out)/(0.5 U_b^2)
# = 2 (p0_in - p0_out), flux-weighted on the lossIn/lossOut faceZones.
set -u
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$APP_DIR/openfoam-case"
CASE_DIR="${CASE_DIR:-$PWD}"
CASE_DIR="$(cd "$CASE_DIR" && pwd)"
PARAMS="${PARAMS:-$CASE_DIR/params.in}"
CORES_PER_CASE="${CORES_PER_CASE:-1}"
MESH_SCALE="${MESH_SCALE:-}"

[ -f "$PARAMS" ] || { echo "no params.in at $PARAMS"; exit 1; }
eval "$(awk 'NF == 2 && $1 ~ /^-?[0-9][0-9.eE+-]*$/ {print $2"="$1}' "$PARAMS")" || exit 1
re="${reynolds:-300}";        sharp="${sharp_step:-0}"
tl="${transition_length:-2}"; a="${top_rounding:-0}"; b="${bottom_rounding:-0}"
il="${inlet_length:-5}";      ol="${outlet_length:-60}"
pin="${plane_in:--2}";        pout="${plane_out:-40}"
ms="${mesh_scale:-$MESH_SCALE}"; ms="${ms:-1}"

[ -f "${OPENFOAM_ENV:-}" ] || { echo "OPENFOAM_ENV not set"; exit 1; }
source "$OPENFOAM_ENV"
command -v blockMesh >/dev/null && command -v simpleFoam >/dev/null || {
  echo "blockMesh/simpleFoam not on PATH after sourcing $OPENFOAM_ENV"; exit 1; }

nu=$(awk -v r="$re" 'BEGIN {printf "%.8g", 2.0/r}')
rm -rf "$CASE_DIR/case"
mkdir -p "$CASE_DIR/case"
cp -r "$TPL/0" "$TPL/constant" "$TPL/system" "$CASE_DIR/case/"

# --- mesh: the generator writes blockMeshDict, topoSetDict and the inlet face
# centres; sharp_step selects the step layout (its own blocks and patches)
flags=(--l "$tl" --a "$a" --b "$b" --scale "$ms" --inlet-length "$il" \
       --outlet-length "$ol" --plane-in "$pin" --plane-out "$pout" \
       --topo-set "$CASE_DIR/case/system/topoSetDict" \
       --inlet-centres "$CASE_DIR/case/inlet-centres.dat")
[ "$sharp" = "1" ] && flags+=(--step)
python3 "$APP_DIR/expansion_blockmesh.py" "${flags[@]}" \
  > "$CASE_DIR/case/system/blockMeshDict" || exit 1

# --- physics: nu from Re; parabolic U(y) = 1.5 (1 - ((y-1.5)/0.5)^2) written
# exactly at the inlet face centres the generator reported (the template's
# inlet block carries $internalField; that value line is replaced)
sed -i "s|^ *nu .*|        nu              ${nu};|" "$CASE_DIR/case/constant/transportProperties"
python3 - "$CASE_DIR/case" << 'PYEOF' || exit 1
import re, sys
cdir = sys.argv[1]
ys = [float(l) for l in open(cdir + "/inlet-centres.dat") if l.strip()]
u = [1.5 * (1.0 - ((y - 1.5) / 0.5) ** 2) for y in ys]
listing = "nonuniform List<vector>\n%d(\n%s)\n;" % (len(u), "".join("(%.10f 0 0)\n" % v for v in u))
src = open(cdir + "/0/U").read()
new = re.sub(r'value\s+(\$internalField|uniform \(0 0 0\));',
             lambda m: m.group(0)[:m.start(0) - m.start(0)] + "value\n" + listing, src, count=1)
assert new != src, "inlet value line not found in 0/U"
open(cdir + "/0/U", "w").write(new)
PYEOF

# the Gartling placement (inlet on the step) has no lossIn zone: drop its
# function object or simpleFoam fails on a missing zone
if awk -v il="$il" 'BEGIN {exit !(il == 0)}'; then
  sed -i '/BEGIN lossIn/,/END lossIn/d' "$CASE_DIR/case/system/controlDict"
fi

cd "$CASE_DIR/case" || exit 1
blockMesh > log.blockMesh 2>&1 || { tail -5 log.blockMesh; exit 1; }
topoSet  > log.topoSet 2>&1 || { tail -5 log.topoSet;  exit 1; }
simpleFoam > log.simpleFoam 2>&1
rc=$?
tail -3 log.simpleFoam
[ $rc -eq 0 ] || exit $rc
touch case.foam

# --- results.out: objective first, diagnostics after (spec, section Evaluator)
python3 - "$CASE_DIR" << 'PYEOF' || exit 1
import glob, os, re, sys
cdir = sys.argv[1]
def last_dat(fo):
    f = sorted(glob.glob("%s/case/postProcessing/%s/*/surfaceFieldValue.dat" % (cdir, fo)))
    if not f: return None
    rows = [l.split() for l in open(f[-1]) if l.strip() and not l.startswith("#")]
    return float(rows[-1][1]) if rows else None
pin, pout = last_dat("lossInZone"), last_dat("lossOutZone")
out = []
if pin is not None and pout is not None:
    out.append("%+.8e loss_coefficient" % (2.0 * (pin - pout)))

# wall shear sampled raw (x y z taux tauy tauz); diagnostics from the sign of
# the streamwise component on the lower wall downstream of x = 0
def wall(name):
    f = sorted(glob.glob("%s/case/postProcessing/wallSample/*/wallShearStress_%s.raw" % (cdir, name)))
    if not f: return []
    pts = [l.split() for l in open(f[-1]) if l.strip() and not l.startswith("#")]
    return sorted((float(p[0]), float(p[3])) for p in pts)
lw = [p for p in wall("lowerWall") if p[0] > -1e-9]
neg = [p for p in lw if p[1] > 0]  # OF sign: tau_x > 0 = reversed flow on lower wall
if neg:
    xs, xr = min(p[0] for p in neg), max(p[0] for p in neg)
    out += ["%.6f separation_point" % xs, "%.6f reattachment_point" % xr,
            "%.6f lower_bubble_length" % (xr - xs)]
else:
    out += ["-1 separation_point", "-1 reattachment_point", "0 lower_bubble_length"]
if lw:
    mws = -max(p[1] for p in lw)  # classical sign: min wall shear, lower wall x>0
    out.append("%+.6e min_wall_shear" % mws)
    out.append("%+.6e neg_min_wall_shear" % -mws)
uw = [p for p in wall("upperWall") if p[1] > 0]  # OF sign: tau_x > 0 = reversed flow on upper wall
if uw:
    out += ["%.6f upper_eddy_start" % min(p[0] for p in uw),
            "%.6f upper_eddy_end" % max(p[0] for p in uw)]

# recirculation area: cells with Ux < 0, volumes from the V field, scaled to
# area by the (uniform) mesh depth; -1 marks "not computed" rather than 0
try:
    t = sorted((d for d in os.listdir("%s/case" % cdir) if d[0].isdigit() and
                os.path.isdir("%s/case/%s" % (cdir, d))), key=float)[-1]
    def field(name, n):
        txt = open("%s/case/%s/%s" % (cdir, t, name)).read()
        pat = r"nonuniform List<scalar>\s*\d+\s*\(\s*(.*?)\)\s*;" if n == 1 \
            else r"nonuniform List<vector>\s*\d+\s*\(\s*(.*?)\)\s*;"
        m = re.search(pat, txt, re.S)
        vals = re.findall(r"[-0-9.eE+]+", m.group(1))
        it = iter(vals)
        return [float(next(it)) if n == 1 else tuple(float(next(it)) for _ in range(n))
                for _ in range(len(vals) // n)]
    V, U = field("V", 1), field("U", 3)
    pts = open("%s/case/constant/polyMesh/points" % cdir).read()
    zs = [float(s.split()[2]) for s in re.findall(r"\(([-0-9.eE+ ]+)\)", pts)]
    dz = max(zs) - min(zs)
    out.append("%.6f recirculation_area" % (sum(v for v, u in zip(V, U) if u[0] < 0) / dz))
except Exception:
    out.append("-1 recirculation_area")
open("%s/results.out" % cdir, "w").write("\n".join(out) + "\n")
print("\n".join(out))
PYEOF
