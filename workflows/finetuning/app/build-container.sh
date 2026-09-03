#!/usr/bin/env bash
# Standalone, workflow-independent build of finetune.sif. Runnable by hand:
#   bash app/build-container.sh [output_sif_path] [registry_tag]
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

cd "$(dirname "${BASH_SOURCE[0]}")"   # always run from app/, so finetune.def's
                                       # %files requirements.txt resolves
                                       # regardless of the caller's cwd

OUTPUT_SIF="${1:-finetune.sif}"
REGISTRY_TAG="${2:-}"

export SINGULARITY_TMPDIR="${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}"
export SINGULARITY_CACHEDIR="${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}"
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}" "$(dirname "${OUTPUT_SIF}")"

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
