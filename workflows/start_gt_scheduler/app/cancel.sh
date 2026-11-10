#!/bin/bash
# Stops what main.sh started. It runs from main.sh when the scheduler dies and again
# as that step's cleanup, so every line is safe to repeat.
cd "${PW_PARENT_JOB_DIR:-${PWD}}"
[ -f controller.env ] || exit 0
source controller.env
source workflows/start_gt_scheduler/app/libs.sh
set -x

controller_ssh "[ -f ${remote_dir}/cancel.sh ]"
found=$?
if [ ${found} -eq 0 ]; then
    timeout 300 ssh ${SSH_OPTIONS} -o ConnectTimeout=10 "${controller}" "${remote_dir}/cancel.sh" \
        || echo "::warning::The cancel script on ${controller} did not finish: check ${remote_dir} there"
elif [ ${found} -eq 255 ]; then
    echo "::warning::No SSH connection to ${controller}: the scheduler there could not be stopped from here"
fi

stop_reverse_tunnel
