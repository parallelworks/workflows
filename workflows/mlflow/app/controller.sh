set -o pipefail

################################################################################
# Interactive Session Controller - MLflow
#
# Purpose: Install MLflow in a Miniforge (conda-forge) environment
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_conda_install: Whether to install conda (true/false)
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_install_instructions: latest | yaml | install_command | <conda-env-yaml-name>
#       latest          = Miniforge plus the newest mlflow from conda-forge
#       <name>          = the environment pinned in workflows/mlflow/app/<name>.yaml
#       yaml            = the environment pasted in the form (service_yaml)
#       install_command = run service_install_command instead (noaa existing clusters)
#   - service_load_env: Command to load mlflow (when conda_install=false or after install_command)
################################################################################

if [ -n "${PW_PARENT_JOB_DIR}" ]; then
    cd "${PW_PARENT_JOB_DIR}"
fi

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p "${service_parent_install_dir}"

source tools/utils/miniforge.sh

conda_prefix=${service_parent_install_dir}/${service_conda_install_dir}
# The installer the environment files under workflows/mlflow/app were exported from;
# latest and pasted environments bootstrap the newest Miniforge instead
miniforge_pinned_url=https://github.com/conda-forge/miniforge/releases/download/26.7.2-0/Miniforge3-Linux-x86_64.sh
service_conda_sh=${conda_prefix}/etc/profile.d/conda.sh

f_fail() {
    echo "::error title=Error::$1"
    exit 1
}

# Strips name/prefix so the yaml applies to any environment; prints the hash that keys
# the "environment already matches this yaml" marker
f_prepare_yaml() {
    sed -i -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' "$1"
    sha256sum "$1" | cut -c1-16
}

f_conda_env_exists() {
    conda env list | awk '{print $1}' | grep -qx "$1"
}

f_ensure_conda() {
    if [ ! -f "${service_conda_sh}" ]; then
        echo "::notice::Conda not found in <${conda_prefix}>. Installing Miniforge..."
        miniforge_bootstrap "${conda_prefix}" || f_fail "Miniforge installation failed"
    fi
    echo "::notice::Sourcing Conda SH <${service_conda_sh}>"
    source "${service_conda_sh}" || f_fail "Could not source ${service_conda_sh}"
}

f_set_up_conda_from_yaml() {
    local conda_yaml=$1 yaml_hash=$2
    f_ensure_conda
    if ! f_conda_env_exists "${service_conda_env}"; then
        echo "::notice::Creating Conda Environment <${service_conda_env}>"
        conda create -y --name "${service_conda_env}" || f_fail "Could not create the conda environment ${service_conda_env}"
    fi
    echo "::notice::Updating Conda environment <${service_conda_env}> from ${conda_yaml}"
    conda env update -n "${service_conda_env}" -f "${conda_yaml}" || f_fail "conda env update from ${conda_yaml} failed"
    mkdir -p "${conda_prefix}/.pw-env-markers"
    touch "${conda_prefix}/.pw-env-markers/${service_conda_env}-${yaml_hash}"
}

f_set_up_conda_latest() {
    f_ensure_conda
    if ! f_conda_env_exists "${service_conda_env}"; then
        echo "::notice::Creating Conda Environment <${service_conda_env}> with mlflow"
        conda create -y -n "${service_conda_env}" -c conda-forge mlflow || f_fail "Could not create the conda environment ${service_conda_env}"
    fi
    conda activate "${service_conda_env}" || f_fail "Could not activate the conda environment ${service_conda_env}"
    if ! command -v mlflow > /dev/null 2>&1; then
        echo "::notice::Installing mlflow into <${service_conda_env}>"
        conda install -y -c conda-forge mlflow || f_fail "conda install mlflow failed"
    fi
}

if [[ "${service_conda_install}" == "true" ]]; then
    echo "::group::MLflow Installation"
    if [[ "${service_install_instructions}" == "install_command" ]]; then
        echo "::notice::Running install command ${service_install_command}"
        eval "${service_install_command}" || f_fail "The install command failed"
    else
        # Several runs may install into the same prefix at once (a cold cluster): the
        # lock is held until this script exits, so one installs and the others find it
        miniforge_lock "${conda_prefix}" || f_fail "Could not lock ${conda_prefix}"
        if [[ "${service_install_instructions}" == "latest" ]]; then
            echo "::notice::Installing the latest mlflow from conda-forge"
            f_set_up_conda_latest
        else
            if [[ "${service_install_instructions}" == "yaml" ]]; then
                echo "::notice::Installing custom conda environment"
                printf "%b" "${service_yaml}" > conda.yaml
            else
                echo "::notice::Installing conda environment ${service_install_instructions}.yaml"
                conda_yaml_src=workflows/mlflow/app/${service_install_instructions}.yaml
                [ -f "${conda_yaml_src}" ] || f_fail "Conda environment definition ${conda_yaml_src} not found in $(pwd)"
                cp "${conda_yaml_src}" conda.yaml
                export MINIFORGE_URL=${miniforge_pinned_url}
            fi
            cat conda.yaml
            yaml_hash=$(f_prepare_yaml conda.yaml)
            env_marker=${conda_prefix}/.pw-env-markers/${service_conda_env}-${yaml_hash}
            if [ -f "${service_conda_sh}" ] && [ -f "${env_marker}" ]; then
                echo "::notice::Conda environment <${service_conda_env}> in <${conda_prefix}> already matches conda.yaml; skipping the update"
            else
                f_set_up_conda_from_yaml conda.yaml "${yaml_hash}"
            fi
        fi
    fi
    echo "::endgroup::"
    if [ -z "${service_load_env}" ]; then
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
fi

eval "${service_load_env}"

if ! command -v mlflow > /dev/null 2>&1; then
    echo "::error title=Error::mlflow command not found"
    exit 1
fi
echo "::notice::$(mlflow --version 2>/dev/null) at $(command -v mlflow)"
