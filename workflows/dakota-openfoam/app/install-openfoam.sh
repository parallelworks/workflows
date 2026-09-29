#!/bin/bash
# Idempotent OpenFOAM install from conda-forge (no sudo). Runs on the login node
# with internet access; safe to re-run — a working env is detected and kept.
set -o pipefail
cd "$(dirname "$0")"
source ./install-common.sh

OPENFOAM_VERSION="${OPENFOAM_VERSION:-2412}"

f_openfoam_ok() {
    "${CONDA_PREFIX_DIR}/bin/conda" run -n openfoam simpleFoam -help > /dev/null 2>&1
}

if f_openfoam_ok; then
    echo "::notice::OpenFOAM already installed in ${CONDA_PREFIX_DIR}/envs/openfoam"
    exit 0
fi

f_install_miniforge || exit 1

echo "::notice::Creating the openfoam env (openfoam=${OPENFOAM_VERSION} from conda-forge)"
if ! "${CONDA_PREFIX_DIR}/bin/conda" create -y -n openfoam "openfoam=${OPENFOAM_VERSION}"; then
    echo "::error::conda create -n openfoam openfoam=${OPENFOAM_VERSION} failed"
    exit 1
fi

if ! f_openfoam_ok; then
    echo "::error::OpenFOAM installed but 'simpleFoam -help' does not run"
    exit 1
fi
echo "::notice::OpenFOAM ${OPENFOAM_VERSION} ready"
