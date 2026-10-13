#!/bin/bash

jobid=$(cat $1 | tail -1 | awk -F ' ' '{print $4}')

get_slurm_job_status() {
    if [ -z "${SQUEUE_HEADER}" ]; then
        export SQUEUE_HEADER="$(squeue | awk 'NR==1')"
    fi
    status_column=$(echo "${SQUEUE_HEADER}" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^S/) { print i; exit } }')
    status_response=$(squeue | grep "\<${jobid}\>")
    echo "${SQUEUE_HEADER}"
    echo "${status_response}"
    export job_status=$(echo ${status_response} | awk -v id="${jobid}" -v col="$status_column" '{print $col}')
}

while true; do
    sleep 15
    get_slurm_job_status
    if [ -z "${job_status}" ]; then
        job_status=$(sacct -j ${jobid} --format=state | tail -n1)
        break
    fi
done

# Write the job status to an output file
echo "${job_status}" > job_status.txt
