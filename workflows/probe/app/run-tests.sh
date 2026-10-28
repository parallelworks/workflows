#!/bin/bash
# Runs the tests named in selection.txt (all, or test definition files relative to the
# tests directory, one per line or space separated) once, from the job directory set up
# by setup.sh. A failed test is a result, recorded and shown on the dashboard, so it is
# reported as a warning; the run ends in error only when PROBE could not run the tests
# or record their results.
set -o pipefail
set -x
source probe.env
export PATH=$HOME/pw:$PATH
export PYTHONPATH=$PWD/workflows/probe/app
ARGS=""
if [ -z "$(tr -d '[:space:]' < selection.txt)" ] || grep -qx '[[:space:]]*\(all\|undefined\)[[:space:]]*' selection.txt; then
    ARGS="--all"
else
    for f in $(cat selection.txt); do ARGS="${ARGS} --test ${f}"; done
fi
echo "::notice::python3 -m probe run --tests tests --results ${RESULTS_DIR} ${RESULTS_BUCKET:+--bucket ${RESULTS_BUCKET}} ${ARGS}"
python3 -u -m probe run --tests tests --results "${RESULTS_DIR}" ${RESULTS_BUCKET:+--bucket "${RESULTS_BUCKET}"} ${ARGS} 2>&1 | tee probe-run.log
rc=${PIPESTATUS[0]}
summary=$(grep -E '^[0-9:]+ summary: ' probe-run.log | tail -1 | cut -d' ' -f2-)
if [ -n "${summary}" ]; then echo "::notice title=PROBE::${summary}"; fi
sed -n '/ summary: /,$p' probe-run.log | grep -E '^[0-9:]+ +FAIL ' \
    | while read -r _ _ id rest; do echo "::warning title=Test failed::${id} ${rest}"; done
# probe run exits 1 when a test failed and 2 when it could not run or record the
# tests (invalid definition, bad selection, bucket upload)
case "${rc}" in
    0|1) ;;
    *) echo "::error title=PROBE failed::exit ${rc}: the tests could not be run or their results not recorded; see above"
       exit "${rc}" ;;
esac
