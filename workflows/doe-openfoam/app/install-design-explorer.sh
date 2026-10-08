#!/bin/bash
# Usage: install-design-explorer.sh [path-file]
# Idempotent download of Design Explorer (https://github.com/tt-acm/DesignExplorer,
# a static web page: HTML, JavaScript and CSS, no build step; the server uses its
# libraries, d3 and d3.parcoords, under the app's own page) into
# ${service_parent_install_dir:-$HOME/pw/software}/doe-openfoam/DesignExplorer-<commit>,
# pinned to DESIGN_EXPLORER_COMMIT so every run serves the same page. Runs on
# the login node with internet access; safe to re-run — an install with its
# index.html is kept. Prints DESIGN_EXPLORER_DIR=<dir> and, with [path-file],
# writes that directory's path there. DESIGN_EXPLORER_URL replaces the tarball
# URL (a mirror).
set -o pipefail

DESIGN_EXPLORER_COMMIT="${DESIGN_EXPLORER_COMMIT:-215d17ee12deb1d27ec2b6c0c3887ef2e2f3fb0d}"
DESIGN_EXPLORER_URL="${DESIGN_EXPLORER_URL:-https://codeload.github.com/tt-acm/DesignExplorer/tar.gz/${DESIGN_EXPLORER_COMMIT}}"
SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
PREFIX="${SOFTWARE_DIR}/doe-openfoam"
INSTALL_DIR="${PREFIX}/DesignExplorer-${DESIGN_EXPLORER_COMMIT:0:12}"

mkdir -p "${PREFIX}" || exit 1
exec 9> "${PREFIX}/DesignExplorer.lock" && flock 9

f_download() {
    local url="$1" out="$2"
    if command -v wget > /dev/null 2>&1; then
        wget --timeout=60 --tries=3 -nv -O "${out}" "${url}"
    elif command -v curl > /dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 60 -o "${out}" "${url}"
    else
        echo "::error::neither wget nor curl is available to download Design Explorer"
        return 1
    fi
}

if [ -f "${INSTALL_DIR}/index.html" ] && [ -f "${INSTALL_DIR}/js/designExplorer.js" ]; then
    echo "::notice::Design Explorer already installed in ${INSTALL_DIR}"
else
    download=$(mktemp "${PREFIX}/download-XXXXXX.tar.gz")
    echo "::notice::Downloading ${DESIGN_EXPLORER_URL}"
    if ! f_download "${DESIGN_EXPLORER_URL}" "${download}"; then
        rm -f "${download}"
        echo "::error::Could not download Design Explorer from ${DESIGN_EXPLORER_URL}"
        exit 1
    fi
    extract=$(mktemp -d "${PREFIX}/extract-XXXXXX")
    if ! tar -xzf "${download}" -C "${extract}"; then
        rm -rf "${download}" "${extract}"
        echo "::error::The Design Explorer tarball could not be extracted"
        exit 1
    fi
    rm -f "${download}"
    top=$(find "${extract}" -maxdepth 2 -name index.html | head -1)
    if [ -z "${top}" ] || [ ! -f "$(dirname "${top}")/js/designExplorer.js" ]; then
        rm -rf "${extract}"
        echo "::error::No Design Explorer page (index.html + js/designExplorer.js) in the downloaded tarball"
        exit 1
    fi
    rm -rf "${INSTALL_DIR}"
    mv "$(dirname "${top}")" "${INSTALL_DIR}" || exit 1
    rm -rf "${extract}"
    echo "::notice::Design Explorer ready in ${INSTALL_DIR}"
fi

echo "DESIGN_EXPLORER_DIR=${INSTALL_DIR}"
if [ -n "${1:-}" ]; then
    echo "${INSTALL_DIR}" > "$1"
fi
