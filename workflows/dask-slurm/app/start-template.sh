################################################################################
# Service Starter - Dask on SLURM
#
# Purpose: Keep a dask-jobqueue SLURMCluster alive on the login node and serve
#          its dashboard through a pw endpoint (app/dask_cluster.py)
# Runs on: Login node (the workers are SLURM jobs it submits)
# Called by: Workflow after controller setup, through the script submitter
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug)
#   - PW_PARENT_JOB_DIR: the run's job directory (dask-env.sh, scheduler file, markers)
#   - PW_RUN_SLUG: names the workers' SLURM jobs dask-<slug>
#   Read by dask_cluster.py from the environment:
#   - dask_partition, dask_account, dask_qos, dask_node_type: where the worker jobs go
#   - dask_cores, dask_memory, dask_processes, dask_walltime: the shape of one worker job
#   - dask_min_jobs, dask_max_jobs: the adaptive range of worker jobs
#   - dask_mem_directive: true to request the memory from SLURM (--mem)
#   - dask_interface: network interface the scheduler and workers talk over (optional)
#   - dask-directives.txt in the job directory: extra #SBATCH lines
################################################################################

cd "${PW_PARENT_JOB_DIR}" || exit 1

export dask_job_name="dask-${PW_RUN_SLUG}"
# The service cancels its worker jobs when it exits cleanly; cancel.sh covers a
# service that was killed. Written first so a cancel at any moment finds it.
cat > cancel.sh << EOF
#!/bin/bash
scancel --name ${dask_job_name} --user \${USER} 2> /dev/null || true
EOF
chmod +x cancel.sh
rm -f STOP CLUSTER_CLOSED scheduler.json ENDPOINT_URL

source ./dask-env.sh
if ! command -v sbatch > /dev/null 2>&1; then
    echo "::error title=Error::sbatch not found: the Dask workers are SLURM jobs"
    exit 1
fi

echo "::group::Start Service"
echo "::notice::Starting the Dask cluster: pw endpoints run ${pw_endpoints_args} -- python -u workflows/dask-slurm/app/dask_cluster.py --dashboard-port {port}"

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- python -u workflows/dask-slurm/app/dask_cluster.py --dashboard-port {port}

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Only a
    # launch that never registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
