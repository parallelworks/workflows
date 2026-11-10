#!/bin/bash
# Stops what main.sh started. It runs from main.sh when the scheduler dies and again
# as that step's cleanup, so every line is safe to repeat.
cd "${PW_PARENT_JOB_DIR:-${PWD}}"
[ -f controller.env ] || exit 0
source controller.env
source workflows/start_gt_scheduler/app/libs.sh
set -x

problem=""
controller_ssh_retry "[ -f '${remote_dir}/cancel.sh' ]"
found=$?
if [ ${found} -eq 0 ]; then
    stopped=255
    for attempt in 1 2 3 4 5; do
        timeout 300 ssh ${SSH_OPTIONS} -o ConnectTimeout=10 "${controller}" "'${remote_dir}/cancel.sh'"
        stopped=$?
        [ ${stopped} -ne 255 ] && break
        sleep 15
    done
    [ ${stopped} -eq 0 ] || problem="its cancel script ended with status ${stopped}"
elif [ ${found} -ne 1 ]; then
    problem="no SSH connection to it"
fi

stop_reverse_tunnel

if [ -n "${problem}" ]; then
    echo "::error title=Error::The GT scheduler on ${controller} could not be stopped from here (${problem}). Run ${remote_dir}/cancel.sh there"
    exit 1
fi
