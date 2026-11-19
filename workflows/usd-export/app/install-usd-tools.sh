#!/bin/bash
# Usage: install-usd-tools.sh [env-file]
# Idempotent install of the exporter's Python (OpenUSD, VTK, NumPy, Pillow) from
# conda-forge and PyPI, no sudo, into
# ${service_parent_install_dir:-$HOME/pw/software}/usd-export/miniforge. Runs on the
# login node with internet access; a working env is detected and kept. With
# [env-file], writes the sourceable activation of the env there (the contract of
# tools/utils/prepare-env.sh).
#
# usd-core is pinned to the OpenUSD release of the Kit the omniverse workflow runs
# (Isaac Sim 6.2, Kit 110, OpenUSD 25.11), so the crate files it writes open there.
set -o pipefail
app_dir="$(cd "$(dirname "$0")" && pwd)"
source "${app_dir}/../../../tools/utils/miniforge.sh" || exit 1

USD_CORE_VERSION="${USD_CORE_VERSION:-25.11}"
PACKAGES=("usd-core==${USD_CORE_VERSION}" "vtk==${VTK_VERSION:-9.7.2}" numpy pillow)
PREFIX="$(miniforge_prefix usd-export)"
miniforge_lock "${PREFIX}" || exit 1

f_tools_ok() {
    "${PREFIX}/bin/conda" run -n usd python -c "
import numpy, PIL, vtkmodules.vtkIOGeometry
from pxr import Usd
v = Usd.GetVersion()
assert f'{v[1]}.{v[2]}' == '${USD_CORE_VERSION}', v
" > /dev/null 2>&1
}

INSTALLING="${PREFIX}/envs/usd.installing"
if f_tools_ok; then
    echo "::notice::The USD export tools are already installed in ${PREFIX}/envs/usd"
    rm -f "${INSTALLING}"
else
    miniforge_bootstrap "${PREFIX}" || exit 1
    if [ -f "${INSTALLING}" ]; then
        "${PREFIX}/bin/conda" env remove -y -n usd > /dev/null 2>&1
    fi
    touch "${INSTALLING}"
    echo "::notice::Creating the usd env (Python 3.12, ${PACKAGES[*]})"
    if ! "${PREFIX}/bin/conda" create -y -n usd python=3.12 pip; then
        echo "::error::conda create -n usd python=3.12 failed"
        exit 1
    fi
    if ! "${PREFIX}/bin/conda" run -n usd python -m pip install --no-cache-dir "${PACKAGES[@]}"; then
        echo "::error::pip install ${PACKAGES[*]} failed"
        exit 1
    fi
    if ! f_tools_ok; then
        echo "::error::The usd env installed but OpenUSD ${USD_CORE_VERSION:-25.11}, VTK, NumPy or Pillow does not import"
        exit 1
    fi
    rm -f "${INSTALLING}"
    echo "::notice::The USD export tools are ready"
fi
if [ -n "${1:-}" ]; then
    miniforge_env_file "${PREFIX}" usd "$1"
fi
