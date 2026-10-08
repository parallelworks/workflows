# Body of merge.sh, which merges the workers' results. yamls/general.yaml assembles it as:
#   inputs.sh + dcs_environment/<version>.sh + node-setup.sh + macros/merge_<analysis_type>.sh + this file
# and submits it through script_submitter as a SLURM job.
set -o pipefail

echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
# The submitter never inspects the script's exit status; the merge job reads merge.exit
trap 'echo $? > merge.exit' EXIT

model_name=$(basename "${dcs_model_file%.*}")
merged_file="Results/${model_name}.${result_ext}"

upload() {
    # Transient S3 signing/network errors abort the whole copy: retry before failing the merge
    local attempt
    for attempt in 1 2 3; do
        pw buckets cp -r "$@" && return 0
        echo "$(date) WARNING: upload attempt ${attempt} failed" >&2
        sleep 30
    done
    return 1
}

# The workers' results live in the shared job directory, one level up
mkdir -p Results
cp "${PW_PARENT_JOB_DIR}"/job_dir_*/Results/"${model_name}"_*."${result_ext}" Results/
num_results=$(ls Results/"${model_name}"_*."${result_ext}" | wc -l)
if [ "${num_results}" -ne "${dcs_concurrency}" ]; then
    echo "$(date) ERROR: Found ${num_results} result files to merge, expected ${dcs_concurrency}" >&2
    exit 1
fi

write_macro
echo; echo "macroScript.txt:"; cat macroScript.txt; echo

if [[ "${dcs_dry_run}" == "true" ]]; then
    echo "$(date) INFO: Dry run: 3DCS is not executed"
    touch "${merged_file}"
else
    ensure_wine_runs || exit 1

    node_usage="$(hostname)-${PW_RUN_SLUG}-merge"
    usage_file="${PW_PARENT_JOB_DIR}/usage/${node_usage}"
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
    # dcsSimuMacro returns -3 on success, so the merged file decides below
    echo "$(date) INFO: 3DCS exited with status ${dcs_status} after ${SECONDS} seconds"

    kill ${metering_pid} 2>/dev/null
    mv "${usage_file}" "${PW_PARENT_JOB_DIR}/usage_completed/" 2>/dev/null || true

    # 3DCS writes some result files as root
    sudo -n chmod -R 777 Results 2>/dev/null || true
    echo "${SECONDS}" > Results/dcs-runtime-merge.txt
fi

if [ ! -f "${merged_file}" ] || { [[ "${dcs_dry_run}" != "true" ]] && [ ! -s "${merged_file}" ]; }; then
    echo "$(date) ERROR: 3DCS did not produce ${merged_file}" >&2
    exit 1
fi

# The per-worker inputs of the merge are already in the bucket under job_dir_<n>/
rm -f Results/"${model_name}"_*."${result_ext}"

# The pw CLI mis-signs S3 keys with characters that need URL-encoding (403 SignatureDoesNotMatch), and 3DCS
# names result files after the model's measurements (e.g. "CMRailTraining .hsu", "TRUNK×BUMPER", "INST（FR）"):
# drop spaces, and turn every other run of bytes outside [A-Za-z0-9._-] into "_", whatever the node's locale
LC_ALL=C find Results -depth -name '*[!A-Za-z0-9._-]*' | while IFS= read -r f; do
    mv -n "${f}" "$(dirname "${f}")/$(basename "${f}" | LC_ALL=C tr -d ' ' | LC_ALL=C tr -cs 'A-Za-z0-9._\n-' '_')"
done

echo "$(date) INFO: Uploading the merge to ${dcs_output_uri}"
pw buckets cp merge.sh "${dcs_output_uri}/merge.sh"
upload Results/ "${dcs_output_uri}/Results" || exit 1
if [ -d TempData ]; then
    upload TempData/ "${dcs_output_uri}/TempData" || exit 1
fi
echo "$(date) INFO: Merge completed"
