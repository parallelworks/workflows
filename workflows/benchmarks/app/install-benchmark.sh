#!/bin/bash
# Usage: install-benchmark.sh <imb|ior> <mpi-env-file> <bin-dir-file>
#
# Builds the benchmark binaries against the MPI that sourcing <mpi-env-file>
# provides, idempotently, under
# ${service_parent_install_dir:-$HOME/pw/software}/benchmarks/<mpi>/, where
# <mpi> names the MPI installation by its directory (usr_lib64_openmpi, ...):
# one build per MPI, reused by every later run with that MPI, and MPI.txt in
# that directory says which. Writes the directory that holds the binaries into
# <bin-dir-file>. Runs on the login node with internet access; the compute
# nodes share the file system.
#
#   imb  IMB-MPI1 from the Intel MPI Benchmarks IMB_VERSION (default 2021.11);
#        an IMB-MPI1 already on PATH (Intel MPI ships one) is used as it is
#   ior  ior and mdtest from IOR IOR_VERSION (default 4.0.0)
set -o pipefail

tool="$1"
mpi_env="$2"
bin_dir_file="$3"
if [ -z "${tool}" ] || [ -z "${mpi_env}" ] || [ -z "${bin_dir_file}" ]; then
    echo "::error::usage: install-benchmark.sh <imb|ior> <mpi-env-file> <bin-dir-file>"
    exit 1
fi
IMB_VERSION="${IMB_VERSION:-2021.11}"
IOR_VERSION="${IOR_VERSION:-4.0.0}"

source "${mpi_env}" || exit 1
for cmd in mpicc mpirun; do
    if ! command -v "${cmd}" > /dev/null; then
        echo "::error::${cmd} is not on PATH after sourcing ${mpi_env}"
        exit 1
    fi
done

root="${service_parent_install_dir:-${HOME}/pw/software}/benchmarks"
mpi_home="$(cd "$(dirname "$(command -v mpicc)")/.." && pwd -P)"
mpi_id="$(printf '%s' "${mpi_home#/}" | tr '/' '_')"
install_dir="${root}/${mpi_id}"
mkdir -p "${install_dir}" || exit 1
# several runs on a cold cluster: the first one builds while the others wait here
exec 9> "${install_dir}/.lock" && flock 9 || exit 1
{
    echo "mpicc:  $(command -v mpicc)"
    echo "mpirun: $(command -v mpirun)"
    mpicc --version 2>/dev/null | head -n 1
    mpirun --version 2>/dev/null | head -n 1
} > "${install_dir}/MPI.txt"

f_download() {
    # f_download <url> <file>
    if [ -f "$2" ]; then
        return 0
    fi
    if ! wget --timeout=60 --tries=3 -nv -O "$2.tmp" "$1"; then
        rm -f "$2.tmp"
        echo "::error::Could not download $1"
        return 1
    fi
    mv "$2.tmp" "$2"
}

src="${install_dir}/src"
case "${tool}" in
    imb)
        if command -v IMB-MPI1 > /dev/null; then
            bin_dir="$(dirname "$(command -v IMB-MPI1)")"
            echo "::notice::IMB-MPI1: using the one on PATH, ${bin_dir}/IMB-MPI1"
        else
            bin_dir="${install_dir}/imb-${IMB_VERSION}"
            if [ -x "${bin_dir}/IMB-MPI1" ]; then
                echo "::notice::IMB-MPI1 ${IMB_VERSION} already built in ${bin_dir} ($(cat "${install_dir}/MPI.txt" | tail -n 1))"
            else
                if ! command -v mpicxx > /dev/null; then
                    echo "::error::mpicxx is not on PATH after sourcing ${mpi_env}; IMB-MPI1 is C++"
                    exit 1
                fi
                echo "::notice::Building IMB-MPI1 ${IMB_VERSION} with $(mpicxx --version | head -n 1) against $(mpirun --version | head -n 1) in ${bin_dir}"
                mkdir -p "${src}" || exit 1
                tarball="${src}/IMB-v${IMB_VERSION}.tar.gz"
                f_download "https://github.com/intel/mpi-benchmarks/archive/refs/tags/IMB-v${IMB_VERSION}.tar.gz" "${tarball}" || exit 1
                build="${src}/mpi-benchmarks-IMB-v${IMB_VERSION}"
                rm -rf "${build}"
                tar -xzf "${tarball}" -C "${src}" || exit 1
                # The Makefile compiles with -Werror (and -O0, Intel's own flags): Open MPI's
                # deprecated C++ bindings header trips it, so they are skipped (IMB uses the
                # C API), and so does the template-id warning GCC 14 introduced, demoted
                # for that compiler only (clang would reject the unknown option)
                cxxflags=""
                gnuc=$(echo | mpicxx -dM -E -x c++ - 2>/dev/null | awk '$2 == "__GNUC__" {print $3}')
                if ! echo | mpicxx -dM -E -x c++ - 2>/dev/null | grep -q __clang__ && [ "${gnuc:-0}" -ge 14 ]; then
                    cxxflags="-Wno-error=template-id-cdtor"
                fi
                if ! make -C "${build}" IMB-MPI1 CC=mpicc CXX=mpicxx CPPFLAGS="-DOMPI_SKIP_MPICXX" CXXFLAGS="${cxxflags}" > "${build}/make.log" 2>&1; then
                    echo "::error::The IMB-MPI1 build failed; tail of ${build}/make.log:"
                    tail -n 20 "${build}/make.log"
                    exit 1
                fi
                mkdir -p "${bin_dir}" && cp "${build}/IMB-MPI1" "${bin_dir}/" || exit 1
                rm -rf "${build}"
                echo "::notice::IMB-MPI1 ${IMB_VERSION} ready in ${bin_dir}"
            fi
        fi
        ;;
    ior)
        prefix="${install_dir}/ior-${IOR_VERSION}"
        bin_dir="${prefix}/bin"
        if [ -x "${bin_dir}/ior" ] && [ -x "${bin_dir}/mdtest" ]; then
            echo "::notice::IOR ${IOR_VERSION} (ior, mdtest) already built in ${bin_dir} ($(cat "${install_dir}/MPI.txt" | tail -n 1))"
        else
            echo "::notice::Building IOR ${IOR_VERSION} (ior, mdtest) with $(mpicc --version | head -n 1) against $(mpirun --version | head -n 1) in ${prefix}"
            mkdir -p "${src}" || exit 1
            tarball="${src}/ior-${IOR_VERSION}.tar.gz"
            f_download "https://github.com/hpc/ior/releases/download/${IOR_VERSION}/ior-${IOR_VERSION}.tar.gz" "${tarball}" || exit 1
            build="${src}/ior-${IOR_VERSION}"
            rm -rf "${build}"
            tar -xzf "${tarball}" -C "${src}" || exit 1
            # The release tarball ships configure (no automake needed) and Lustre support
            # is detected from the headers. gnu17 keeps GCC 15 (conda-forge) off C23, where
            # IOR 4.0.0's option.c does not compile.
            if ! (cd "${build}" && ./configure --prefix="${prefix}" CFLAGS="-g -O2 -std=gnu17" && make -j"$(nproc)" && make install) > "${build}.log" 2>&1; then
                echo "::error::The IOR build failed; tail of ${build}.log:"
                tail -n 20 "${build}.log"
                exit 1
            fi
            rm -rf "${build}"
            echo "::notice::IOR ${IOR_VERSION} ready in ${bin_dir}"
        fi
        ;;
    *)
        echo "::error::unknown benchmark tool '${tool}' (imb or ior)"
        exit 1
        ;;
esac
echo "${bin_dir}" > "${bin_dir_file}"
