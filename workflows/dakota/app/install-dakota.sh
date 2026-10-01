#!/bin/bash
# Usage: install-dakota.sh [env-file]
# Idempotent Dakota install from conda-forge (no sudo) into
# ${service_parent_install_dir:-$HOME/pw/software}/dakota/miniforge. Runs on the
# login node with internet access; safe to re-run — a working env is detected and
# kept. With [env-file], writes the sourceable activation of the env there (the
# contract of tools/utils/prepare-env.sh). tools/utils is checked out next to this
# app by the workflow.
set -o pipefail
app_dir="$(cd "$(dirname "$0")" && pwd)"
source "${app_dir}/../../../tools/utils/miniforge.sh" || exit 1

DAKOTA_VERSION="${DAKOTA_VERSION:-6.16.0}"
PREFIX="$(miniforge_prefix dakota)"
miniforge_lock "${PREFIX}" || exit 1

f_dakota_ok() {
    "${PREFIX}/bin/conda" run -n dakota dakota --version > /dev/null 2>&1
}

if f_dakota_ok; then
    echo "::notice::Dakota already installed in ${PREFIX}/envs/dakota"
else
    miniforge_bootstrap "${PREFIX}" || exit 1
    echo "::notice::Creating the dakota env (dakota=${DAKOTA_VERSION} from conda-forge)"
    if ! "${PREFIX}/bin/conda" create -y -n dakota "dakota=${DAKOTA_VERSION}"; then
        echo "::error::conda create -n dakota dakota=${DAKOTA_VERSION} failed"
        exit 1
    fi
    if ! f_dakota_ok; then
        echo "::error::Dakota installed but 'dakota --version' does not run"
        exit 1
    fi
    echo "::notice::Dakota ${DAKOTA_VERSION} ready"
fi
if [ -n "${1:-}" ]; then
    miniforge_env_file "${PREFIX}" dakota "$1"
fi
