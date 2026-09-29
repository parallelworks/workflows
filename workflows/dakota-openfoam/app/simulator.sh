#!/bin/bash
# OpenFOAM per-case driver, run inside one case directory: reads ./params.in (one
# "<value> <name>" line per design variable — the NACA 4-digit parameters), builds
# a C-grid airfoil case from the airFoil2D tutorial (Spalart-Allmaras, freestream
# at ALPHA_DEG incidence, Re = 1e6), runs blockMesh + simpleFoam, and writes
# ./results.out (one "<value> <label>" line per objective, both minimized:
# f1 = drag coefficient, f2 = -lift coefficient, from the forceCoeffs function
# object). The write is atomic; on any error the process exits non-zero and leaves
# no results.out, which is the failure signal. MESH_SCALE (default 1) multiplies
# every cell count — the cost dial.
set -o pipefail

SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
CONDA_PREFIX_DIR="${SOFTWARE_DIR}/dakota-openfoam/miniforge"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

ALPHA_DEG="${ALPHA_DEG:-5}"
UINF="${UINF:-10}"
MESH_SCALE="${MESH_SCALE:-1}"

source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh" || exit 1
conda activate openfoam || exit 1
command -v simpleFoam > /dev/null || { echo "simpleFoam not on PATH after activating the openfoam env"; exit 1; }
# the conda package does not export FOAM_TUTORIALS
FOAM_TUTORIALS="${FOAM_TUTORIALS:-${CONDA_PREFIX}/tutorials}"

max_camber=$(awk '$2=="max_camber"{print $1}' params.in)
camber_position=$(awk '$2=="camber_position"{print $1}' params.in)
thickness=$(awk '$2=="thickness"{print $1}' params.in)
if [ -z "${max_camber}" ] || [ -z "${camber_position}" ] || [ -z "${thickness}" ]; then
    echo "params.in is missing max_camber, camber_position or thickness"
    exit 1
fi

# freestream vector and force directions from the angle of attack: the airfoil
# stays axis-aligned and the incidence lives in the far-field velocity
read -r ux uy lx ly <<< "$(python3 -c "
import math
a = math.radians(${ALPHA_DEG})
print('%.8f %.8f %.8f %.8f' % (${UINF} * math.cos(a), ${UINF} * math.sin(a),
                               -math.sin(a), math.cos(a)))")"

rm -rf case
cp -r "${FOAM_TUTORIALS}/incompressible/simpleFoam/airFoil2D" case
rm -rf case/constant/polyMesh.orig case/Allrun case/Allclean
mv case/0.orig case/0

python3 "${APP_DIR}/naca_blockmesh.py" \
    --camber "${max_camber}" --camber-pos "${camber_position}" \
    --thickness "${thickness}" --scale "${MESH_SCALE}" > case/system/blockMeshDict || exit 1

# write 0/U wholesale: a foamDictionary edit of internalField alone leaves the
# freestreamValue macros expanded to the tutorial's original velocity
cat > case/0/U << EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       volVectorField;
    object      U;
}

dimensions      [0 1 -1 0 0 0 0];

internalField   uniform (${ux} ${uy} 0);

boundaryField
{
    inlet
    {
        type            freestreamVelocity;
        freestreamValue \$internalField;
    }
    outlet
    {
        type            freestreamVelocity;
        freestreamValue \$internalField;
    }
    walls
    {
        type            noSlip;
    }
    frontAndBack
    {
        type            empty;
    }
}
EOF

# own controlDict: iteration cap (fvSolution's residualControl usually converges
# earlier) and the forceCoeffs function object that extracts the objectives
cat > case/system/controlDict << EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      controlDict;
}

application     simpleFoam;
startFrom       startTime;
startTime       0;
stopAt          endTime;
endTime         800;
deltaT          1;
writeControl    timeStep;
writeInterval   800;
purgeWrite      1;
writeFormat     ascii;
writePrecision  6;
timeFormat      general;
timePrecision   6;
runTimeModifiable true;

functions
{
    forceCoeffs1
    {
        type            forceCoeffs;
        libs            (forces);
        patches         (walls);
        rho             rhoInf;
        rhoInf          1;
        liftDir         (${lx} ${ly} 0);
        dragDir         ($(python3 -c "import math; a=math.radians(${ALPHA_DEG}); print('%.8f %.8f' % (math.cos(a), math.sin(a)))") 0);
        CofR            (0.25 0 0);
        pitchAxis       (0 0 1);
        magUInf         ${UINF};
        lRef            1;
        Aref            0.1;
        writeControl    timeStep;
        writeInterval   1;
        log             no;
    }
}
EOF

# a potentialFoam initial field is required: starting SIMPLE impulsively from a
# uniform freestream diverges on this C-mesh (verified: every uniform start blew
# up around iteration ~200; the potential start converges everywhere in the box)
foamDictionary -entry solvers.Phi -set '{solver GAMG; tolerance 1e-06; relTol 0.01; smoother GaussSeidel;}' case/system/fvSolution > /dev/null
foamDictionary -entry potentialFlow -set '{nNonOrthogonalCorrectors 10;}' case/system/fvSolution > /dev/null

if ! (cd case && blockMesh > log.blockMesh 2>&1 && potentialFoam > log.potentialFoam 2>&1 && simpleFoam > log.simpleFoam 2>&1); then
    echo "OpenFOAM failed for camber=${max_camber} pos=${camber_position} thickness=${thickness}; log tails:"
    tail -8 case/log.blockMesh case/log.potentialFoam case/log.simpleFoam 2>/dev/null
    exit 1
fi

python3 - << 'EOF'
import glob
import os
import sys

paths = sorted(glob.glob("case/postProcessing/forceCoeffs1/*/coefficient*.dat"))
if not paths:
    sys.exit("missing forceCoeffs output")
header, rows = None, []
with open(paths[-1]) as fh:
    for line in fh:
        if line.startswith("#"):
            header = line
        elif line.split():
            rows.append(line.split())
if not header or not rows:
    sys.exit("empty forceCoeffs output")
cols = header.lstrip("#").split()
icd, icl = cols.index("Cd"), cols.index("Cl")

# average the last 20% of iterations to smooth residual oscillation
tail = rows[-max(1, len(rows) // 5):]
cd = sum(float(r[icd]) for r in tail) / len(tail)
cl = sum(float(r[icl]) for r in tail) / len(tail)

with open("results.out.tmp", "w") as fh:
    fh.write("%.10f drag_coefficient\n%.10f neg_lift_coefficient\n" % (cd, -cl))
os.rename("results.out.tmp", "results.out")
print("Cd=%.6f Cl=%.6f (averaged over last %d iterations)" % (cd, cl, len(tail)))
EOF
