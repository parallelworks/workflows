#!/usr/bin/env bash
# Builds the Isaac Sim Singularity image from isaac-sim.def (the NGC image, with its
# files opened for reading by any user) for upload to ghcr.io via ORAS, where the
# controller pulls it with tools/oras/libs.sh:oras_pull_file.
#
# Usage: ./build-container.sh [output.sif]      (default: isaac-sim-6.2.0.1.sif here)
#
# Prerequisites: singularity (or apptainer) with fakeroot support, about 45 GB free
# under ${HOME} (the layers, the unpacked image and the SIF at once; the SIF is 11 GB)
#
# After running, push the SIF (the package must be public) and point
# app/controller.sh at the new tag:
#   tools/oras/oras push ghcr.io/parallelworks/isaac-sim:6.2.0.1 isaac-sim-6.2.0.1.sif

set -euo pipefail

cd "$(dirname "$0")"
sif="${1:-${PWD}/isaac-sim-6.2.0.1.sif}"

# Build scratch and the layer cache off /tmp, which is small and often noexec
export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${sif} from isaac-sim.def"
singularity build --force --fakeroot "${sif}" isaac-sim.def

# Smoke test as the current user: --userns covers hosts whose kernel cannot mount
# a SIF (hardened images disable squashfs)
singularity exec --userns "${sif}" cat /isaac-sim/VERSION

echo ""
echo "Build complete: ${sif}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  tools/oras/oras push ghcr.io/parallelworks/isaac-sim:6.2.0.1 ${sif}"
