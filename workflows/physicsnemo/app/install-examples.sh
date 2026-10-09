#!/bin/bash
# Usage: install-examples.sh <ref> <path-file>
# Idempotent download of the PhysicsNeMo examples at git <ref> (a release tag such
# as v1.1.0, the one matching the container's PhysicsNeMo) into
# ${service_parent_install_dir:-$HOME/pw/software}/physicsnemo/src/physicsnemo-<ref>:
# a shallow, sparse clone of examples/ only (~10 MB instead of the repository's
# ~250 MB). Runs on the login node, which reaches GitHub, so the training job
# needs no internet access; the job mounts the tree read-only and copies the
# example it runs. Writes the tree's path to <path-file>. PHYSICSNEMO_REPO
# replaces the repository URL (a mirror).
set -o pipefail

ref="$1"
path_file="$2"
if [ -z "${ref}" ] || [ -z "${path_file}" ]; then
    echo "::error::usage: install-examples.sh <ref> <path-file>"
    exit 1
fi
if ! [[ "${ref}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "::error::the PhysicsNeMo examples version must be a git tag or branch name such as v1.1.0, got '${ref}'"
    exit 1
fi
PHYSICSNEMO_REPO="${PHYSICSNEMO_REPO:-https://github.com/NVIDIA/physicsnemo.git}"
SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
PREFIX="${SOFTWARE_DIR}/physicsnemo/src"
SRC_DIR="${PREFIX}/physicsnemo-${ref}"

mkdir -p "${PREFIX}" || exit 1
exec 9> "${SRC_DIR}.lock" && flock 9

if [ -f "${SRC_DIR}/.complete" ] && [ -d "${SRC_DIR}/examples/cfd" ]; then
    echo "::notice::PhysicsNeMo examples ${ref} already in ${SRC_DIR}"
else
    tmp=$(mktemp -d "${PREFIX}/clone-XXXXXX")
    cloned=false
    for attempt in 1 2 3; do
        rm -rf "${tmp}"
        if git clone --quiet --depth 1 --branch "${ref}" --filter=blob:none --sparse \
                "${PHYSICSNEMO_REPO}" "${tmp}" \
            && git -C "${tmp}" sparse-checkout set examples; then
            cloned=true
            break
        fi
        echo "::warning::clone attempt ${attempt} of ${PHYSICSNEMO_REPO} at ${ref} failed"
        sleep $(( attempt * 10 ))
    done
    if [ "${cloned}" != true ] || [ ! -d "${tmp}/examples/cfd" ]; then
        rm -rf "${tmp}"
        echo "::error::Could not get the PhysicsNeMo examples at ${ref} from ${PHYSICSNEMO_REPO}"
        exit 1
    fi
    rm -rf "${tmp}/.git" "${SRC_DIR}"
    mv "${tmp}" "${SRC_DIR}" || exit 1
    chmod -R a+rX "${SRC_DIR}"
    touch "${SRC_DIR}/.complete"
    echo "::notice::PhysicsNeMo examples ${ref} downloaded to ${SRC_DIR}"
fi
echo "${SRC_DIR}" > "${path_file}"
