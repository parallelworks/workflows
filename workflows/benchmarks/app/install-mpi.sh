#!/bin/bash
# Usage: MPI_PROVIDER=auto|conda-forge install-mpi.sh <env-file>
#
# Provides an MPI for the benchmarks when the form gives no load commands, and
# writes the sourceable activation into <env-file>: the contract of
# tools/utils/prepare-env.sh, which runs this installer when the load snippet is
# empty and then checks that sourcing the file puts mpicc and mpirun on PATH.
# Runs on the login node with internet access; safe to re-run.
#
# auto (default): the first of these that provides mpicc and mpirun wins: the
#   PATH as it is; a system MPI module (mpi/openmpi-x86_64 and mpi/mpich-x86_64,
#   the EL package modules, then openmpi and mpich); OpenMPI from conda-forge.
# conda-forge: OpenMPI (with conda's compilers, which its wrappers call) under
#   ${service_parent_install_dir:-$HOME/pw/software}/benchmarks/miniforge, env
#   mpi; no sudo, ~2 GB, once. Verified to launch across SLURM nodes with
#   plain mpirun (its PRRTE has the slurm and pbs components).
set -o pipefail
app_dir="$(cd "$(dirname "$0")" && pwd)"
source "${app_dir}/../../../tools/utils/miniforge.sh" || exit 1

env_file="$1"
if [ -z "${env_file}" ]; then
    echo "::error::usage: install-mpi.sh <env-file>"
    exit 1
fi
provider="${MPI_PROVIDER:-auto}"

# a workflow step is not a login shell, so `module` may be undefined there
read -r -d '' MODULE_INIT << 'EOT' || true
if ! command -v module > /dev/null 2>&1; then
    for f in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \
             /usr/share/lmod/lmod/init/bash /usr/share/Modules/init/bash; do
        if [ -r "${f}" ]; then
            source "${f}"
            break
        fi
    done
fi
EOT

f_provides_mpi() {
    # does a fresh shell that runs the snippet have mpicc and mpirun on PATH?
    bash -c "${MODULE_INIT}
${1}
command -v mpicc > /dev/null && command -v mpirun > /dev/null" > /dev/null 2>&1
}

f_write_env() {
    printf '# MPI environment: %s\n%s\n%s\n' "$1" "${MODULE_INIT}" "$2" > "${env_file}"
}

case "${provider}" in
    auto)
        if f_provides_mpi ""; then
            echo "::notice::MPI: using the mpicc and mpirun already on PATH ($(command -v mpirun))"
            f_write_env "mpicc and mpirun were already on PATH" ""
            exit 0
        fi
        for mod in mpi/openmpi-x86_64 mpi/mpich-x86_64 openmpi mpich; do
            if f_provides_mpi "module load ${mod} > /dev/null 2>&1 || exit 1"; then
                echo "::notice::MPI: using the system module ${mod}"
                f_write_env "the system module ${mod}" "module load ${mod}"
                exit 0
            fi
        done
        echo "::notice::MPI: nothing on PATH and no system MPI module; using OpenMPI from conda-forge"
        ;;
    conda-forge) ;;
    *)
        echo "::error::MPI_PROVIDER must be auto or conda-forge, not '${provider}'"
        exit 1
        ;;
esac

PREFIX="$(miniforge_prefix benchmarks)"
MPI_ENV="${PREFIX}/envs/mpi"
miniforge_lock "${PREFIX}" || exit 1
if [ -x "${MPI_ENV}/bin/mpicc" ] && [ -x "${MPI_ENV}/bin/mpirun" ]; then
    echo "::notice::MPI: using the conda-forge OpenMPI already installed in ${MPI_ENV}"
else
    miniforge_bootstrap "${PREFIX}" || exit 1
    echo "::notice::Creating the mpi env (openmpi and the compilers from conda-forge) in ${MPI_ENV}"
    if ! "${PREFIX}/bin/conda" create -y -n mpi openmpi openmpi-mpicc openmpi-mpicxx c-compiler cxx-compiler make; then
        echo "::error::conda create -n mpi failed"
        exit 1
    fi
    if ! [ -x "${MPI_ENV}/bin/mpicc" ] || ! [ -x "${MPI_ENV}/bin/mpirun" ]; then
        echo "::error::OpenMPI installed but ${MPI_ENV}/bin has no mpicc or mpirun"
        exit 1
    fi
    echo "::notice::$("${MPI_ENV}/bin/mpirun" --version 2>/dev/null | head -n 1) ready"
fi
miniforge_env_file "${PREFIX}" mpi "${env_file}"
