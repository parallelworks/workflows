#!/bin/bash
# Installs cwltool under its own Miniconda in the install directory. Idempotent:
# the cwltool binary marks a completed install.
set -o pipefail
set -x

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
conda_dir=${service_parent_install_dir}/miniconda3-cwltool

if [ -x "${conda_dir}/bin/cwltool" ]; then
    echo "cwltool already exists under ${conda_dir}."
    echo "To reinstall, delete the directory and rerun the job."
    exit 0
fi

set -e
mkdir -p "${conda_dir}"
wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O "${conda_dir}/miniconda.sh"
bash "${conda_dir}/miniconda.sh" -b -u -p "${conda_dir}"
rm "${conda_dir}/miniconda.sh"
source "${conda_dir}/bin/activate"
pip install cwltool
