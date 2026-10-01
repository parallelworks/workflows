#!/bin/bash
# Usage: install-openfoam.sh [env-file]
# Idempotent OpenFOAM install from conda-forge (no sudo) into
# ${service_parent_install_dir:-$HOME/pw/software}/openfoam-naca/miniforge. Runs
# on the login node with internet access; safe to re-run — a working env is
# detected and kept. With [env-file], writes the sourceable activation of the env
# there (the contract of tools/utils/prepare-env.sh). tools/utils is checked out
# next to this app by the workflow.
set -o pipefail
app_dir="$(cd "$(dirname "$0")" && pwd)"
source "${app_dir}/../../../tools/utils/miniforge.sh" || exit 1

OPENFOAM_VERSION="${OPENFOAM_VERSION:-2412}"
PREFIX="$(miniforge_prefix openfoam-naca)"
OPENFOAM_PREFIX="${PREFIX}/envs/openfoam"
miniforge_lock "${PREFIX}" || exit 1

f_openfoam_ok() {
    "${PREFIX}/bin/conda" run -n openfoam simpleFoam -help > /dev/null 2>&1
}

# conda-forge's openfoam=2412 ships the MPI Pstream under lib/mpich-3.3 while the
# binaries' rpath (and FOAM_MPI) name lib/sys-mpich, so a `-parallel` run resolves
# the dummy Pstream and aborts ("The dummy Pstream library cannot be used in
# parallel mode"); rpath beats LD_LIBRARY_PATH, so link the expected name instead
f_link_mpi_pstream() {
    local foam_mpi real
    foam_mpi=$("${PREFIX}/bin/conda" run -n openfoam printenv FOAM_MPI 2>/dev/null | tr -d '[:space:]')
    [ -n "${foam_mpi}" ] || return 0
    [ -e "${OPENFOAM_PREFIX}/lib/${foam_mpi}" ] && return 0
    real=$(ls -d "${OPENFOAM_PREFIX}"/lib/*/libPstream.so 2>/dev/null | grep -v '/dummy/' | head -1)
    if [ -z "${real}" ]; then
        echo "::warning::no MPI libPstream.so under ${OPENFOAM_PREFIX}/lib: parallel cases will not run"
        return 0
    fi
    ln -s "$(basename "$(dirname "${real}")")" "${OPENFOAM_PREFIX}/lib/${foam_mpi}" || return 1
    echo "::notice::linked lib/${foam_mpi} -> lib/$(basename "$(dirname "${real}")") so -parallel runs load the MPI Pstream"
}

if f_openfoam_ok; then
    echo "::notice::OpenFOAM already installed in ${OPENFOAM_PREFIX}"
else
    miniforge_bootstrap "${PREFIX}" || exit 1
    echo "::notice::Creating the openfoam env (openfoam=${OPENFOAM_VERSION} from conda-forge)"
    if ! "${PREFIX}/bin/conda" create -y -n openfoam "openfoam=${OPENFOAM_VERSION}"; then
        echo "::error::conda create -n openfoam openfoam=${OPENFOAM_VERSION} failed"
        exit 1
    fi
    if ! f_openfoam_ok; then
        echo "::error::OpenFOAM installed but 'simpleFoam -help' does not run"
        exit 1
    fi
    echo "::notice::OpenFOAM ${OPENFOAM_VERSION} ready"
fi
f_link_mpi_pstream || exit 1
if [ -n "${1:-}" ]; then
    miniforge_env_file "${PREFIX}" openfoam "$1"
fi
