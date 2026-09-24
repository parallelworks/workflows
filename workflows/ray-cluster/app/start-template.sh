################################################################################
# Ray cluster supervisor: Ray head + dashboard endpoint + worker dispatch.
#
# Runs on the head resource's login node under script_submitter, after
# inputs.sh and the generic cleanup trap. The process tree owned by
# `pw endpoints run` is the cluster's lifetime: `pw endpoints delete` (or a
# dead Ray head) ends it, this script returns, and the trap runs cancel.sh.
#
# inputs.sh variables: ray_version, endpoint_name, head_resource_name,
# workload_type; the worker rows are in ${PW_PARENT_JOB_DIR}/workers.json.
################################################################################
JOB_DIR="${PW_PARENT_JOB_DIR%/}"
APP_DIR="${JOB_DIR}/workflows/ray-cluster/app"
mkdir -p "${JOB_DIR}/logs"

# cancel.sh first: script_submitter runs it when the run is cancelled before the
# endpoint is up, the trap runs it when this script exits. The teardown cancels
# jobs on remote sites over ssh, so it runs detached from the tree being killed.
cat > cancel.sh <<CANCEL
#!/bin/bash
if command -v setsid >/dev/null 2>&1; then
    setsid bash "${APP_DIR}/teardown.sh" "${JOB_DIR}" >> "${JOB_DIR}/logs/teardown.log" 2>&1 < /dev/null &
else
    nohup bash "${APP_DIR}/teardown.sh" "${JOB_DIR}" >> "${JOB_DIR}/logs/teardown.log" 2>&1 < /dev/null &
fi
echo "Teardown started: ${JOB_DIR}/logs/teardown.log"
CANCEL
chmod +x cancel.sh

export RAY_VERSION="${ray_version}"
export RAY_ENDPOINT_NAME="${endpoint_name}"
export HEAD_RESOURCE_NAME="${head_resource_name}"
export WORKLOAD_TYPE="${workload_type}"
export WORKERS_JSON="$(cat "${JOB_DIR}/workers.json" 2>/dev/null || echo '[]')"

bash "${APP_DIR}/start_ray_head.sh"
rc=$?
# start_ray_head.sh returns once the endpoint wrapper is gone: deleted with
# pw endpoints delete, killed by the Ray health monitor, or never started.
if [ ${rc} -ne 0 ]; then
    echo "::error title=Error::Ray head ended with status ${rc}; tearing the cluster down"
    exit ${rc}
fi
