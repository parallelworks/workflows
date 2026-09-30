# Body of a worker's run_case.sh. yamls/general.yaml assembles it as:
#   inputs.sh + "export case_index=<n>" + dcs_environment/<version>.sh + macros/<analysis_type>.sh + this file
# and submits it through script_submitter as one SLURM job per worker.
set -o pipefail

echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
# The submitter never inspects the script's exit status; the workers job reads run_case.exit
trap 'echo $? > run_case.exit' EXIT

touch job.started
app="${PW_PARENT_JOB_DIR}/workflows/3dcs/app"
model_name=$(basename "${dcs_model_file%.*}")
result_name="${model_name}_${case_index}"
result_file="Results/${result_name}.${result_ext}"

upload() {
    # Transient S3 signing/network errors abort the whole copy: retry before failing the worker
    local attempt
    for attempt in 1 2 3; do
        pw buckets cp -r "$@" && return 0
        echo "$(date) WARNING: upload attempt ${attempt} failed" >&2
        sleep 30
    done
    return 1
}

write_macro
echo; echo "macroScript.txt:"; cat macroScript.txt; echo

if [[ "${dcs_dry_run}" == "true" ]]; then
    echo "$(date) INFO: Dry run: 3DCS is not executed"
    mkdir -p Results
    touch "${result_file}"
else
    # CPU and memory of the node, plotted after the run; cancels the job when memory exceeds 98%
    source "${monitoring_conda_dir}/etc/profile.d/conda.sh"
    conda activate "${monitoring_conda_env}"
    monitoring_txt="case-${case_index}-${HOSTNAME}-jobid-${SLURM_JOB_ID}.txt"
    python "${app}/cpu_and_memory_usage.py" --write-usage --txt "${monitoring_txt}" &
    monitoring_pid=$!
    echo "kill ${monitoring_pid} || true # monitoring" >> cancel.sh

    # Usage is metered per node and run: every worker on the node appends heartbeats to the same
    # file, which the usage_metering job syncs to the metering server while it sits in usage/
    node_usage="$(hostname)-${PW_RUN_SLUG}"
    usage_file="${PW_PARENT_JOB_DIR}/usage/${node_usage}"
    touch "${PW_PARENT_JOB_DIR}/usage_active/${node_usage}.${case_index}"
    (
        while true; do
            date >> "${usage_file}"
            sleep $((RANDOM % 30 + 30))
        done
    ) &
    metering_pid=$!
    echo "kill ${metering_pid} || true # metering" >> cancel.sh

    SECONDS=0
    eval "${dcs_run}" macroScript.txt
    dcs_status=$?
    # dcsSimuMacro returns -3 on success, so the result file decides below
    echo "$(date) INFO: 3DCS exited with status ${dcs_status} after ${SECONDS} seconds"

    kill ${metering_pid} 2>/dev/null
    rm -f "${PW_PARENT_JOB_DIR}/usage_active/${node_usage}.${case_index}"
    # The last worker on the node retires its usage file so the sync never sends it again
    if ! ls "${PW_PARENT_JOB_DIR}/usage_active/${node_usage}".* >/dev/null 2>&1; then
        mv "${usage_file}" "${PW_PARENT_JOB_DIR}/usage_completed/" 2>/dev/null || true
    fi

    kill ${monitoring_pid} 2>/dev/null
    python "${app}/cpu_and_memory_usage.py" --plot-usage --txt "${monitoring_txt}"
    conda deactivate

    # 3DCS writes some result files as root
    sudo -n chmod -R 777 Results 2>/dev/null || true
    echo "${SECONDS}" > "Results/dcs-runtime-${case_index}.txt"
fi

if [ ! -f "${result_file}" ] || { [[ "${dcs_dry_run}" != "true" ]] && [ ! -s "${result_file}" ]; }; then
    echo "$(date) ERROR: 3DCS did not produce ${result_file}" >&2
    exit 1
fi

echo "$(date) INFO: Uploading $(basename "${PWD}") to ${dcs_output_uri}"
upload "${PWD}/" "${dcs_output_uri}/$(basename "${PWD}")" || exit 1
echo "$(date) INFO: Worker ${case_index} completed"
