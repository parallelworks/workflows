#!/bin/bash
# Usage: prepare-environments.sh <openfoam-load-file> [<paraview-load-file>]
#        (run from the job directory, where the app and tools/utils are checked out)
#
# The environment step of every openfoam-naca variant, and of the restart
# variants' preprocessing, one script so that the YAMLs differ only where the
# platform does: writes <job dir>/openfoam-env.sh, the file every later step and
# the case source to put OpenFOAM on PATH, from the form's load commands (the
# file given, written by the step from its quoted heredoc so the commands reach
# here verbatim; empty: the conda-forge install of install-openfoam.sh), and
# checks that it delivers the tools the case needs; the same for ParaView
# (paraview-env.sh, install-paraview.sh) when images are wanted. Environment:
#   CORES_PER_CASE   > 1 adds decomposePar, reconstructPar and the MPI launcher
#   GENERATE_IMAGES  true: ParaView too
#   RESOURCE_IP      the resource's login host: on NOAA's systems the install goes
#                    to the cluster's shared software tree when it is writable
set -o pipefail
set -x
openfoam_load="$1"
paraview_load="${2:-/dev/null}"
if [ -z "${openfoam_load}" ] || [ ! -f "${openfoam_load}" ]; then
    echo "::error::usage: prepare-environments.sh <openfoam-load-file> [<paraview-load-file>]"
    exit 1
fi
cores="${CORES_PER_CASE:-1}"
if ! [[ "${cores}" =~ ^[0-9]+$ ]] || [ "${cores}" -lt 1 ]; then
    echo "::error::cores_per_case must be a positive integer, got '${cores}'"
    exit 1
fi
# NOAA home directories are small: when no environment commands are given, the
# conda-forge install goes to the cluster's shared software tree if this account
# can write there. Probe by creating the directory rather than reading mode
# bits: the trees are group- or ACL-writable and list as root-owned. Only the
# installer reads this; the environment file it writes records the absolute
# prefix
case "${RESOURCE_IP}" in
    hfe[0-9]*.fairmont.rdhpcs.noaa.gov) shared=/contrib/pw ;;          # Hera
    mfe[0-9]*.fairmont.rdhpcs.noaa.gov) shared=/contrib/pw ;;          # Mercury
    ufe[0-9]*.fairmont.rdhpcs.noaa.gov) shared=/contrib/pw ;;          # Ursa
    gaea[0-9]*.ncrc.gov) shared=/usw/rdhpcs/software/pw ;;             # Gaea
    *) shared="" ;;                                                    # PPAN, cloud clusters, every other platform
esac
if [ -n "${shared}" ] && mkdir -p "${shared}/openfoam-naca" 2>/dev/null; then
    export service_parent_install_dir="${shared}"
    echo "::notice::installing under the shared software directory ${shared}"
fi
required="blockMesh potentialFoam simpleFoam"
if [ "${cores}" -gt 1 ]; then
    required="${required} decomposePar reconstructPar mpirun"
fi
bash tools/utils/prepare-env.sh openfoam "${PWD}/openfoam-env.sh" \
    workflows/openfoam-naca/app/install-openfoam.sh ${required} < "${openfoam_load}" || exit 1
if [ "${GENERATE_IMAGES}" = true ]; then
    bash tools/utils/prepare-env.sh paraview "${PWD}/paraview-env.sh" \
        workflows/openfoam-naca/app/install-paraview.sh pvpython < "${paraview_load}" || exit 1
fi
