#!/bin/bash
# Usage: OUTPUTS=<file> read-results.sh <case_dir>
#
# The results step of every openfoam-naca variant, one script so that the YAMLs
# differ only where the platform does: reads the coefficients the case left in
# <case_dir>/results.out and publishes them, or fails the run when there is
# none, with the exit status and the log tails. Environment:
#   OUTPUTS          the file the workflow collects KEY=value outputs from
#   GENERATE_IMAGES  true: the images under <case_dir>/images are reported
#   MESH_SCALE       for the notice
#   RESTART_ATTEMPT  true when the run is one attempt of the resubmission loop
#                    (<variant>-restart.yaml): a simulator that ended on its own
#                    (an exit_code without results.out: a diverged solver,
#                    recorded in case/restart/failed, or a failure before the
#                    case was opened) is then final and the step completes, so
#                    the loop stops; a killed one (no exit_code) fails the step,
#                    so the loop resumes the case from its latest checkpoint
set -o pipefail
case_dir="$1"
if [ -z "${case_dir}" ] || [ -z "${OUTPUTS}" ]; then
    echo "::error::usage: OUTPUTS=<file> read-results.sh <case_dir>"
    exit 1
fi

if [ ! -f "${case_dir}/results.out" ]; then
    rc=$(cat "${case_dir}/exit_code" 2>/dev/null || echo "none: the case did not run to its end (killed, walltime, node lost)")
    if [ "${RESTART_ATTEMPT}" = true ] && [ -f "${case_dir}/exit_code" ]; then
        reason=$(cat "${case_dir}/case/restart/failed" 2>/dev/null || echo "exit status ${rc} before the case was opened: the inputs, or the environment on the node; its output follows")
        echo "::notice::no results.out: the simulator failed on its own, which is final (${reason}); this attempt completes so that the calling loop stops"
        tail -n 20 "${case_dir}"/case/log.* 2>/dev/null
        tail -n 30 "${case_dir}"/run.*.out 2>/dev/null
        exit 0
    fi
    echo "::error::no results.out in ${case_dir} (simulator exit code: ${rc}); log tails follow"
    [ -f "${case_dir}/attempts.log" ] && echo "last attempt: $(tail -n 1 "${case_dir}/attempts.log")"
    if [ "${RESTART_ATTEMPT}" = true ]; then
        echo "::notice::one attempt of a resubmission loop: this failure makes the calling loop resume the case from its latest complete checkpoint"
    fi
    tail -n 20 "${case_dir}"/case/log.* 2>/dev/null
    tail -n 30 "${case_dir}"/run.*.out 2>/dev/null
    exit 1
fi

cd_=$(awk '$2 == "drag_coefficient" {print $1}' "${case_dir}/results.out")
cl=$(awk '$2 == "neg_lift_coefficient" {printf "%.10f", -$1}' "${case_dir}/results.out")
{
    echo "DRAG_COEFFICIENT=${cd_}"
    echo "LIFT_COEFFICIENT=${cl}"
    echo "RESULTS_FILE=${case_dir}/results.out"
    echo "PARAVIEW_FILE=${case_dir}/case/case.foam"
} | tee -a "${OUTPUTS}"
# the images are a courtesy of a solved case: missing ones are a warning with
# the renderer's log, never a failed case
if [ "${GENERATE_IMAGES}" = true ]; then
    n=$(ls "${case_dir}"/images/*.png 2>/dev/null | wc -l)
    if [ "${n}" -gt 0 ]; then
        echo "IMAGES_DIR=${case_dir}/images" | tee -a "${OUTPUTS}"
        echo "::notice::${n} images of the fields in ${case_dir}/images: $(cd "${case_dir}/images" && ls *.png | tr '\n' ' ')"
    else
        echo "::warning::no images were rendered for the solved case; the renderer's log follows (${case_dir}/images/render.log)"
        tail -n 20 "${case_dir}/images/render.log" 2>/dev/null
    fi
fi
echo "::notice::Cd = ${cd_}, Cl = ${cl} for the design in ${case_dir}/params.in (mesh_scale ${MESH_SCALE:-?}); open ${case_dir}/case/case.foam in ParaView to see the fields"
