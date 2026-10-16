#!/bin/bash
# Usage: OUTPUTS=<file> restart-prepare.sh    (run from the job directory)
#
# The preprocessing step of the restart variants (<variant>-restart.yaml), one
# script for the three: checks the loop's inputs and names the case directory
# every attempt works on, published as CASE_DIR. Nothing else is needed before
# the loop: every attempt checks out the app, prepares the OpenFOAM environment
# and creates the case itself, in the case variant's own preprocessing.
# Environment, the form's values:
#   MAX_RESTARTS, ATTEMPT_TIMEOUT, CHECKPOINT_EVERY, KEEP_CHECKPOINTS, CORES_PER_CASE
#   CASE_DIR   absolute path of the case directory; empty: <job dir>/case
#   OUTPUTS    the file the workflow collects KEY=value outputs from
set -o pipefail
set -x
if [ -z "${OUTPUTS}" ]; then
    echo "::error::usage: OUTPUTS=<file> restart-prepare.sh"
    exit 1
fi
# the API passes values the form forbids through unchanged: with no checkpoints
# every attempt would start over from iteration 0
for pair in "max_restarts=${MAX_RESTARTS}:0" "checkpoint_every=${CHECKPOINT_EVERY}:1" \
            "keep_checkpoints=${KEEP_CHECKPOINTS}:1" "cores_per_case=${CORES_PER_CASE}:1"; do
    name="${pair%%=*}"; value="${pair#*=}"; min="${value##*:}"; value="${value%:*}"
    if ! [[ "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt "${min}" ]; then
        echo "::error::${name} must be an integer of at least ${min}, got '${value}'"
        exit 1
    fi
done
if ! [[ "${ATTEMPT_TIMEOUT}" =~ ^[0-9]+(s|m|h|d)$ ]]; then
    echo "::error::restart.attempt_timeout must be a number with a unit (30s, 10m, 2h, 1d), got '${ATTEMPT_TIMEOUT}'"
    exit 1
fi
# the case directory every attempt works on: this run's, or an earlier run's to
# continue its case (resume only keeps a case built from the same design and
# settings; anything else starts over there)
case_dir="${CASE_DIR}"
case "${case_dir}" in
    ''|undefined) case_dir="${PWD}/case" ;;
esac
mkdir -p "${case_dir}" || exit 1
if [ -f "${case_dir}/attempts.log" ]; then
    echo "::notice::${case_dir} has $(grep -c '  start  ' "${case_dir}/attempts.log") attempts recorded already; the case there is continued when it matches this design and these settings"
    cat "${case_dir}/attempts.log"
fi
echo "::notice::up to $(( MAX_RESTARTS + 1 )) attempts of ${ATTEMPT_TIMEOUT} each on ${case_dir}; checkpoints every ${CHECKPOINT_EVERY} iterations, the last ${KEEP_CHECKPOINTS} kept"
echo "CASE_DIR=${case_dir}" | tee -a "${OUTPUTS}"
