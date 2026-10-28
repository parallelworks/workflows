#!/bin/bash
# The start script of one PROBE dashboard, submitted through script_submitter from
# <job dir>/dashboard (the read-only one) or <job dir>/admin: the directory it runs in
# names the dashboard, ../probe.env (written by setup.sh and credential.sh) holds the
# rest. Serves until the endpoint is deleted. No set -x: the API key would show.
kind=$(basename "$PWD")
case "${kind}" in
    dashboard) name="probe-${PW_RUN_SLUG}"; flag="" ;;
    admin) name="probe-admin-${PW_RUN_SLUG}"; flag="--admin" ;;
    *) echo "::error title=Error::start-dashboard.sh runs from <job dir>/dashboard or <job dir>/admin, not from $PWD"; exit 1 ;;
esac
source ../probe.env
job_dir=$(cd .. && pwd)
export PATH=$HOME/pw:$PATH
export PYTHONPATH=${job_dir}/workflows/probe/app
export PW_PLATFORM_HOST PW_USER
# The run's own PW_API_KEY stops working when the run completes
case "${PROBE_AUTH}" in
    key) export PW_API_KEY="${PROBE_API_KEY}" ;;
    host) unset PW_API_KEY ;;
    *) echo "::error title=Error::No credential decided for ${name} (PROBE_AUTH=${PROBE_AUTH})"; exit 1 ;;
esac
echo "pw endpoints delete ${name} || true" > cancel.sh
chmod +x cancel.sh
cd "${job_dir}"
echo "::notice::Starting endpoint ${name}"
pw endpoints run --name ${name} -o text -- \
    python3 -u -m probe serve ${flag} --port {port} --prefix {path} --results "${RESULTS_DIR}" --tests tests \
        ${RESULTS_BUCKET:+--bucket "${RESULTS_BUCKET}"} \
        --tests-repo "${TESTS_REPO}" --tests-branch "${TESTS_BRANCH}" --tests-directory "${TESTS_DIR}"
if [ $? -ne 0 ]; then
    # pw endpoints run blocks for the life of the endpoint, so it also exits non-zero
    # when this job is cancelled after a successful start. Only a start that never
    # registered its endpoint is a failure.
    if pw endpoints list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qxF "${name}"; then
        echo "::notice::Endpoint ${name} served until this job was cancelled"
        exit 0
    fi
    echo "::error title=Error::pw endpoints run failed for ${name}"
    exit 1
fi
