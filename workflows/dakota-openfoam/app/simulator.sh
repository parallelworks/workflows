#!/bin/bash
# OpenFOAM per-case driver, run inside one case directory: reads ./params.in (one
# "<value> <name>" line per design variable), builds a pitzDaily case with the
# proposed inlet velocity and viscosity, runs blockMesh + simpleFoam, and writes
# ./results.out (one "<value> <label>" line per objective, both minimized:
# f1 = kinematic pressure drop inlet->outlet, f2 = -average outlet speed).
# The write is atomic; on any error the process exits non-zero and leaves no
# results.out, which is the failure signal the optimizer understands.
set -o pipefail

SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
CONDA_PREFIX_DIR="${SOFTWARE_DIR}/dakota-openfoam/miniforge"

source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh" || exit 1
conda activate openfoam || exit 1
command -v simpleFoam > /dev/null || { echo "simpleFoam not on PATH after activating the openfoam env"; exit 1; }
# the conda package does not export FOAM_TUTORIALS
FOAM_TUTORIALS="${FOAM_TUTORIALS:-${CONDA_PREFIX}/tutorials}"

inlet_velocity=$(awk '$2=="inlet_velocity"{print $1}' params.in)
viscosity=$(awk '$2=="viscosity"{print $1}' params.in)
if [ -z "${inlet_velocity}" ] || [ -z "${viscosity}" ]; then
    echo "params.in is missing inlet_velocity or viscosity"
    exit 1
fi

# turbulence inlet values must scale with the inlet speed (5% intensity,
# mixing length 0.1 * the 25.4mm inlet height) or the solver destabilizes
# at the edges of the design space
read -r k epsilon <<< "$(python3 -c "
u = float('${inlet_velocity}')
k = 1.5 * (0.05 * u) ** 2
print('%.6g %.6g' % (k, 0.09 ** 0.75 * k ** 1.5 / 0.00254))")"

rm -rf case
cp -r "${FOAM_TUTORIALS}/incompressible/simpleFoam/pitzDaily" case

foamDictionary -entry boundaryField.inlet.value -set "uniform (${inlet_velocity} 0 0)" case/0/U > /dev/null
foamDictionary -entry nu -set "${viscosity}" case/constant/transportProperties > /dev/null
for entry in internalField boundaryField.inlet.value; do
    foamDictionary -entry "${entry}" -set "uniform ${k}" case/0/k > /dev/null
    foamDictionary -entry "${entry}" -set "uniform ${epsilon}" case/0/epsilon > /dev/null
done

# own controlDict: cap the iteration count (fvSolution's residualControl usually
# converges earlier) and extract the objectives as surfaceFieldValue functions
cat > case/system/controlDict << 'EOF'
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
endTime         600;
deltaT          1;
writeControl    timeStep;
writeInterval   600;
purgeWrite      1;
writeFormat     ascii;
writePrecision  6;
timeFormat      general;
timePrecision   6;
runTimeModifiable true;

functions
{
    inletAvgP
    {
        type            surfaceFieldValue;
        libs            (fieldFunctionObjects);
        regionType      patch;
        name            inlet;
        operation       areaAverage;
        fields          (p);
        writeFields     no;
        writeControl    timeStep;
        writeInterval   1;
        log             no;
    }
    outletAvgP
    {
        type            surfaceFieldValue;
        libs            (fieldFunctionObjects);
        regionType      patch;
        name            outlet;
        operation       areaAverage;
        fields          (p);
        writeFields     no;
        writeControl    timeStep;
        writeInterval   1;
        log             no;
    }
    outletAvgU
    {
        type            surfaceFieldValue;
        libs            (fieldFunctionObjects);
        regionType      patch;
        name            outlet;
        operation       areaAverage;
        fields          (U);
        writeFields     no;
        writeControl    timeStep;
        writeInterval   1;
        log             no;
    }
    inletAvgU
    {
        type            surfaceFieldValue;
        libs            (fieldFunctionObjects);
        regionType      patch;
        name            inlet;
        operation       areaAverage;
        fields          (U);
        writeFields     no;
        writeControl    timeStep;
        writeInterval   1;
        log             no;
    }
}
EOF

if ! (cd case && blockMesh > log.blockMesh 2>&1 && simpleFoam > log.simpleFoam 2>&1); then
    echo "OpenFOAM failed for inlet_velocity=${inlet_velocity} viscosity=${viscosity}; log tails:"
    tail -8 case/log.blockMesh case/log.simpleFoam 2>/dev/null
    exit 1
fi

python3 - << 'EOF'
import glob
import os
import re
import sys


def last_row(pattern):
    paths = sorted(glob.glob(pattern))
    if not paths:
        sys.exit("missing postProcessing output: %s" % pattern)
    with open(paths[-1]) as fh:
        rows = [line for line in fh if not line.startswith("#")]
    if not rows:
        sys.exit("empty postProcessing output: %s" % pattern)
    return rows[-1]


def mag(row):
    vx, vy, vz = (float(v) for v in re.search(r"\(([^)]*)\)", row).group(1).split())
    return (vx * vx + vy * vy + vz * vz) ** 0.5


p_in = float(last_row("case/postProcessing/inletAvgP/*/surfaceFieldValue*.dat").split()[-1])
p_out = float(last_row("case/postProcessing/outletAvgP/*/surfaceFieldValue*.dat").split()[-1])
u_in = mag(last_row("case/postProcessing/inletAvgU/*/surfaceFieldValue*.dat"))
u_out = mag(last_row("case/postProcessing/outletAvgU/*/surfaceFieldValue*.dat"))

# f1: kinematic TOTAL pressure drop (static p falls as the flow expands past the
# step, so static dp alone would be negative); f2: -outlet speed (maximize speed)
dp_total = (p_in + 0.5 * u_in ** 2) - (p_out + 0.5 * u_out ** 2)
with open("results.out.tmp", "w") as fh:
    fh.write("%.10f pressure_drop\n%.10f neg_outlet_speed\n" % (dp_total, -u_out))
os.rename("results.out.tmp", "results.out")
print("pressure_drop=%.6f neg_outlet_speed=%.6f" % (dp_total, -u_out))
EOF
