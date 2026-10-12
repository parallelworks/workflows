#!/bin/bash
# Installs Intel oneAPI MPI and compilers with spack under the install directory
# and writes load-intel-oneapi-mpi.sh, the file the CWL steps source to get
# mpicc and mpirun. Idempotent: the load file marks a completed install.
set -o pipefail
set -x

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
load_file=${service_parent_install_dir}/load-intel-oneapi-mpi.sh

if [ -f "${load_file}" ]; then
    echo "Intel oneAPI MPI is already installed (${load_file} exists)."
    echo "To reinstall, delete the file and rerun the job."
    exit 0
fi

set -e
mkdir -p "${service_parent_install_dir}"
cd "${service_parent_install_dir}"
if [ ! -d spack ]; then
    git clone -c feature.manyFiles=true --depth 1 https://github.com/spack/spack.git
fi
. "${service_parent_install_dir}/spack/share/spack/setup-env.sh"
spack install intel-oneapi-mpi intel-oneapi-compilers gcc-runtime

# the load file is written last, so a failed install never looks complete
cat > "${load_file}" <<HERE
#!/bin/bash
. ${service_parent_install_dir}/spack/share/spack/setup-env.sh
spack load intel-oneapi-compilers intel-oneapi-mpi
HERE
