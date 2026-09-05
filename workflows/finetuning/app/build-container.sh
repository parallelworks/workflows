#!/usr/bin/env bash
# Standalone, workflow-independent build of finetune.sif. Runnable by hand:
#   bash app/build-container.sh [output_sif_path] [registry_tag] [requirements_file]
#
# The third argument selects the pin set: requirements.txt (default, the
# transformers 4.x stack that serves every profile except gemma-4-31b) or
# requirements-tf5.txt (transformers 5.x, needed for gemma-4-31b -- read that
# file's header for its regressions). It is staged into a temp build dir as
# `requirements.txt` so finetune.def's %files line stays constant and the
# repo's own requirements.txt is never modified.
#
# This is the SINGLE source of truth for building the image -- controller.sh's
# `build` container_mode calls this exact script (never duplicates the build
# logic), and a maintainer can run it directly the same way.
#
# Requires: singularity or apptainer with fakeroot support. Building itself
# does not require a GPU. For unprivileged hosts without fakeroot, use
# `singularity build --remote` instead (not automated here -- see the
# commented alternative below).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${APP_DIR}"

OUTPUT_SIF="${1:-finetune.sif}"
REGISTRY_TAG="${2:-}"
REQUIREMENTS_FILE="${3:-${REQUIREMENTS_FILE:-requirements.txt}}"

export SINGULARITY_TMPDIR="${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}"
export SINGULARITY_CACHEDIR="${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}"
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}" "$(dirname "${OUTPUT_SIF}")"

if ! [ -f "${REQUIREMENTS_FILE}" ]; then
    echo "::error title=Error::requirements file not found: ${REQUIREMENTS_FILE} (looked in ${APP_DIR})"
    exit 1
fi
# Absolute, because the build runs from the staging dir below.
OUTPUT_SIF="$(cd "$(dirname "${OUTPUT_SIF}")" && pwd)/$(basename "${OUTPUT_SIF}")"

# Stage def + chosen pins into a temp dir and build from there. %files paths
# resolve against the build cwd, so staging the selected file as
# `requirements.txt` lets one unmodified finetune.def serve both pin sets --
# and leaves the repo's requirements.txt untouched.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cp finetune.def "${BUILD_DIR}/finetune.def"
cp "${REQUIREMENTS_FILE}" "${BUILD_DIR}/requirements.txt"
echo "::notice::Building with pin set: ${REQUIREMENTS_FILE} ($(grep -c . "${REQUIREMENTS_FILE}") lines, transformers=$(grep -oE '^transformers==[0-9.]+' "${REQUIREMENTS_FILE}" || echo unpinned))"
cd "${BUILD_DIR}"

SING=$(command -v singularity || command -v apptainer) || {
    echo "::error title=Error::no singularity/apptainer on PATH"
    exit 1
}

echo "::group::Building ${OUTPUT_SIF} from finetune.def"
if ! "${SING}" build --force --fakeroot "${OUTPUT_SIF}" finetune.def; then
    # --fakeroot needs newuidmap/newgidmap to be setuid-root (or have
    # cap_setuid/cap_setgid); many dev hosts don't have that configured but
    # do have passwordless sudo, which performs a real (non-fakeroot) root
    # build just as well.
    if sudo -n true 2>/dev/null; then
        echo "::notice::--fakeroot build failed (newuidmap likely not setuid-root); retrying with sudo"
        sudo "${SING}" build --force "${OUTPUT_SIF}" finetune.def
        sudo chown "$(id -u):$(id -g)" "${OUTPUT_SIF}"
    else
        echo "::error title=Error::--fakeroot build failed and no passwordless sudo available. " \
             "For unprivileged hosts without either, use: ${SING} build --remote ${OUTPUT_SIF} finetune.def"
        exit 1
    fi
fi
echo "::endgroup::"

echo "::group::Smoke test"
"${SING}" exec "${OUTPUT_SIF}" python3 -c "import torch, transformers, peft, trl, accelerate; print('build ok')"
echo "::endgroup::"

echo "Built: $(readlink -f "${OUTPUT_SIF}")"

if [ -n "${REGISTRY_TAG}" ]; then
    echo "::group::Pushing to ${REGISTRY_TAG}"
    oras push "${REGISTRY_TAG}" "${OUTPUT_SIF}"
    echo "::endgroup::"
fi
