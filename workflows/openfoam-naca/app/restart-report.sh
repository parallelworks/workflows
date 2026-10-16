#!/bin/bash
# Usage: OUTPUTS=<file> restart-report.sh <case_dir>
#
# The Report step of the restart variants (<variant>-restart.yaml), one script
# for the three, run with if: always: the run's verdict comes from the case
# directory, never from how the retried Solve step ended. Solved is the only
# success, whether the loop stopped by decision or by exhausting its retries;
# the failures are told apart: the case failed on its own (a diverged solver,
# final), the simulator failed before opening the case (the inputs, the node's
# environment: final), no attempt ever ran the simulator (the case workflow
# failed before it), or the case is still interrupted after the attempts ran
# out (resumable: a later run given this directory continues it).
# Environment: OUTPUTS (the file the workflow collects KEY=value outputs from),
# MAX_RESTARTS and MESH_SCALE (for the messages).
set -o pipefail
set -x
case_dir="$1"
if [ -z "${case_dir}" ] || [ -z "${OUTPUTS}" ]; then
    echo "::error::usage: OUTPUTS=<file> restart-report.sh <case_dir>"
    exit 1
fi
log="${case_dir}/attempts.log"
echo "--- ${log}"
cat "${log}" 2>/dev/null || echo "(no attempt ran the simulator)"
attempts=$(awk '$2 == "attempt" && $4 == "start" {n = $3} END {print n + 0}' "${log}" 2>/dev/null)
interruptions=$(awk '$2 == "attempt" && $4 == "end" && $5 == "interrupted" {n++} END {print n + 0}' "${log}" 2>/dev/null)
{
    echo "ATTEMPTS=${attempts:-0}"
    echo "INTERRUPTIONS=${interruptions:-0}"
    echo "CASE_DIR=${case_dir}"
} | tee -a "${OUTPUTS}"
if [ -f "${case_dir}/case/restart/failed" ]; then
    echo "::error::the case failed on its own, which is final (not an interruption, so no attempt solved it again): $(cat "${case_dir}/case/restart/failed"); ${interruptions:-0} interruption(s) before that over ${attempts:-0} attempt(s). The solver's logs are ${case_dir}/case/log.simpleFoam*; to start over, change the design or remove ${case_dir}/case"
    exit 1
fi
if [ -f "${case_dir}/results.out" ] && [ -f "${case_dir}/case/restart/simpleFoam.done" ]; then
    cd_=$(awk '$2 == "drag_coefficient" {print $1}' "${case_dir}/results.out")
    cl=$(awk '$2 == "neg_lift_coefficient" {printf "%.10f", -$1}' "${case_dir}/results.out")
    {
        echo "DRAG_COEFFICIENT=${cd_}"
        echo "LIFT_COEFFICIENT=${cl}"
        echo "PARAVIEW_FILE=${case_dir}/case/case.foam"
    } | tee -a "${OUTPUTS}"
    echo "::notice::solved in ${attempts} attempt(s), ${interruptions} of them interrupted and resumed from a checkpoint: Cd = ${cd_}, Cl = ${cl} (mesh_scale ${MESH_SCALE:-?}). The history is ${log}; open ${case_dir}/case/case.foam in ParaView to see the fields. Should the Solve step show as failed anyway, the budget cut its last allowed attempt after the solve: the result stands"
    exit 0
fi
# the last attempt's simulator ended on its own without opening the case (an
# exit_code, no failed record): a bad input or the environment on the node,
# which no retry would fix and the loop therefore stopped on
if [ -f "${case_dir}/exit_code" ]; then
    echo "::error::the last attempt's simulator failed before the case was opened (exit status $(cat "${case_dir}/exit_code")): not an interruption, so the loop stopped. Read the Solve step's logs (the OpenFOAM environment on the node, the inputs); ${attempts:-0} attempt(s), ${interruptions:-0} interrupted"
    exit 1
fi
if [ "${attempts:-0}" -eq 0 ]; then
    echo "::error::no attempt ran the simulator: the case workflow failed before it every time (its checkout, the OpenFOAM environment commands, the inputs). Read the Solve step's logs; nothing here is resumable"
    exit 1
fi
echo "::error::not solved: the attempts ran out (${attempts} made, ${interruptions:-0} interrupted; max_restarts ${MAX_RESTARTS:-?}) with the case still interrupted. The case is resumable: run this workflow again with case.case_dir = ${case_dir}, or raise max_restarts, attempt_timeout or the walltime"
exit 1
