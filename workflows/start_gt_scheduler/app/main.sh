#!/bin/bash
# Runs in the user workspace for as long as the run does: prepares the controller,
# opens the license tunnel, starts the scheduler there and watches it. The scheduler
# is stopped by this step's cleanup (cancel.sh), which is how a run is ended.
set -o pipefail
cd "${PW_PARENT_JOB_DIR:-${PWD}}"
source inputs.sh
source controller.env
source workflows/start_gt_scheduler/app/libs.sh
set -x

fail() {
    echo "::error title=Error::$1"
    bash "${app_dir}/cancel.sh"
    exit 1
}

setup=$(controller_ssh "bash -s -- ${PW_USER}" < "${app_dir}/controller/usercontainer.sh") \
    || fail "Could not prepare the connection from ${controller} back to the user workspace"
usercontainer_port=$(sed -n 's/^USERCONTAINER_PORT=//p' <<< "${setup}")
usercontainer_key=$(sed -n 's/^USERCONTAINER_KEY=//p' <<< "${setup}")
[ -n "${usercontainer_port}" ] && [ -n "${usercontainer_key}" ] \
    || fail "Could not read the usercontainer port and key of ${controller}"
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
grep -qxF "${usercontainer_key}" ~/.ssh/authorized_keys || echo "${usercontainer_key}" >> ~/.ssh/authorized_keys
ensure_usercontainer \
    || fail "${controller} cannot reach the user workspace through port ${usercontainer_port}: $(cat reverse-tunnel.out 2> /dev/null)"

rm -rf controller
cp -r "${app_dir}/controller" controller
chmod +x controller/*.sh
cat > controller/inputs.sh <<HERE
export gt_license_user="${gt_license_user}"
export gt_license_ip="${gt_license_ip}"
export gt_license_hostname="${gt_license_hostname}"
export gt_license_port="${gt_license_port}"
export gt_license_vendor_port="${gt_license_vendor_port}"
export customer_org_id="${customer_org_id}"
export customer_org_name="${customer_org_name}"
export gt_version="${gt_version}"
export adv_gt_sum_serv="${adv_gt_sum_serv}"
export adv_gt_allow_ps="${adv_gt_allow_ps}"
export adv_gt_max_parallel_cores_per_solver="${adv_gt_max_parallel_cores_per_solver}"
export adv_pw_ds_cycle="${adv_pw_ds_cycle}"
export adv_pw_min_core_demand="${adv_pw_min_core_demand}"
export adv_pw_max_core_demand="${adv_pw_max_core_demand}"
export resource_name="${resource_name}"
export resource_namespace="${resource_namespace}"
export resource_type="${resource_type}"
export resource_privateIp="${controller_private_ip}"
export resource_ssh_usercontainer_options="${USERCONTAINER_OPTIONS}"
export workspace_app_dir="${app_dir}"
HERE
rsync -az -e "ssh ${SSH_OPTIONS}" --rsync-path="mkdir -p ${remote_dir} && rsync" controller/ "${controller}:${remote_dir}/" \
    || fail "Could not copy the scheduler's files to ${controller}:${remote_dir}"

# The license_access job fails the run when it cannot install the key, which cancels
# this step: the limit here only keeps the wait from being open-ended
waited=0
until [ -f license-access.ready ]; do
    [ ${waited} -lt 900 ] || fail "The license_access job did not authorize ${controller} on the license server within ${waited} s"
    sleep 10
    waited=$((waited + 10))
done

# Retried because the controller's sshd fetches its authorized keys from the platform
# API, which can fail for a moment (Permission denied)
tunnel=1
for attempt in 1 2 3 4 5; do
    controller_ssh "${remote_dir}/license_tunnel.sh"
    tunnel=$?
    [ ${tunnel} -eq 0 ] && break
    echo "$(date) WARNING: license_tunnel.sh failed with code ${tunnel} (attempt ${attempt}/5). Retrying in 30s..."
    sleep 30
done
[ ${tunnel} -eq 0 ] || fail "Could not open the license tunnel from ${controller} to ${gt_license_user}@${gt_license_ip}"

# Only a lost connection (255) is retried: the script's own failure is final
launch=255
for attempt in 1 2 3 4 5; do
    controller_ssh "${remote_dir}/launch_scheduler.sh"
    launch=$?
    [ ${launch} -ne 255 ] && break
    echo "$(date) WARNING: no connection to ${controller} to launch the scheduler (attempt ${attempt}/5). Retrying in 30s..."
    sleep 30
done
[ ${launch} -eq 0 ] || fail "Could not start the scheduler on ${controller}"
touch scheduler.launched

# The loop below runs for the life of the scheduler: no trace, so this step's log
# stays the scheduler's own
set +x
echo "$(date) Scheduler launched on ${controller}; its files and logs.out are in ${remote_dir}"

scheduler_log="${remote_dir}/logs.out"
stream_scheduler_log() {
    # $1: how much of the file to print first (+1: all of it, 0: only new lines)
    ssh ${SSH_OPTIONS} -o ServerAliveInterval=60 -o ServerAliveCountMax=3 "${controller}" "tail -n $1 -F ${scheduler_log}"
}
stream_scheduler_log +1 &
stream_pid=$!
trap 'kill ${stream_pid} 2> /dev/null' EXIT

missed=0
while true; do
    # The license tunnel and the scheduler's balance queries both go through it
    ensure_usercontainer \
        || echo "$(date) WARNING: ${controller} cannot reach the user workspace through port ${usercontainer_port}"

    if ! controller_ssh "netstat -tuln | grep -q ${gt_license_port} && netstat -tuln | grep -q ${gt_license_vendor_port}"; then
        echo "$(date) The license ports ${gt_license_port} and ${gt_license_vendor_port} are not both listening on ${controller}: opening the tunnel again"
        controller_ssh "${remote_dir}/license_tunnel.sh"
    fi

    if controller_ssh "screen -list | grep -q '[.]gt-scheduler'"; then
        missed=0
    else
        missed=$((missed + 1))
        echo "$(date) The gt-scheduler session is not running on ${controller} (check ${missed}/5)"
    fi
    [ ${missed} -lt 5 ] || break

    if ! kill -0 ${stream_pid} 2> /dev/null; then
        stream_scheduler_log 0 &
        stream_pid=$!
    fi

    sleep 90
done

echo "::error title=Error::The GT scheduler on ${controller} stopped: its gt-scheduler session is gone. The end of ${scheduler_log}:"
controller_ssh "tail -n 40 ${scheduler_log}"
bash "${app_dir}/cancel.sh"
exit 1
