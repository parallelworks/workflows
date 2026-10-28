#!/bin/bash
# Usage: prepare-environment.sh <env-file> <load-file>
#        (run from the job directory, where the app and tools/utils are checked out)
#
# The environment step of the optimizer, one script so that the YAML carries no
# site logic: writes <env-file>, the script every later step sources to put Dakota
# on PATH, from the form's load commands (<load-file>, written by the step from its
# quoted heredoc so the commands reach here verbatim; empty: the conda-forge
# install of install-dakota.sh), and checks that it delivers `dakota`. Environment:
#   RESOURCE_IP   the resource's login host: on NOAA's systems the install goes to
#                 the cluster's shared software tree when it is writable
set -o pipefail
set -x
env_file="$1"
load_file="$2"
if [ -z "${env_file}" ] || [ -z "${load_file}" ] || [ ! -f "${load_file}" ]; then
    echo "::error::usage: prepare-environment.sh <env-file> <load-file>"
    exit 1
fi
# NOAA home directories are small: when no environment commands are given, the
# conda-forge install goes to the cluster's shared software tree if this account
# can write there. Probe by creating the directory rather than reading mode
# bits: the trees are group- or ACL-writable and list as root-owned. Only the
# installer reads this; the environment file it writes records the absolute
# prefix
shared=$(bash tools/utils/shared-software-dir.sh "${RESOURCE_IP}") || exit 1
if [ -n "${shared}" ] && mkdir -p "${shared}/dakota" 2>/dev/null; then
    export service_parent_install_dir="${shared}"
    echo "::notice::installing under the shared software directory ${shared}"
fi
bash tools/utils/prepare-env.sh dakota "${env_file}" \
    workflows/dakota/app/install-dakota.sh dakota < "${load_file}"
