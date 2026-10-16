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
# --bind-to none -np <ranks>`); the ranks are capped so that each keeps at least
# MIN_CELLS_PER_RANK cells (default 1000, 0 disables the cap): 16 ranks on the
# 5400-cell base mesh diverged for a marginal design that converged serially, on
# 4 ranks and on 16 ranks of a finer mesh (Nautilus, 2026-10-05). A user-set
# MPIRUN carries its own rank count, so it is only warned about, never changed.
# OPENFOAM_ENV names a file sourced to
# put OpenFOAM (and mpirun) on PATH; unset, the conda env that
# install-openfoam.sh creates is activated. Every OpenFOAM step's full output
# goes to case/log.<step>; the short steps are also streamed to stdout, and the
# solver streams one progress line (iteration, pressure residual, Cd, Cl) every
# STREAM_EVERY iterations (default 50; 0 streams its whole log). DECOMP_METHOD
# (default hierarchical: x-strips) selects the decomposePar method.
#
# Checkpoints and resuming (restart.sh, sourced below, has the mechanics and the
# state files): CHECKPOINT_EVERY (default 0: only the last iteration is written)
# makes simpleFoam write its fields every N iterations, keeping the last
# KEEP_CHECKPOINTS (default 2) of them. RESUME=true continues a ./case built from
# the same design and settings: the mesh, the decomposition and the potentialFoam
# initialization are kept once done, simpleFoam restarts from its latest complete
# checkpoint, a solved case is not solved again and neither is one whose solver
# failed on its own; a case built from other inputs starts over. Every run is one
# attempt in ./attempts.log, and a signal (the scheduler's walltime, a cancel)
# ends the attempt as interrupted, exit status 128 + signal, for the next one to
# continue. Without RESUME the case always starts from scratch.
set -o pipefail

SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
CONDA_PREFIX_DIR="${SOFTWARE_DIR}/openfoam-naca/miniforge"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

ALPHA_DEG="${ALPHA_DEG:-5}"
UINF="${UINF:-10}"
MESH_SCALE="${MESH_SCALE:-1}"
CORES_PER_CASE="${CORES_PER_CASE:-1}"
RESUME="${RESUME:-false}"
CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-0}"
KEEP_CHECKPOINTS="${KEEP_CHECKPOINTS:-2}"
for v in CHECKPOINT_EVERY KEEP_CHECKPOINTS; do
    if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
        echo "${v} must be a non-negative integer, got '${!v}'"
        exit 1
    fi
done
[ "${KEEP_CHECKPOINTS}" -ge 1 ] || KEEP_CHECKPOINTS=1

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

# the launcher is checked before any work is done; the rank count is settled after
# blockMesh, from the cell count
if [ "${CORES_PER_CASE}" -gt 1 ]; then
    launcher="${MPIRUN:-mpirun}"
    command -v "${launcher%% *}" > /dev/null || { echo "${launcher%% *} not on PATH: the OpenFOAM environment must provide the MPI launcher when CORES_PER_CASE > 1"; exit 1; }
fi
MIN_CELLS_PER_RANK="${MIN_CELLS_PER_RANK:-1000}"

max_camber=$(awk '$2=="max_camber"{print $1}' params.in)
camber_position=$(awk '$2=="camber_position"{print $1}' params.in)
thickness=$(awk '$2=="thickness"{print $1}' params.in)
if [ -z "${max_camber}" ] || [ -z "${camber_position}" ] || [ -z "${thickness}" ]; then
    echo "params.in is missing max_camber, camber_position or thickness"
    exit 1
fi
# params.in may carry the angle too (the workflow writes it there; an optimizer
# treating the incidence as a design variable would as well): the file wins
alpha_in_file=$(awk '$2=="angle_of_attack"{print $1}' params.in)
if [ -n "${alpha_in_file}" ]; then
    ALPHA_DEG="${alpha_in_file}"
fi
echo "design: camber=${max_camber} pos=${camber_position} thickness=${thickness} alpha=${ALPHA_DEG} deg (mesh_scale ${MESH_SCALE}, ${CORES_PER_CASE} core(s))"

# freestream vector and force directions from the angle of attack: the airfoil
# stays axis-aligned and the incidence lives in the far-field velocity
read -r ux uy lx ly <<< "$(python3 -c "
import math
a = math.radians(${ALPHA_DEG})
print('%.8f %.8f %.8f %.8f' % (${UINF} * math.cos(a), ${UINF} * math.sin(a),
                               -math.sin(a), math.cos(a)))")"

# the case is continued or started over (restart.sh decides from these inputs,
# the ones that decide the solution). The static case files are versioned with
# the workflow and (re)written on every attempt with what depends on the design
# point: blockMeshDict, 0/U and controlDict. The initial fields are only
# rewritten while potentialFoam has not run on them, and with them goes a
# decomposition made before it, so that no stage ever starts from a file a kill
# cut short
source "${APP_DIR}/restart.sh"
restart_begin "$(printf '%s\n' \
    "max_camber ${max_camber}" "camber_position ${camber_position}" \
    "thickness ${thickness}" "angle_of_attack ${ALPHA_DEG}" "uinf ${UINF}" \
    "mesh_scale ${MESH_SCALE}" "cores_per_case ${CORES_PER_CASE}" \
    "min_cells_per_rank ${MIN_CELLS_PER_RANK}" "decomp_method ${DECOMP_METHOD}" \
    "mpirun ${MPIRUN:-}")"
mkdir -p case
cp -r "${APP_DIR}/openfoam-case/constant" "${APP_DIR}/openfoam-case/system" case/
if ! stage_done potentialFoam; then
    rm -rf case/0 case/processor[0-9]* "${RESTART_DIR}/decomposePar.done"
    cp -r "${APP_DIR}/openfoam-case/0" case/
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
fi

python3 "${APP_DIR}/naca_blockmesh.py" \
    --camber "${max_camber}" --camber-pos "${camber_position}" \
    --thickness "${thickness}" --scale "${MESH_SCALE}" > case/system/blockMeshDict || exit 1

# finer meshes converge more slowly (information travels cell by cell) and are
# less forgiving of aggressive relaxation: scale the iteration cap with the mesh
# and soften the relaxation beyond the base mesh
END_TIME=$((800 * MESH_SCALE))
if [ "${MESH_SCALE}" -ge 2 ]; then
    foamDictionary -entry relaxationFactors.fields.p -set 0.25 case/system/fvSolution > /dev/null
    foamDictionary -entry relaxationFactors.equations.U -set 0.5 case/system/fvSolution > /dev/null
    foamDictionary -entry relaxationFactors.equations.nuTilda -set 0.5 case/system/fvSolution > /dev/null
fi

# own controlDict: iteration cap (fvSolution's residualControl usually converges
# earlier), the checkpoints (the fields every CHECKPOINT_EVERY iterations, the
# last KEEP_CHECKPOINTS kept; without, only the last iteration), where a resumed
# case starts (latestTime: its latest checkpoint, 0 on a fresh case) and the
# forceCoeffs function object that extracts the objectives
START_FROM=startTime
[ "${RESUME}" = true ] && START_FROM=latestTime
WRITE_INTERVAL="${END_TIME}"
[ "${CHECKPOINT_EVERY}" -gt 0 ] && WRITE_INTERVAL="${CHECKPOINT_EVERY}"
cat > case/system/controlDict << EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      controlDict;
}

application     simpleFoam;
startFrom       ${START_FROM};
startTime       0;
stopAt          endTime;
endTime         ${END_TIME};
deltaT          1;
writeControl    timeStep;
writeInterval   ${WRITE_INTERVAL};
purgeWrite      ${KEEP_CHECKPOINTS};
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

# a stage that did not return 0: an interruption ends the attempt here (exit
# 128 + signal, for the next attempt to continue); a tool failing on its own is
# recorded as final and the case fails
f_failed() {
    restart_failed "$1" "$2"
    echo "OpenFOAM failed for camber=${max_camber} pos=${camber_position} thickness=${thickness} (${RANKS:-${CORES_PER_CASE}} rank(s)); log tails:"
    # -n: coreutils rejects the short `tail -8 f1 f2` form with several files
    tail -n 20 case/log.blockMesh case/log.decomposePar case/log.potentialFoam case/log.simpleFoam 2>/dev/null
    exit 1
}

# every tool runs through run_interruptible, in the background, so a signal
# stops it at once and the stage stays unfinished for the next attempt
if stage_done blockMesh; then
    echo "--- blockMesh: kept (done on $(stage_by blockMesh))"
else
    run_interruptible foam_step blockMesh blockMesh || f_failed blockMesh $?
    stage_mark blockMesh
fi

# the rank count: the request, capped so that every rank keeps MIN_CELLS_PER_RANK
# cells (the header has the measurements behind the floor)
n_cells=$(awk '/^ *nCells:/ {print $2; exit}' case/log.blockMesh)
RANKS="${CORES_PER_CASE}"
if [ "${CORES_PER_CASE}" -gt 1 ] && [ -n "${n_cells}" ] && [ "${MIN_CELLS_PER_RANK}" -gt 0 ]; then
    max_ranks=$(( n_cells / MIN_CELLS_PER_RANK ))
    [ "${max_ranks}" -ge 1 ] || max_ranks=1
    if [ "${CORES_PER_CASE}" -gt "${max_ranks}" ]; then
        if [ -n "${MPIRUN:-}" ]; then
            echo "::warning::${n_cells} cells over ${CORES_PER_CASE} ranks leave $(( n_cells / CORES_PER_CASE )) cells per rank, below the floor of ${MIN_CELLS_PER_RANK}; MPIRUN is set, so the rank count is yours, and a marginal design may diverge: lower CORES_PER_CASE or raise MESH_SCALE"
        else
            echo "::notice::${n_cells} cells over ${CORES_PER_CASE} ranks would leave $(( n_cells / CORES_PER_CASE )) cells per rank; running on ${max_ranks} rank(s) instead (floor MIN_CELLS_PER_RANK=${MIN_CELLS_PER_RANK}): raise MESH_SCALE to use more cores"
            RANKS="${max_ranks}"
        fi
    fi
fi
export RANKS

# --bind-to none: concurrent launchers on one node (the login-node mode runs
# batch_size cases at once) would otherwise all pin their ranks to the same first
# cores; the sourced environment may export MPIRUN to replace the launcher
LAUNCH=()
PARALLEL=()
if [ "${RANKS}" -gt 1 ]; then
    read -r -a LAUNCH <<< "${MPIRUN:-mpirun --bind-to none -np ${RANKS}}"
    PARALLEL=(-parallel)
    coeffs=""
    case "${DECOMP_METHOD}" in
        hierarchical|simple)
            coeffs=$(printf 'coeffs\n{\n    n           (%d 1 1);\n    order       xyz;\n}\n' "${RANKS}") ;;
    esac
    cat > case/system/decomposeParDict << EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${RANKS};
method          ${DECOMP_METHOD};
${coeffs}
EOF
    if stage_done decomposePar; then
        n_proc=$(ls -d case/processor[0-9]* 2>/dev/null | wc -l)
        if [ "${n_proc}" -ne "${RANKS}" ]; then
            echo "the case is decomposed into ${n_proc} parts but ${RANKS} ranks were settled from the same inputs; remove ${PWD}/case to start over"
            exit 1
        fi
        echo "--- decomposePar: kept (done on $(stage_by decomposePar), ${RANKS} parts)"
    else
        run_interruptible foam_step decomposePar decomposePar || f_failed decomposePar $?
        stage_mark decomposePar
    fi
fi

# the potentialFoam initial field is required: starting SIMPLE impulsively from
# a uniform freestream diverges on this C-mesh (see fvSolution's Phi block).
# In parallel the forceCoeffs output still lands in case/postProcessing, so the
# objectives need no reconstructPar.
if stage_done potentialFoam; then
    echo "--- potentialFoam: kept (done on $(stage_by potentialFoam))"
else
    run_interruptible foam_step potentialFoam "${LAUNCH[@]}" potentialFoam "${PARALLEL[@]}" || f_failed potentialFoam $?
    stage_mark potentialFoam
fi

if stage_done simpleFoam; then
    echo "--- simpleFoam: kept (done on $(stage_by simpleFoam)); only the results are extracted again"
else
    # the checkpoint the solver continues from, once the incomplete ones are
    # discarded; the previous attempt's solver log is kept under its number
    latest=$(restart_checkpoints)
    if [ -f case/log.simpleFoam ] && [ -f "${RESTART_DIR}/solver.attempt" ]; then
        mv case/log.simpleFoam "case/log.simpleFoam.$(cat "${RESTART_DIR}/solver.attempt")"
    fi
    echo "${ATTEMPT}" > "${RESTART_DIR}/solver.attempt"
    if [ "${latest}" != 0 ]; then
        echo "--- simpleFoam: resuming from checkpoint ${latest} of ${END_TIME} iterations (attempt ${ATTEMPT})"
    fi
    run_interruptible foam_solve simpleFoam "${LAUNCH[@]}" simpleFoam "${PARALLEL[@]}"
    rc=$?
    # a signal that came as the solver ended on its own still marks the stage
    # done: the next attempt extracts the results instead of solving again
    [ "${rc}" -eq 0 ] && stage_mark simpleFoam
    { [ "${rc}" -eq 0 ] && [ -z "${INTERRUPTED}" ]; } || f_failed simpleFoam "${rc}"
    # the solver only purges what it wrote itself: the earlier attempts'
    # checkpoints go now, so the last KEEP_CHECKPOINTS remain whatever the history
    restart_checkpoints > /dev/null
fi

python3 - << 'EOF'
import glob
import os
import sys

# one coefficient file per start of the solver, in a directory named after its
# start iteration: a resumed case has several, and the iterations after a
# checkpoint were solved again, so the later file wins
paths = glob.glob("case/postProcessing/forceCoeffs1/*/coefficient*.dat")
if not paths:
    sys.exit("missing forceCoeffs output")
paths.sort(key=lambda p: float(os.path.basename(os.path.dirname(p))))
header, rows = None, {}
for path in paths:
    with open(path) as fh:
        for line in fh:
            if line.startswith("#"):
                header = line
            elif line.split():
                parts = line.split()
                rows[float(parts[0])] = parts
if not header or not rows:
    sys.exit("empty forceCoeffs output")
cols = header.lstrip("#").split()
icd, icl = cols.index("Cd"), cols.index("Cl")

# average the last 20% of iterations to smooth residual oscillation
ordered = [rows[t] for t in sorted(rows)]
tail = ordered[-max(1, len(ordered) // 5):]
cd = sum(float(r[icd]) for r in tail) / len(tail)
cl = sum(float(r[icl]) for r in tail) / len(tail)

with open("results.out.tmp", "w") as fh:
    fh.write("%.10f drag_coefficient\n%.10f neg_lift_coefficient\n" % (cd, -cl))
os.rename("results.out.tmp", "results.out")
print("Cd=%.6f Cl=%.6f (averaged over last %d of %d iterations, %s rank(s))"
      % (cd, cl, len(tail), len(ordered), os.environ.get("RANKS", "1")))
EOF
[ -f results.out ] || f_failed results 1
restart_log "${ATTEMPT}" end "solved: $(awk 'NR == 1 {cd = $1} NR == 2 {cl = -$1} END {printf "Cd %.6f Cl %.6f", cd, cl}' results.out) at iteration $(restart_iteration) ($(cat case/log.simpleFoam* 2>/dev/null | grep -c '^Time = ') solved over all attempts); simpleFoam done on $(stage_by simpleFoam)"

# the objectives are safe on disk: everything below only makes the case open in
# ParaView — reconstruct a decomposed case (the reader handles processor*
# directories too, as a "Decomposed Case") and leave the empty .foam file the
# OpenFOAM reader keys on
if [ "${RANKS}" -gt 1 ]; then
    if ! foam_step reconstructPar reconstructPar -latestTime; then
        echo "::warning::reconstructPar failed; open case/case.foam in ParaView as a Decomposed Case (tail of case/log.reconstructPar follows)"
        tail -n 10 case/log.reconstructPar
    fi
fi
touch case/case.foam
echo "case ready for ParaView: $(pwd)/case/case.foam"
