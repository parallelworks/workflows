#!/bin/bash
# OpenFOAM per-case driver, run inside one case directory: reads ./params.in (one
# "<value> <name>" line per design variable — the NACA 4-digit parameters
# max_camber, camber_position, thickness), builds a C-grid airfoil case from the
# airFoil2D tutorial (Spalart-Allmaras, freestream at ALPHA_DEG incidence,
# Re = 1e6), runs blockMesh + potentialFoam + simpleFoam, and writes
# ./results.out (one "<value> <label>" line per objective, both minimized:
# f1 = drag coefficient, f2 = -lift coefficient, from the forceCoeffs function
# object). The write is atomic; on any error the process exits non-zero and leaves
# no results.out, which is the failure signal. The solved case stays in ./case
# with an empty case/case.foam next to it, so it opens directly in ParaView; a
# decomposed case is reconstructed first.
#
# Environment: ALPHA_DEG (default 5) is the angle of attack. MESH_SCALE (default
# 1) multiplies every cell count — the cost dial. CORES_PER_CASE (default 1) > 1
# decomposes the mesh and runs the solvers under ${MPIRUN} (default `mpirun
# --bind-to none -np ${CORES_PER_CASE}`). OPENFOAM_ENV names a file sourced to
# put OpenFOAM (and mpirun) on PATH; unset, the conda env that
# install-openfoam.sh creates is activated. Every OpenFOAM step's full output
# goes to case/log.<step>; the short steps are also streamed to stdout, and the
# solver streams one progress line (iteration, pressure residual, Cd, Cl) every
# STREAM_EVERY iterations (default 50; 0 streams its whole log). DECOMP_METHOD
# (default hierarchical: x-strips) selects the decomposePar method.
set -o pipefail

SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
CONDA_PREFIX_DIR="${SOFTWARE_DIR}/openfoam-naca/miniforge"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

ALPHA_DEG="${ALPHA_DEG:-5}"
UINF="${UINF:-10}"
MESH_SCALE="${MESH_SCALE:-1}"
CORES_PER_CASE="${CORES_PER_CASE:-1}"

if [ -n "${OPENFOAM_ENV:-}" ]; then
    source "${OPENFOAM_ENV}" || { echo "sourcing ${OPENFOAM_ENV} failed"; exit 1; }
else
    source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh" || exit 1
    conda activate openfoam || exit 1
fi
command -v simpleFoam > /dev/null || { echo "simpleFoam not on PATH after loading the OpenFOAM environment (${OPENFOAM_ENV:-conda env openfoam})"; exit 1; }
STREAM_EVERY="${STREAM_EVERY:-50}"
# hierarchical x-strips, not scotch: the conda-forge scotch partitions differently
# on every run, and on this C-grid a marginal design then converges or diverges
# by the draw (1 divergence in 30 runs on the login node, more on the compute
# nodes); strips are deterministic and converged for every design tried
DECOMP_METHOD="${DECOMP_METHOD:-hierarchical}"

# --bind-to none: concurrent launchers on one node (the login-node mode runs
# batch_size cases at once) would otherwise all pin their ranks to the same first
# cores; the sourced environment may export MPIRUN to replace the launcher
LAUNCH=()
PARALLEL=()
if [ "${CORES_PER_CASE}" -gt 1 ]; then
    MPIRUN="${MPIRUN:-mpirun --bind-to none -np ${CORES_PER_CASE}}"
    read -r -a LAUNCH <<< "${MPIRUN}"
    PARALLEL=(-parallel)
    command -v "${LAUNCH[0]}" > /dev/null || { echo "${LAUNCH[0]} not on PATH: the OpenFOAM environment must provide the MPI launcher when CORES_PER_CASE > 1"; exit 1; }
fi

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

# the static case files are versioned with the workflow; only what depends on
# the design point is generated: blockMeshDict, 0/U and controlDict
rm -rf case
cp -r "${APP_DIR}/openfoam-case" case

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

# finer meshes converge more slowly (information travels cell by cell) and are
# less forgiving of aggressive relaxation: scale the iteration cap with the mesh
# and soften the relaxation beyond the base mesh
END_TIME=$((800 * MESH_SCALE))
if [ "${MESH_SCALE}" -ge 2 ]; then
    foamDictionary -entry relaxationFactors.fields.p -set 0.25 case/system/fvSolution > /dev/null
    foamDictionary -entry relaxationFactors.equations.U -set 0.5 case/system/fvSolution > /dev/null
    foamDictionary -entry relaxationFactors.equations.nuTilda -set 0.5 case/system/fvSolution > /dev/null
fi

if [ "${CORES_PER_CASE}" -gt 1 ]; then
    coeffs=""
    case "${DECOMP_METHOD}" in
        hierarchical|simple)
            coeffs=$(printf 'coeffs\n{\n    n           (%d 1 1);\n    order       xyz;\n}\n' "${CORES_PER_CASE}") ;;
    esac
    cat > case/system/decomposeParDict << EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${CORES_PER_CASE};
method          ${DECOMP_METHOD};
${coeffs}
EOF
fi

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
endTime         ${END_TIME};
deltaT          1;
writeControl    timeStep;
writeInterval   ${END_TIME};
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
        log             yes;
    }
}
EOF

foam_step() {
    local name="$1"
    shift
    echo "--- ${name}: $*"
    (cd case && "$@" 2>&1 | tee "log.${name}")
}

# the solver's log runs to thousands of iterations: keep it whole in
# case/log.simpleFoam and stream a progress line every STREAM_EVERY iterations
# (the forceCoeffs function object logs Cd/Cl each iteration), plus anything
# that looks like an ending or a crash
foam_solve() {
    local name="$1"
    shift
    echo "--- ${name}: $* (progress every ${STREAM_EVERY} iterations; full log in case/log.${name})"
    if [ "${STREAM_EVERY}" -eq 0 ]; then
        foam_step "${name}" "$@"
        return
    fi
    (cd case && "$@" 2>&1 | tee "log.${name}" | awk -v every="${STREAM_EVERY}" '
        /^(Exec|Host|nProcs) +:/ { print; fflush(); next }
        /^Time = / { t = $3; p = ""; next }
        /Solving for p,/ && p == "" { p = $8; sub(/,$/, "", p); next }
        /^[ \t]*Cd:/ { cd = $2; next }
        /^[ \t]*Cl:/ { cl = $2; next }
        /^ExecutionTime/ { if (t % every == 0) { printf("iter %6d  p residual %-12s Cd %-10s Cl %s\n", t, p, cd, cl); fflush() } next }
        /converged in|FOAM FATAL|FOAM Warning|sigFpe|Floating point|BAD TERMINATION|^End$/ { print; fflush() }
    ')
}

# the potentialFoam initial field is required: starting SIMPLE impulsively from
# a uniform freestream diverges on this C-mesh (see fvSolution's Phi block).
# In parallel the forceCoeffs output still lands in case/postProcessing, so the
# objectives need no reconstructPar.
if ! { foam_step blockMesh blockMesh \
        && { [ "${CORES_PER_CASE}" -eq 1 ] || foam_step decomposePar decomposePar; } \
        && foam_step potentialFoam "${LAUNCH[@]}" potentialFoam "${PARALLEL[@]}" \
        && foam_solve simpleFoam "${LAUNCH[@]}" simpleFoam "${PARALLEL[@]}"; }; then
    echo "OpenFOAM failed for camber=${max_camber} pos=${camber_position} thickness=${thickness} (${CORES_PER_CASE} core(s)); log tails:"
    # -n: coreutils rejects the short `tail -8 f1 f2` form with several files
    tail -n 20 case/log.blockMesh case/log.decomposePar case/log.potentialFoam case/log.simpleFoam 2>/dev/null
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
print("Cd=%.6f Cl=%.6f (averaged over last %d iterations, %s core(s))"
      % (cd, cl, len(tail), os.environ.get("CORES_PER_CASE", "1")))
EOF

# the objectives are safe on disk: everything below only makes the case open in
# ParaView — reconstruct a decomposed case (the reader handles processor*
# directories too, as a "Decomposed Case") and leave the empty .foam file the
# OpenFOAM reader keys on
if [ "${CORES_PER_CASE}" -gt 1 ]; then
    if ! foam_step reconstructPar reconstructPar -latestTime; then
        echo "::warning::reconstructPar failed; open case/case.foam in ParaView as a Decomposed Case (tail of case/log.reconstructPar follows)"
        tail -n 10 case/log.reconstructPar
    fi
fi
touch case/case.foam
echo "case ready for ParaView: $(pwd)/case/case.foam"
