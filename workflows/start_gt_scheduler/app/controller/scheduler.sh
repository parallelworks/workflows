#!/bin/bash
APP_DIR=$(dirname $0)
source inputs.sh
source ${APP_DIR}/scheduler-libs.sh

bash license_tunnel.sh

if ! [ -d "/software" ]; then
    echo; echo
    echo "ERROR: Directory /software does not exist. Exiting."
    exit 1
fi

export GTIHOME=/software/gtsuite
GT_VERSION_HOME=${GTIHOME}/${gt_version}
export PATH=${GTIHOME}/bin/:${PATH}
export PATH=${GT_VERSION_HOME}/GTsuite/bin/linux_x86_64/:${PATH}

# Directories / Files:
# Persistent disk is mounted in the sched_work_dir!
export sched_work_dir=/var/opt/gtsuite/
export exec_work_dir=/var/opt/gtsuite/


# Write load file for gtise interactive session
load_env_sh=${sched_work_dir}/load-env.sh 
rm -f ${load_env_sh}
cat >> ${load_env_sh} <<HERE
export GTIHOME=${GTIHOME}
export GTISOFT_LICENSE_FILE=${gt_license_port}@localhost #10.128.0.78 27014
export PATH=${GTIHOME}/bin/:${PATH}
HERE

sudo mkdir -p ${sched_work_dir} ${GTIHOME}

# Make sure user has permissions
sudo chown ${USER}: ${GTIHOME} -R
chmod u+w ${GTIHOME} -R
sudo chown ${USER}: ${sched_work_dir} -R
chmod u+w ${sched_work_dir} -R
mkdir -p ${sched_work_dir}/gtdistd ${sched_work_dir}/db ${sched_work_dir}/compounds

ulimit -u

# Add lic server's hostname to loopback address
cat /etc/hosts > hosts_mod
echo "127.0.0.1 ${gt_license_hostname}" >> hosts_mod
sudo cp hosts_mod /etc/hosts

# CREATE PROPERTIES FILES
exec_prop_file_template=${PWD}/gtdistd-exec-template.properties
sched_prop_file=${sched_work_dir}/gtdistd/gtdistd-sched.properties

# Prepare executor properties file (except core-count and priority)
pf_dir=properties_files
# cp ${GT_VERSION_HOME}/distributed/config-samples/gtdistd-exec.properties ${exec_prop_file_template}
cp ${pf_dir}/gtdistd-exec-${gt_version}.properties ${exec_prop_file_template}
sed -i "s|^GTDistributed.work-dir.*|GTDistributed.work-dir = ${exec_work_dir}/gtdistd|g" ${exec_prop_file_template}
sed -i "s|^GTDistributed.license-file.*|GTDistributed.license-file = ${gt_license_port}@${resource_privateIp}|g" ${exec_prop_file_template}
sed -i "s|^GTDistributed.client.hostname.*|GTDistributed.client.hostname = ${resource_privateIp}|g" ${exec_prop_file_template}
sed -i 's/\r//' ${exec_prop_file_template}

# Prepare scheduler properties file
template_sched_prop_file="${pf_dir}/gtdistd-sched-${gt_version}.properties"
if [[ ! -f "${template_sched_prop_file}" ]]; then
    echod "ERROR: File ${template_sched_prop_file} does not exist. Exiting workflow." >&2
    exit 1
fi
cp ${template_sched_prop_file} ${sched_prop_file}
sed -i "s|^GTDistributed.work-dir.*|GTDistributed.work-dir = ${sched_work_dir}/gtdistd|g" ${sched_prop_file}
if [[ ${adv_gt_sum_serv,,} == "true" ]]; then
    echod Activating summary service
    sed -i "s|GTDistributed.job-summary-service-enable.*|GTDistributed.job-summary-service-enable = true|g" ${sched_prop_file}
fi

if [[ ${adv_gt_allow_ps,,} == "true" ]]; then
    echod "Enabling parallel solver"
    if [[ -n "${adv_gt_max_parallel_cores_per_solver}" ]]; then
        echod "Setting max-parallel-cores-per-solver to ${adv_gt_max_parallel_cores_per_solver}"
        sed -i "s|^GTDistributed.scheduler.max-parallel-cores-per-solver.*|GTDistributed.scheduler.max-parallel-cores-per-solver = ${adv_gt_max_parallel_cores_per_solver}|g" ${sched_prop_file}
    else
        sed -i "s|GTDistributed.scheduler.max-parallel-cores-per-solver.*||g" ${sched_prop_file}
    fi
    sed -i "s|GTDistributed.scheduler.validation.max-parallel-cores-per-solver.*||g" ${sched_prop_file}
fi

# Start or restart gtdist daemon
date >> ${sched_work_dir}/dates.txt

if ! start_gt_db; then
    echod "ERROR: Failed to start GT database. Exiting workflow." >&2
    exit 1
fi

if ! configure_daemon_systemd ${sched_prop_file}; then
    echod "ERROR: Failed to configure and start daemon systemd with ${sched_prop_file}. Exiting workflow." >&2
    cat /tmp/gtdistd.out >&2
    exit 1
fi

if [[ "${gt_version}" == "v2024" ]]; then
    get_core_demand_script="get_core_demand_v2024.py"
elif [[ "${gt_version}" == "v2025" ]]; then
    get_core_demand_script="get_core_demand_v2024.py"
elif [[ "${gt_version}" == "v2026" ]]; then
    get_core_demand_script="get_core_demand_v2024.py"
else
    get_core_demand_script="get_core_demand.py"
fi

check_partition_names
list_sorted_partitions

echo
echod Partitions
echo
cat partitions.list

while true; do
    sleep ${adv_pw_ds_cycle}
    echo; echo
    # REALOAD INPUTS AND LIBS
    # This facilitate debugging and quick fixes
    source inputs.sh
    source ${APP_DIR}/scheduler-libs.sh
    
    # Writes balance to balance.json file
    write_balance # Writes balance.json

    # Updates the sched_prop_file to inhibit jobs that checkout products without balance
    python3 ${APP_DIR}/enforce_balance_in_prop_file.py ${sched_prop_file}

    # CORE DEMAND
    curl_wrapper "curl -s http://${resource_privateIp}:8979/jobs/?xml" webapp.xml
    python3 ${get_core_demand_script} \
        --webapp_xml webapp.xml \
        --balance_json balance.json \
        --allow_ps ${adv_gt_allow_ps} \
        --sched_work_dir ${sched_work_dir} > CORE_DEMAND

    export CORE_DEMAND=$(cat CORE_DEMAND)
    echod "CORE DEMAND: ${CORE_DEMAND}"

    # Check if CORE_DEMAND is empty
    if [[ -z "$CORE_DEMAND" ]]; then
        echod "Error: CORE_DEMAND is empty. Setting it to 0."
        export CORE_DEMAND=0
    fi

    if [ "${CORE_DEMAND}" -lt "${adv_pw_min_core_demand}" ]; then
        export CORE_DEMAND=${adv_pw_min_core_demand}
        echod "CORE DEMAND is under minimum limit. Set to MIN CORE DEMAND: ${CORE_DEMAND}"
    elif [ "${CORE_DEMAND}" -gt "${adv_pw_max_core_demand}" ]; then
        export CORE_DEMAND=${adv_pw_max_core_demand}
        echod "CORE DEMAND exceeded the limit. Set to MAX CORE DEMAND: ${CORE_DEMAND}"
    fi

    # Check if CORE_DEMAND is zero
    if [ "$CORE_DEMAND" -eq 0 ]; then
        # Cancel all jobs for the current user
        scancel -u $USER
    fi
    # Write node status information
    write_node_info

    cancel_failed_jobs_and_rotate_failed_partitions

    # CORE SUPPLY
    get_core_supply
    echod "CORE SUPPLY: ${CORE_SUPPLY}"

    core_overdemand=$((CORE_DEMAND-CORE_SUPPLY))
    
    if [ -f "INHIBIT_JOBS" ]; then
        echod "INHIBITING SUBMISSION OF ADDITIONAL JOBS"
        core_overdemand=0
    fi

    if [ "${core_overdemand}" -gt 0 ]; then
        echod "CORE OVERDEMAND: ${core_overdemand}"
        satisfy_core_overdemand ${core_overdemand}
    fi
    # The tail is to skip the date
    squeue --long | tail -n +2
done
