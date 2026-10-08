#!/bin/bash
# Usage: install-paraview.sh [env-file]
# Idempotent install of the official ParaView Linux binaries (no sudo) under
# ${service_parent_install_dir:-$HOME/pw/software}/openfoam-naca/paraview, for
# the pvpython rendering of solved cases (render-images.sh). Runs on the login
# node with internet access; safe to re-run — a working pvpython is detected
# and kept. With [env-file], writes the sourceable activation (PATH) there, the
# contract of tools/utils/prepare-env.sh. PARAVIEW_VERSION picks the release
# (default 6.1.1, ~830 MB download, 2.7 GB on disk); PARAVIEW_URL replaces the
# download URL altogether (another mirror, another build).
#
# The official binaries rather than conda-forge: one self-contained tarball,
# and since ParaView 6.0 the single Linux build renders offscreen without a
# display or any system GL library (it falls back to its bundled OSMesa when
# DISPLAY is unset), where the separate 5.13 "osmesa" build needed the system's
# libglapi.so.0, absent on minimal cloud images (gcpsmall, 2026-10-08). Only
# x86_64 binaries are published: on another architecture give the form a
# paraview_load snippet (a site module) instead. The first install renders a
# test image, so a node where offscreen rendering cannot work fails here, once,
# rather than silently in every case.
set -o pipefail

PARAVIEW_VERSION="${PARAVIEW_VERSION:-6.1.1}"
SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
PREFIX="${SOFTWARE_DIR}/openfoam-naca/paraview"
INSTALL_DIR="${PREFIX}/ParaView-${PARAVIEW_VERSION}"
arch=$(uname -m)
series="v${PARAVIEW_VERSION%.*}"
tarball="ParaView-${PARAVIEW_VERSION}-MPI-Linux-Python3.12-${arch}.tar.gz"
PARAVIEW_URL="${PARAVIEW_URL:-https://www.paraview.org/files/${series}/${tarball}}"

# several cases of one run may install at once (a design of experiments on a
# cold cluster): the first one installs while the others wait here
mkdir -p "${PREFIX}" || exit 1
exec 9> "${PREFIX}.lock" && flock 9

f_pvpython_ok() {
    [ -x "${INSTALL_DIR}/bin/pvpython" ] && "${INSTALL_DIR}/bin/pvpython" --version > /dev/null 2>&1
}

f_download() {
    local url="$1" out="$2"
    if command -v wget > /dev/null 2>&1; then
        wget --timeout=60 --tries=3 -nv -O "${out}" "${url}"
    elif command -v curl > /dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 60 -o "${out}" "${url}"
    else
        echo "::error::neither wget nor curl is available to download ParaView"
        return 1
    fi
}

# a sphere rendered to a PNG without a display: the check that pvpython can
# render offscreen on this node (the OpenFOAM reader and the real images come
# later, in render-case.py)
f_render_ok() {
    local tmp
    tmp=$(mktemp -d /tmp/paraview-check-XXXXXX)
    cat > "${tmp}/check.py" << 'EOF'
import os
import sys
from paraview.simple import *
view = GetActiveViewOrCreate("RenderView")
Show(Sphere(), view)
Render(view)
SaveScreenshot(sys.argv[1], view, ImageResolution=[200, 150])
print("rendered %d bytes" % os.path.getsize(sys.argv[1]), flush=True)
# no interpreter teardown: pvpython's exit has hung in the software renderer's
# thread teardown after the image was written (render-case.py does the same)
os._exit(0)
EOF
    # the OSMesa software renderer named outright, then the build's own backend
    # choice (render-images.sh tries the same two, then xvfb-run)
    for backend in "VTK_DEFAULT_OPENGL_WINDOW=vtkOSOpenGLRenderWindow" ""; do
        rm -f "${tmp}/check.png"
        timeout -k 10 300 env ${backend} "${INSTALL_DIR}/bin/pvpython" --force-offscreen-rendering "${tmp}/check.py" "${tmp}/check.png" >> "${tmp}/check.log" 2>&1
        if [ -s "${tmp}/check.png" ]; then
            rm -rf "${tmp}"
            return 0
        fi
    done
    echo "::error::${INSTALL_DIR}/bin/pvpython cannot render offscreen on this node; its output follows"
    cat "${tmp}/check.log"
    rm -rf "${tmp}"
    return 1
}

if f_pvpython_ok; then
    echo "::notice::ParaView already installed in ${INSTALL_DIR} ($("${INSTALL_DIR}/bin/pvpython" --version 2>/dev/null))"
    # the render check is repeated until it has passed once (a node whose first
    # check failed keeps the 2.7 GB install and gets checked again)
    if [ ! -f "${INSTALL_DIR}/.render-checked" ]; then
        f_render_ok || exit 1
        touch "${INSTALL_DIR}/.render-checked"
        echo "::notice::offscreen rendering checked"
    fi
else
    if [ "${arch}" != x86_64 ] && [[ "${PARAVIEW_URL}" == https://www.paraview.org/* ]]; then
        echo "::error::ParaView publishes Linux binaries for x86_64 only (this node is ${arch}): give the form the commands that load a site ParaView (paraview_load) or set PARAVIEW_URL to a build for this architecture"
        exit 1
    fi
    download=$(mktemp "${PREFIX}/download-XXXXXX.tar.gz")
    echo "::notice::Downloading ${PARAVIEW_URL}"
    if ! f_download "${PARAVIEW_URL}" "${download}"; then
        rm -f "${download}"
        echo "::error::Could not download ParaView ${PARAVIEW_VERSION} from ${PARAVIEW_URL}; check PARAVIEW_VERSION (the file name follows the paraview.org release naming) or set PARAVIEW_URL"
        exit 1
    fi
    extract=$(mktemp -d "${PREFIX}/extract-XXXXXX")
    echo "::notice::Extracting $(du -h "${download}" | cut -f1) into ${INSTALL_DIR}"
    if ! tar -xzf "${download}" -C "${extract}"; then
        rm -rf "${download}" "${extract}"
        echo "::error::The ParaView tarball could not be extracted"
        exit 1
    fi
    rm -f "${download}"
    # the top directory of the official tarball names the build; whatever it is
    # called, the install is the directory holding bin/pvpython
    top=$(find "${extract}" -maxdepth 3 -type f -name pvpython -path '*/bin/*' | head -1)
    if [ -z "${top}" ]; then
        rm -rf "${extract}"
        echo "::error::No bin/pvpython in the downloaded tarball"
        exit 1
    fi
    rm -rf "${INSTALL_DIR}"
    mv "$(dirname "$(dirname "${top}")")" "${INSTALL_DIR}" || exit 1
    rm -rf "${extract}"
    if ! f_pvpython_ok; then
        echo "::error::ParaView extracted to ${INSTALL_DIR} but 'pvpython --version' does not run (missing system libraries? run it by hand to see)"
        "${INSTALL_DIR}/bin/pvpython" --version
        exit 1
    fi
    f_render_ok || exit 1
    touch "${INSTALL_DIR}/.render-checked"
    echo "::notice::ParaView ${PARAVIEW_VERSION} ready in ${INSTALL_DIR} (offscreen rendering checked)"
fi

if [ -n "${1:-}" ]; then
    cat > "$1" << EOT
# paraview environment: the ParaView ${PARAVIEW_VERSION} binaries under ${INSTALL_DIR}
export PATH="${INSTALL_DIR}/bin:\${PATH}"
EOT
fi
