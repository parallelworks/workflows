#!/bin/bash
# Usage: install-container.sh <image> <path-file> [sif]
# The Singularity/Apptainer image the training runs in. With [sif] (a SIF the
# user already has) it only checks that the file is a readable image. Otherwise
# it builds docker://<image> once into
# ${service_parent_install_dir:-$HOME/pw/software}/physicsnemo/containers/<name>.sif
# and reuses it afterwards. Runs on the login node, which reaches the registry; the
# SIF sits on the shared filesystem for the compute nodes. Writes the SIF's path
# to <path-file>.
#
# The NGC PhysicsNeMo image is big (25.06: 17 GB of layers, 31 GB unpacked) and the
# build needs the layers, the unpacked tree and the SIF at once, so it checks the
# free space first and removes its scratch afterwards.
set -o pipefail

image="$1"
path_file="$2"
sif="$3"
if [ -z "${image}" ] || [ -z "${path_file}" ]; then
    echo "::error::usage: install-container.sh <image> <path-file> [sif]"
    exit 1
fi

if command -v singularity > /dev/null 2>&1; then
    runtime=singularity
elif command -v apptainer > /dev/null 2>&1; then
    runtime=apptainer
else
    echo "::error::the Singularity runtime needs singularity or apptainer on PATH, and the login node has neither; choose Docker on this cluster"
    exit 1
fi

if [ -n "${sif}" ]; then
    if [ ! -r "${sif}" ] || ! "${runtime}" inspect "${sif}" > /dev/null 2>&1; then
        echo "::error::${sif} is not a readable Singularity image"
        exit 1
    fi
    echo "::notice::Using the Singularity image ${sif}"
    echo "${sif}" > "${path_file}"
    exit 0
fi

SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
PREFIX="${SOFTWARE_DIR}/physicsnemo/containers"
name=$(printf '%s' "${image##*/}" | tr ':@' '--')
sif="${PREFIX}/${name}.sif"
REQUIRED_GB="${PHYSICSNEMO_SIF_BUILD_GB:-70}"

mkdir -p "${PREFIX}" || exit 1
exec 9> "${sif}.lock" && flock 9

if [ -s "${sif}" ] && "${runtime}" inspect "${sif}" > /dev/null 2>&1; then
    echo "::notice::Singularity image ${sif} already built"
else
    available_gb=$(df -Pk "${PREFIX}" | awk 'NR == 2 {print int($4 / 1048576)}')
    if [ "${available_gb:-0}" -lt "${REQUIRED_GB}" ]; then
        echo "::error::Building ${sif} from docker://${image} needs about ${REQUIRED_GB} GB free in ${PREFIX} (the layers, the unpacked image and the SIF at once); ${available_gb} GB are. Free space, point the install directory at a larger filesystem, give the path of a SIF built elsewhere, or use Docker."
        df -h "${PREFIX}"
        exit 1
    fi
    scratch=$(mktemp -d "${PREFIX}/build-XXXXXX")
    export SINGULARITY_TMPDIR="${scratch}/tmp" APPTAINER_TMPDIR="${scratch}/tmp"
    export SINGULARITY_CACHEDIR="${scratch}/cache" APPTAINER_CACHEDIR="${scratch}/cache"
    mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"
    echo "::notice::Building ${sif} from docker://${image} with ${runtime} (once; 7 minutes for the 25.06 image on a 20-core server with a fast link)"
    start=$(date +%s)
    if ! "${runtime}" build --force "${sif}.partial" "docker://${image}"; then
        rm -rf "${scratch}" "${sif}.partial"
        echo "::error::${runtime} could not build docker://${image}"
        df -h "${PREFIX}"
        exit 1
    fi
    rm -rf "${scratch}"
    mv "${sif}.partial" "${sif}" || exit 1
    chmod a+r "${sif}"
    echo "::notice::Built ${sif} ($(du -h "${sif}" | cut -f1)) in $(( ($(date +%s) - start) / 60 )) minutes"
fi
echo "${sif}" > "${path_file}"
