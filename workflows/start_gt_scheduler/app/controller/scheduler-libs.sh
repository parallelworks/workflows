
uc_python_cmd="/usr/bin/python3"

echod() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}


curl_wrapper () {
    local curl_cmd=$1
    local out_file=$2
    while true; do
	    ${curl_cmd} > ${out_file}.tmp 2> /dev/null && mv ${out_file}.tmp ${out_file}
        if [ -f ${out_file} ]; then
            break
	    else
            echo "ERROR: File ${out_file} was not produced by command:"
            echo "       ${curl_cmd}"
	        sleep 10
	    fi
    done
}


# Function to check partition names
check_partition_names() {
    # Get partition information using sinfo and filter out the header
    partition_info=$(sinfo -h -o "%P")

    # Flag to indicate if any partition name has more than 8 characters
    error_found=0

    # Loop through each partition name
    while read -r partition_name; do
        # Check if the length of the partition name is greater than 8 characters
        if [ ${#partition_name} -gt 8 ]; then
            echo "Partition name '$partition_name' has more than 8 characters."
            error_found=1
        fi
    done <<< "$partition_info"

    # Exit with status code 1 if an error was found
    if [ $error_found -eq 1 ]; then
        echo "Partition names cannot have more than 8 characters! Exiting job..."
        exit 1
    fi
}

list_sorted_partitions() {
    sinfo --noheader --format="%P"  | sed 's/*//g' > partitions.list
    rm -f partitions_with_cores.list
    while IFS= read -r partition; do
        # Number of cores in the partition
        local pcores=$(sinfo  --noheader -p ${partition} -o "%.8c" | tr -d ' ')
        echo "${partition} ${pcores}" >>  partitions_with_cores.list
    done < partitions.list
    sort -k2 -r -n partitions_with_cores.list | awk '{print $1}' > partitions.list
    # This file is required by rotate_by_cores function
    sort -k2 -r -n partitions_with_cores.list > sorted_with_cores.list
}

rotate_by_cores() {
    # Read the file contents into an array, preserving lines
    mapfile -t lines < sorted_with_cores.list

    # Initialize an associative array to hold groups of lines by core count
    declare -A groups

    # Organize lines by core count
    for line in "${lines[@]}"; do
        core_count=$(echo "$line" | awk '{print $2}')
        groups[$core_count]+="$line;"
    done

    # Create an array to hold the core counts for sorting
    core_counts=("${!groups[@]}")
    
    # Sort core counts in descending order
    IFS=$'\n' sorted_core_counts=($(sort -nr <<<"${core_counts[*]}"))
    unset IFS

    # Rotate each group and print the result
    > sorted_with_cores.list # Truncate the file to start fresh
    for core_count in "${sorted_core_counts[@]}"; do
        # Split the group's lines into an array
        IFS=';' read -ra group_lines <<< "${groups[$core_count]}"
        group_size=${#group_lines[@]}

        # Rotate the group by shifting elements
        first_line="${group_lines[0]}"
        for ((i = 0; i < group_size - 1; i++)); do
            group_lines[i]="${group_lines[i+1]}"
        done
        group_lines[group_size-1]="$first_line"

        # Append the rotated lines back to the file
        for line in "${group_lines[@]}"; do
            if [ -n "$line" ]; then
                echo "$line" >> sorted_with_cores.list
            fi
        done
    done
    cat sorted_with_cores.list | awk '{print $1}' > partitions.list
}

rotate_single_by_core() {
    # Read the file contents into an array, preserving lines
    mapfile -t lines < sorted_with_cores.list

    # Specify the target core count to rotate
    target_core_count="$1"

    # Initialize an associative array to hold groups of lines by core count
    declare -A groups

    # Organize lines by core count
    for line in "${lines[@]}"; do
        core_count=$(echo "$line" | awk '{print $2}')
        groups[$core_count]+="$line;"
    done

    # Create an array to hold the core counts for sorting
    core_counts=("${!groups[@]}")
    
    # Sort core counts in descending order
    IFS=$'\n' sorted_core_counts=($(sort -nr <<<"${core_counts[*]}"))
    unset IFS

    # Rotate the specified group and keep other groups as is
    > sorted_with_cores.list # Truncate the file to start fresh
    for core_count in "${sorted_core_counts[@]}"; do
        # Split the group's lines into an array
        IFS=';' read -ra group_lines <<< "${groups[$core_count]}"
        
        if [ "$core_count" -eq "$target_core_count" ]; then
            # Rotate the group for the specified core
            group_size=${#group_lines[@]}
            first_line="${group_lines[0]}"
            for ((i = 0; i < group_size - 1; i++)); do
                group_lines[i]="${group_lines[i+1]}"
            done
            group_lines[group_size-1]="$first_line"
        fi

        # Append the lines back to the file
        for line in "${group_lines[@]}"; do
            if [ -n "$line" ]; then
                echo "$line" >> sorted_with_cores.list
            fi
        done
    done
    cat sorted_with_cores.list | awk '{print $1}' > partitions.list
}



cancel_long_cf_jobs() {
    # Get the current time in seconds since epoch
    current_time=$(date +%s)

    # Loop over all jobs in CF state
    squeue --state=CF --format="%.18i %.10M %.16u" | tail -n +2 | while read job_id time_in_cf user; do
        # Convert time_in_cf (e.g. 00:10:00) to seconds
        minutes=$(echo $time_in_cf | cut -d':' -f1)
        seconds=$(echo $time_in_cf | cut -d':' -f2)
        total_seconds_in_cf=$((10#$minutes*60 + 10#$seconds))

        # If job has been in CF state for more than adv_pw_max_cf_time seconds, cancel it
        if [ "$total_seconds_in_cf" -gt ${adv_pw_max_cf_time} ]; then
            echo "Cancelling job $job_id (User: $user) in CF state for $total_seconds_in_cf seconds"
            scancel $job_id
            touch rotate_partitions
        fi
    done
}

get_core_supply() {
    CORE_SUPPLY=0   
    while IFS= read -r partition; do
        # Number of cores in the partition
        local pcores=$(sinfo  --noheader -p ${partition} -o "%.8c" | tr -d ' ')
        # Number of jobs running in this partition
        local pjobs=$(squeue --long | grep "\b${partition}\b" | wc -l)
        export CORE_SUPPLY=$((CORE_SUPPLY+pcores*pjobs))
    done < partitions.list
}

submit_executor_job() {
    local partition=$1
    local job_name=$2
    local pcores=$3

    local slurm_job_dir="${PWD}/slurm-jobs/$(date +%Y-%m-%d)"
    mkdir -p ${slurm_job_dir}
    
    # Create SLURM script from executor
    sed -e "s|__PARTITION__|${partition}|g" \
        -e "s|__JOB_NAME__|${job_name}|g" \
        -e "s|__SLURM_JOB_DIR__|${slurm_job_dir}|g" \
        -e "s|__CORES_PER_NODE__|${pcores}|g" \
        -e "s|__RESOURCE_TYPE__|${resource_type}|g" \
        -e "s|__GT_VERSION__|${gt_version}|g" \
        -e "s|__SCHEDULER_INTERNAL_IP__|${resource_privateIp}|g" \
        -e "s|__GT_LICENSE_HOSTNAME__|${gt_license_hostname}|g" \
        -e "s|__EXEC_PROP_FILE_TEMPLATE__|${exec_prop_file_template}|g" \
        -e "s|__SSH_CONFIG_COMPUTE__|${ssh_config_compute}|g" \
        "${APP_DIR}/executor-template.sh" > "${slurm_job_dir}/${job_name}.sh"

    # Submit job to queue
    jobid=$(sbatch ${slurm_job_dir}/${job_name}.sh | tail -1 | awk -F ' ' '{print $4}')
}


satisfy_core_overdemand() {
    core_overdemand=$1

    if [ "${core_overdemand}" -le 0 ]; then
        return
    fi

    # Minimize number of nodes by submitting jobs from large nodes to small nodes
    while IFS= read -r partition; do
        # Number of cores in the partition
        local pcores=$(sinfo  --noheader -p ${partition} -o "%.8c" | tr -d ' ')
        # Maximum number of nodes in the partition
        local max_nodes=$(sinfo  --noheader -p ${partition} -o "%D" | tr -d ' ')
        # Number of jobs running in this partition
        # - Jobs always request 1 node!
        local pjobs=$(squeue --long | grep "\b${partition}\b" | wc -l)
        # Available number of nodes in the partition 
        local available_nodes=$((max_nodes-pjobs))
        # Partition nodes needed to satisfy the overdemand
        local needed_nodes=$((core_overdemand/pcores))
        # Do not submit more jobs than available nodes
        if [ "${available_nodes}" -lt "${needed_nodes}" ]; then
            local njobs="${available_nodes}"
        else
            local njobs="${needed_nodes}"
        fi
        
        # Submit as many jobs as needed nodes. Each job requests 1 node!
        for i in $(seq 1 "${njobs}"); do
            job_name="${SECONDS}-${partition}-${i}"
            echod "Submitting job ${job_name} to partition ${partition} with ${pcores} cores"
            submit_executor_job ${partition} ${job_name} ${pcores}
            core_overdemand=$((core_overdemand-pcores))
        done
        sleep 1
    done < partitions.list
    
    if [ "$core_overdemand" -le 0 ]; then
        return
    fi

    # Distribute remaining packets to the single smallest possible node
    tac partitions.list | while IFS= read -r partition; do
        # Maximum number of nodes in the partition
        local max_nodes=$(sinfo  --noheader -p ${partition} -o "%D" | tr -d ' ')
        # Number of jobs running in this partition
        # - Jobs always request 1 node!
        local pjobs=$(squeue --long | grep "\b${partition}\b" | wc -l)
        # Do not submit additional jobs to this partition if the maximum number of running nodes is reached
        if [ "${pjobs}" -lt "${max_nodes}" ]; then
            job_name="${SECONDS}-${partition}-remainder"
            echod "Submitting job ${job_name} to partition ${partition} with ${pcores} cores"
            submit_executor_job ${partition} ${job_name} ${pcores}
            core_overdemand=$((core_overdemand-pcores))
            break
        fi
    done
}


start_gt_db() {
    # Start DB on node boot as USER
    # VERSION=$(echo ${gt_version} | sed "s/v//g")
    # ${GTIHOME}/bin/gtcollect -V ${VERSION} dbstart
    # ${GTIHOME}/bin/gtcollect -V ${VERSION} dbstop
    # ${GTIHOME}/bin/gtcollect -V ${VERSION} dbstart
    # FIXME: Wont work after 2029
    for gtv in $(ls -d ${GTIHOME}/v202*); do
        vn=$(basename ${gtv} | sed 's/v//g')
        echo "${GTIHOME}/bin/gtcollect -V ${vn} dbstart"
        ${GTIHOME}/bin/gtcollect -V ${vn} dbstart
    done
}

#$GTIHOME/v2020/distributed/bin/gtdistd.sh -c <config-file>
# USE LATEST VERSION!
configure_daemon_systemd() {
    local prop_file=$1

    # Make sure this user can write the gtdistd.out file
    touch /tmp/gtdistd.out
    chmod 777 /tmp/gtdistd.out

    # Get daemon version
    vn=$(echo ${gt_version} | sed 's/v//g')
    if [ ${vn} -lt 2020 ]; then
        dversion=v2020
    else
        dversion=${gt_version}
    fi

    # Following instructions in section 5b of /opt/gtsuite/v2020/distributed/bin/README_Linux.md
    # Stage the unit files as the regular user first: /software may be NFS-mounted
    # with root_squash on compute nodes, so root cannot read it there (sudo cp
    # straight from ${GTIHOME} fails with 'Permission denied')
    unit_files_src=${GTIHOME}/${dversion}/distributed/bin/systemd-unit-files
    unit_files_tmp=$(mktemp -d)
    cp ${unit_files_src}/gtdistd.service ${unit_files_tmp}/
    cp -r ${unit_files_src}/gtdistd.service.d ${unit_files_tmp}/
    chmod 644 ${unit_files_tmp}/gtdistd.service ${unit_files_tmp}/gtdistd.service.d/override.conf
    sudo cp ${unit_files_tmp}/gtdistd.service /etc/systemd/system/
    sudo cp -r ${unit_files_tmp}/gtdistd.service.d /etc/systemd/system/
    sudo mkdir -p /etc/systemd/system/gtdistd.service.d/
    conf_file=/etc/systemd/system/gtdistd.service.d/override.conf
    sudo cp ${unit_files_tmp}/gtdistd.service.d/override.conf ${conf_file}
    rm -rf ${unit_files_tmp}
    sudo sed -i "s|/opt/gtsuite/v|${GTIHOME}/v|g" ${conf_file}
    sudo sed -i "s|User=.*|User=${USER}|g" ${conf_file}
    sudo sed -i "s|Environment=GTIHOME=.*|Environment=GTIHOME=${GTIHOME}|g" ${conf_file}
    sudo sed -i "s|Environment=GT_VERSION_HOME=.*|Environment=GT_VERSION_HOME=${GT_VERSION_HOME}|g" ${conf_file}
    sudo sed -i "s|Environment=GT_CONF=.*|Environment=GT_CONF=${prop_file}|g" ${conf_file}
    # Environment=JAVA_OPTS=
    # Environment=DAEMON_OUT=/tmp/gtdistd.out

    # Verify the syntax of the `override.conf` file contains no syntax errors. A correct file
    # will generate no output.
    sudo systemd-analyze verify /etc/systemd/system/gtdistd.service
    sudo systemctl daemon-reload

    # Restart service:
    sudo systemctl start gtdistd.service
    sudo systemctl status gtdistd.service

    # Launch GUI Need X11 DISPLAY!
    # $GTIHOME/${dversion}/distributed/bin/gtdistdconfig.sh
}

write_balance() {
    # Customer's name matches the cluster's name because the license server only 
    # sees <gt-user-name>@<pw-user-name>-<cluster-name>-<session-number>-mgmt and
    # we need to support sharing a single PW user account for the "Managed by PW" solution
    customer_name=$(hostname | cut -d'-' -f2)
    
    # Set retry parameters
    max_retries=10    # Maximum number of attempts
    retry_delay=20   # Delay in seconds between attempts
    attempt=1        # Start with the first attempt

    while [ $attempt -le $max_retries ]; do
        # Attempt to retrieve the balance
        ssh ${resource_ssh_usercontainer_options} usercontainer ${uc_python_cmd} ${workspace_app_dir}/utils/get_balance.py --customer_name=${customer_name} --customer_org_id=${customer_org_id} --customer_org_name=${customer_org_name} > balance.json 2>write_balance.log
        
        ssh_exit_code=$?
        
        # Check if the SSH command succeeded
        if [ $ssh_exit_code -eq 0 ]; then
            # Check if the balance.json file is valid
            if [ -s "balance.json" ]; then
                return 0  # Exit the function successfully
            else
                echod "Error: File balance.json is missing or empty."
                # No need to retry if file is empty or missing, so exit
                exit 1
            fi
        else
            echod "ERROR: Could not obtain balance. Attempt $attempt of $max_retries failed."
            cat write_balance.log
            echod "Retrying in $retry_delay seconds..."
            attempt=$((attempt + 1))
            sleep $retry_delay
        fi
    done

    # If we exhausted all retries, log the error and exit
    echod "ERROR: Could not obtain balance after $max_retries attempts."
    echod "Exiting workflow"
    exit 1
}


write_node_info() {
    ssh ${resource_ssh_usercontainer_options} usercontainer ${uc_python_cmd} ${workspace_app_dir}/utils/get_node_info.py --resource_name=${resource_name} --resource_namespace=${resource_namespace} --org_name=${customer_org_name} > node_info.json 2>write_node_info.log

    ssh_exit_code=$?

    # Check if the SSH command succeeded
    if [ $ssh_exit_code -eq 0 ]; then
        # Check if the node_info.json file is valid
        if [ -s "node_info.json" ]; then
            return 0  # Exit the function successfully
        fi
    fi

    echod "ERROR: File node_info.json is missing or empty."
    cat write_node_info.log
    rm -rf node_info.json
}

cancel_failed_jobs_and_rotate_failed_partitions() {
    # Without node information the node status of the jobs cannot be checked
    if ! [ -s "node_info.json" ]; then
        return 0
    fi
    rm -f rotating_partitions
    touch rotating_partitions  # Ensure the file exists
    # Loop over all jobs and get their compute node and partition
    squeue --format="%.18i %.10R %.10P %.5C" | tail -n +2 | while read job_id compute_node partition cores; do
        
        # Check the node status in node_info.json
        status=$(jq -r --arg hostname "$compute_node" '.[] | select(.hostname == $hostname) | .status' node_info.json)
        
        # If the status is "failed" and the partition has not already been rotated, cancel the job
        if [[ "$status" == "failed" ]] && ! grep -Fxq "$partition" "rotating_partitions"; then
            echod "Job ID: $job_id | Compute Node: $compute_node | Partition: $partition | Status: failed"
            echod "Cancelling job"
            scancel "$job_id"
            echod "Rotating partitions with ${cores} cores"
            rotate_single_by_core ${cores}
            echo "$partition" >> rotating_partitions
            echo
            cat partitions.list
            echo
        fi
    done
}
