#!/bin/bash
# Idempotent setup on the login node. Assembled after inputs.sh by yamls/general.yaml.
set -o pipefail

app="${PW_PARENT_JOB_DIR}/workflows/3dcs/app"

install_miniconda() {
    local install_dir=$1
    local installer
    installer=$(mktemp /tmp/miniconda-XXXXXX.sh)
    echo "$(date) INFO: Installing Miniconda to ${install_dir}"
    wget -q --no-check-certificate https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O "${installer}"
    rm -rf "${install_dir}"
    mkdir -p "$(dirname "${install_dir}")"
    bash "${installer}" -b -p "${install_dir}"
    rm -f "${installer}"
}

# Conda environment of the CPU and memory monitor (psutil + matplotlib), on a filesystem the compute nodes share
if [ ! -f "${monitoring_conda_dir}/etc/profile.d/conda.sh" ]; then
    install_miniconda "${monitoring_conda_dir}"
fi
source "${monitoring_conda_dir}/etc/profile.d/conda.sh"
if conda env list | grep -q "^${monitoring_conda_env} "; then
    echo "$(date) INFO: Conda environment ${monitoring_conda_env} found in ${monitoring_conda_dir}"
else
    echo "$(date) INFO: Creating conda environment ${monitoring_conda_env} in ${monitoring_conda_dir}"
    conda env create -n "${monitoring_conda_env}" -q -f "${app}/monitoring-env.yaml"
fi

# Wine writes into the shared prefix, so the user running the workflow must own it
source "${app}/dcs_environment/${dcs_version}.sh"
echo "$(date) INFO: Taking ownership of ${WINEPREFIX}"
sudo -n chown -R "${USER}:$(id -gn)" "${WINEPREFIX}"
