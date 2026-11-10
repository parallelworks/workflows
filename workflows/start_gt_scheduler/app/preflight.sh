#!/bin/bash
# Runs in the user workspace before anything is authorized, copied or started:
# resolves the controller and refuses a cluster that cannot run the scheduler or
# already runs one. Leaves what it found in controller.env for the other jobs.
set -o pipefail
cd "${PW_PARENT_JOB_DIR:-${PWD}}"
source inputs.sh
source workflows/start_gt_scheduler/app/libs.sh
set -x

fail() {
    echo "::error title=Error::$1"
    exit 1
}

[[ "${gt_version}" =~ ^v[0-9]{4}$ ]] || fail "Unexpected GT version '${gt_version}'"

# The form's resource was resolved when the run was submitted; the platform's listing
# has the address the cluster has now and says whether it is running
listed=$(pw cluster ls -o json 2> /dev/null | python3 "${app_dir}/utils/cluster_address.py" "${resource_id}")

if [ -z "${listed}" ]; then
    echo "::warning::${resource_name} is not in pw cluster ls: using the address the form resolved"
    [ -n "${resource_ip}" ] || fail "No address for ${resource_name}: is the cluster running?"
    controller="${resource_user}@${resource_ip}"
else
    read -r cluster_status controller <<< "${listed}"
    if [ "${cluster_status}" != "active" ] && [ "${cluster_status}" != "on" ]; then
        fail "${resource_name} is ${cluster_status}: start the cluster first"
    fi
    [ -n "${controller}" ] || fail "${resource_name} is ${cluster_status} but has no address yet"
fi

waited=0
until controller_ssh true; do
    [ ${waited} -lt 600 ] || fail "No SSH connection to ${controller} after ${waited} s"
    sleep 10
    waited=$((waited + 10))
done

report=$(controller_ssh "bash -s -- ${gt_version}" < "${app_dir}/controller/preflight.sh") \
    || fail "Could not inspect ${controller}"
field() {
    sed -n "s/^$1=//p" <<< "${report}"
}
controller_home=$(field home)
controller_private_ip=$(field private_ip)
[ -n "${controller_home}" ] && [ -n "${controller_private_ip}" ] \
    || fail "Could not read the home directory and the private address of ${controller}"

if [ "$(field scheduler_running)" == "true" ]; then
    fail "A GT scheduler is already running on ${resource_name} (screen session gt-scheduler on ${controller}). A cluster runs one at a time: cancel that run first"
fi
if [ "$(field gt_installed)" != "true" ]; then
    fail "GT ${gt_version} is not installed on ${resource_name}: /software/gtsuite/${gt_version} does not exist on ${controller}"
fi
if [ -n "$(field missing)" ]; then
    fail "${controller} lacks what the scheduler needs: $(field missing)"
fi
for kind in sched exec; do
    [ -f "${app_dir}/controller/properties_files/gtdistd-${kind}-${gt_version}.properties" ] \
        || fail "No gtdistd-${kind} properties file for GT ${gt_version}"
done

# The same place the platform gives a run on a cluster: ~/pw/jobs/<run>
run_dir=${PW_PARENT_JOB_DIR%/}
if [[ "${run_dir}" == */runs/* ]]; then
    run_name=${run_dir#*/runs/}
else
    run_name=$(basename "$(dirname "${run_dir}")")/$(basename "${run_dir}")
fi

cat > controller.env <<HERE
controller="${controller}"
controller_home="${controller_home}"
controller_private_ip="${controller_private_ip}"
remote_dir="${controller_home}/pw/jobs/${run_name}"
HERE
cat controller.env
