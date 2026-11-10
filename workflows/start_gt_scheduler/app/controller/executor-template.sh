#!/bin/bash
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --partition=__PARTITION__
#SBATCH --job-name=__JOB_NAME__
#SBATCH -o __SLURM_JOB_DIR__/jobid-%j.out
#SBATCH -e __SLURM_JOB_DIR__/__JOB_NAME__-jobid-%j.out
#SBATCH --chdir=__SLURM_JOB_DIR__

cores_per_node=__CORES_PER_NODE__
resource_type=__RESOURCE_TYPE__
gt_version=__GT_VERSION__
scheduler_internal_ip=__SCHEDULER_INTERNAL_IP__
gt_license_hostname=__GT_LICENSE_HOSTNAME__
exec_prop_file_template=__EXEC_PROP_FILE_TEMPLATE__
ssh_config_compute=__SSH_CONFIG_COMPUTE__

export GTI_DB_CREATION_OPT=1

exec_work_dir=/var/opt/gtsuite
exec_prop_file=${exec_work_dir}/gtdistd/gtdistd-exec.properties
GTIHOME=/software/gtsuite
GT_VERSION_HOME=${GTIHOME}/${gt_version}

# ONLY IN THE EXECUTOR.sh
# add a host pointer to internal IP of the scheduler
# Only edit /etc/hosts if a license hostname is defined. With an empty
# gt_license_hostname the sed below would blank out every line of the file!
if [ -n "${gt_license_hostname}" ]; then
    cat /etc/hosts > hosts_mod
    sed -i "s|.*${gt_license_hostname}.*||g" hosts_mod
    echo "${scheduler_internal_ip} ${gt_license_hostname}" >> hosts_mod
    sudo cp hosts_mod /etc/hosts
fi


# Start or restart gtdist daemon
# Make sure user has permissions
sudo mkdir -p ${sched_work_dir}
sudo chown ${USER}: ${exec_work_dir} -R
chmod u+w ${exec_work_dir} -R

# Directories / Files:
mkdir -p ${exec_work_dir}/gtdistd ${exec_work_dir}/db ${exec_work_dir}/compounds

# Start DB on node boot: Neehar: "Do not use the ds"
# FIXME: Wont work after 2029
for gtv in $(ls -d ${GTIHOME}/v202*); do
    vn=$(basename ${gtv} | sed 's/v//g')
    echo "${GTIHOME}/bin/gtcollect -V ${vn} dbstart"
    ${GTIHOME}/bin/gtcollect -V ${vn} dbstart
done

# Make sure this user can write the gtdistd.out file
touch /tmp/gtdistd.out
chmod 777 /tmp/gtdistd.out

echo "Copying file ${exec_prop_file_template} to ${exec_prop_file}"
cp ${exec_prop_file_template} ${exec_prop_file}
sed -i "s|.*GTDistributed.executor.core-count.*|GTDistributed.executor.core-count = ${cores_per_node}|g" ${exec_prop_file}

# START GTDIST DAEMON
# Get daemon version
vn=$(echo ${gt_version} | sed 's/v//g')
if [ ${vn} -lt 2020 ]; then
    dversion=v2020
else
    dversion=${gt_version}
fi


configure_daemon_systemd() {
    echo Configuring daemon
    local prop_file=$1
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

    # Environment=JRE_HOME=/opt/gtsuite/${dversion}/GTsuite/jre/linux_x86_64
    # Environment=JAVA_OPTS=
    # Environment=DAEMON_OUT=/tmp/gtdistd.out

    # Verify the syntax of the `override.conf` file contains no syntax errors. A correct file
    # will generate no output.
    echo "sudo systemd-analyze verify /etc/systemd/system/gtdistd.service"
    sudo systemd-analyze verify /etc/systemd/system/gtdistd.service
    echo "sudo systemctl daemon-reload"
    sudo systemctl daemon-reload

    # Restart service:
    echo "sudo systemctl start gtdistd.service"
    sudo systemctl start gtdistd.service
    echo "sudo systemctl status gtdistd.service"
    sudo systemctl status gtdistd.service

    # Launch GUI Need X11 DISPLAY!
    # $GTIHOME/${dversion}/distributed/bin/gtdistdconfig.sh
}

configure_daemon_systemd ${exec_prop_file}

# Wait for the sim file to appear (sim_found) and for ALL sim files to disappear before exiting
# FIXME What if simulation is halted? 1cyl_3.hlt
# FIXME: Some jobs are so fast that we never catch the .sim files
# FIXME: If min slider = 1 and no inputs wti is going to shut down and boot repeatedly every 5 min
sim_found=false # True when a sim file is found
# Watcher period: Watcher checks for sim files every wp seconds
wp=3
# Timeout period: cog-job will exit even if no sim file was found after tp seconds
tp=600
accu=0
cpu_exit=0
while true; do
    sleep ${wp}
    accu=$((accu + wp))
    date
    sim_counter=$(find ${exec_work_dir}/gtdistd -name **.sim | wc -l)
    hlt_counter=$(find ${exec_work_dir}/gtdistd -name **.hlt | wc -l)
    echo "Running simulations: ${sim_counter}"
    echo "Halted  simulations: ${hlt_counter}"
    if [ ${sim_counter} -eq 0 ]; then
        echo "No ongoing simulation was found"
        cpu_exit=0
        if ${sim_found}; then # There was a simulation
            echo "All simulation were completed"
            # Will exit after sim was not found 3 times
            exit_counter=$((exit_counter + 1))
            echo "Exit counter: ${exit_counter}"
            if [ ${exit_counter} -gt 60 ]; then
                sudo systemctl stop gtdistd.service
                exit 0
            fi
        fi
    else
        # One or more simulations are running
        sim_found=true
        exit_counter=0
        # If no simulation is paused and cpu usage is small --> exit
        if [ ${hlt_counter} -eq 0 ]; then
            cpu_usage=$(ps -eo %cpu --sort=-%cpu | awk 'FNR == 2 {print}' | awk '{print int($0)}')
            echo "CPU usage of most demanding process: ${cpu_usage}"
            if [ ${cpu_usage} -lt 15 ]; then
                cpu_exit=$((cpu_exit + 1))
                echo "${cpu_usage} < 15% --> CPU exit counter: ${cpu_exit}/50"
                if [ ${cpu_exit} -gt 120 ]; then
                    sudo systemctl stop gtdistd.service
                    exit 0
                fi
            else
                cpu_exit=0
            fi
        fi
    fi
    if ! ${sim_found} && [ ${accu} -gt ${tp} ]; then
        echo "Exiting. No simulation was found after ${accu}>${tp} seconds"
        sudo systemctl stop gtdistd.service
        exit 0
    fi
done

sudo systemctl stop gtdistd.service
