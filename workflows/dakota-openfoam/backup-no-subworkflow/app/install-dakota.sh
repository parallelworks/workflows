#!/bin/bash
# Idempotent Dakota install from conda-forge (no sudo). Runs on the login node
# with internet access; safe to re-run — a working env is detected and kept.
set -o pipefail
cd "$(dirname "$0")"
source ./install-common.sh

DAKOTA_VERSION="${DAKOTA_VERSION:-6.16.0}"

f_dakota_ok() {
    "${CONDA_PREFIX_DIR}/bin/conda" run -n dakota dakota --version > /dev/null 2>&1
}

if f_dakota_ok; then
    echo "::notice::Dakota already installed in ${CONDA_PREFIX_DIR}/envs/dakota"
    exit 0
fi

f_install_miniforge || exit 1

echo "::notice::Creating the dakota env (dakota=${DAKOTA_VERSION} from conda-forge)"
if ! "${CONDA_PREFIX_DIR}/bin/conda" create -y -n dakota "dakota=${DAKOTA_VERSION}"; then
    echo "::error::conda create -n dakota dakota=${DAKOTA_VERSION} failed"
    exit 1
fi

if ! f_dakota_ok; then
    echo "::error::Dakota installed but 'dakota --version' does not run"
    exit 1
fi
echo "::notice::Dakota ${DAKOTA_VERSION} ready"
