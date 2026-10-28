#!/usr/bin/env bash
# Builds the OpenProject Singularity SIF from openproject.def (the official
# openproject/openproject:17-slim image plus PostgreSQL 17 and nginx) for upload
# to ghcr.io/parallelworks/openproject:17.0 via ORAS.
#
# Usage: ./build-container.sh
#
# Prerequisites: singularity (or apptainer) with fakeroot support, oras
#
# After running, push the resulting openproject.sif (the package must be public):
#   oras push ghcr.io/parallelworks/openproject:17.0 openproject.sif

set -euo pipefail

cd "$(dirname "$0")"
SIF_NAME="openproject.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${SIF_NAME} from openproject.def"
singularity build --force --fakeroot "${SIF_NAME}" openproject.def

singularity exec "${SIF_NAME}" bash -c 'nginx -v && /usr/lib/postgresql/17/bin/postgres --version && cd /app && bundle exec rails --version'

echo ""
echo "Build complete: ${SIF_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/openproject:17.0 ${SIF_NAME}"
