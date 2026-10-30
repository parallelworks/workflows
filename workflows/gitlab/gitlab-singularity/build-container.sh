#!/usr/bin/env bash
# Builds the GitLab Singularity SIF from gitlab.def (the official
# gitlab/gitlab-ee image) for upload to ghcr.io/parallelworks/gitlab:<tag>
# via ORAS, the file named after the tag because the controller pulls it by
# that name (GITLAB_SIF_TAG in controller.sh).
#
# Usage: ./build-container.sh
#
# Prerequisites: singularity (or apptainer), oras; about 5 GB of scratch and
# 2 GB for the image
#
# After running, push the resulting SIF (the package must be public):
#   oras push ghcr.io/parallelworks/gitlab:<tag> gitlab-<tag>.sif

set -euo pipefail

cd "$(dirname "$0")"
TAG=$(sed -n 's/^GITLAB_SIF_TAG=//p' controller.sh)
SIF_NAME="gitlab-${TAG}.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${SIF_NAME} from gitlab.def"
singularity build --force "${SIF_NAME}" gitlab.def

singularity exec "${SIF_NAME}" sh -c 'cat /RELEASE | grep RELEASE_VERSION; test -x /assets/init-container && test -f /assets/sshd_config && echo "entrypoint and sshd_config present"'

echo ""
echo "Build complete: ${SIF_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/gitlab:${TAG} ${SIF_NAME}"
