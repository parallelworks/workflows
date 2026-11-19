#!/bin/bash
# Preprocessing of the usd-export workflow, run from the job directory after inputs.sh
# is written: checks the form, installs the exporter's Python once (or takes the form's
# environment commands), and writes export.sh, the script the submitter runs. Publishes
# SCRIPT_PATH, EXIT_FILE and STAGE_FILE through $OUTPUTS.
set -o pipefail
set -x
source inputs.sh

if [ -z "${results_source}" ]; then
    echo "::error title=Error::Results directory is empty: give a case directory or a directory of cases"
    exit 1
fi
if ! [ -d "${results_source}" ]; then
    echo "::error title=Error::The results directory ${results_source} does not exist on $(hostname)"
    exit 1
fi
if [ -z "${stage_directory}" ]; then
    echo "::error title=Error::Stage directory is empty"
    exit 1
fi
if ! mkdir -p "${stage_directory}"; then
    echo "::error title=Error::Cannot create the stage directory ${stage_directory} on $(hostname)"
    exit 1
fi

env_file="${PWD}/usd-env.sh"
printf '%s\n' "${software_python_load}" | \
    bash tools/utils/prepare-env.sh "usd export tools" "${env_file}" \
    workflows/usd-export/app/install-usd-tools.sh python || exit 1

exit_file="${PWD}/export.exit"
rm -f "${exit_file}"
{
    cat inputs.sh
    echo "export_app=${PWD}/workflows/usd-export/app"
    echo "env_file=${env_file}"
    echo "exit_file=${exit_file}"
    cat workflows/usd-export/app/export-template.sh
} > export.sh
chmod +x export.sh

echo "SCRIPT_PATH=${PWD}/export.sh" | tee -a "${OUTPUTS}"
echo "EXIT_FILE=${exit_file}" | tee -a "${OUTPUTS}"
echo "STAGE_FILE=$(realpath -m "${stage_directory}")/study.usda" | tee -a "${OUTPUTS}"
