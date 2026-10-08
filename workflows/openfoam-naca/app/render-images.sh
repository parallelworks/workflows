#!/bin/bash
# Usage: render-images.sh <case dir> <images dir> [params.in] [results.out]
# Renders the fields of a solved OpenFOAM case (the directory holding case.foam)
# to PNG images in <images dir> with pvpython and render-case.py: pressure,
# velocity, streamlines, eddy viscosity, the wake and the mesh, each labeled
# with the design from params.in and the coefficients from results.out when
# those are given. PARAVIEW_ENV names a file sourced to put pvpython on PATH;
# unset, the binaries install-paraview.sh makes are used. pvpython of the
# official binaries renders offscreen by itself when there is no display; a
# site build that needs an X server is retried under xvfb-run where that
# exists. The full pvpython output is kept in <images dir>/render.log. Exit
# status 0 when the images were written, non-zero otherwise: the caller decides
# whether a case without images is a failed case (the workflow says no, the
# coefficients are already on disk).
set -o pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
case_dir="$1"
out="$2"
params="${3:-}"
results="${4:-}"
if [ -z "${case_dir}" ] || [ -z "${out}" ]; then
    echo "usage: render-images.sh <case dir> <images dir> [params.in] [results.out]"
    exit 2
fi
if [ ! -d "${case_dir}" ]; then
    echo "render-images: no case directory ${case_dir}"
    exit 1
fi

if [ -n "${PARAVIEW_ENV:-}" ]; then
    source "${PARAVIEW_ENV}" || { echo "render-images: sourcing ${PARAVIEW_ENV} failed"; exit 1; }
elif ! command -v pvpython > /dev/null 2>&1; then
    # the newest install of install-paraview.sh, when no environment was given
    for candidate in $(ls -d "${SOFTWARE_DIR}"/openfoam-naca/paraview/ParaView-*/bin 2>/dev/null | sort -V -r); do
        if [ -x "${candidate}/pvpython" ]; then
            export PATH="${candidate}:${PATH}"
            break
        fi
    done
fi
command -v pvpython > /dev/null 2>&1 || { echo "render-images: pvpython not on PATH after loading the ParaView environment (${PARAVIEW_ENV:-none given})"; exit 1; }

mkdir -p "${out}" || exit 1
args=(--case "${case_dir}" --out "${out}")
[ -n "${params}" ] && [ -f "${params}" ] && args+=(--params "${params}")
[ -n "${results}" ] && [ -f "${results}" ] && args+=(--results "${results}")
echo "--- render: $(command -v pvpython) render-case.py ${args[*]} (full output in ${out}/render.log)"

# render-case.py writes manifest.json after the last image, so the manifest is
# the proof of a complete render whatever pvpython's exit status: a pvpython
# that hangs on exit (seen once with the software renderer) is killed by the
# timeout (RENDER_TIMEOUT seconds, default 900) and the images are kept
f_render() {
    rm -f "${out}/manifest.json"
    timeout -k 10 "${RENDER_TIMEOUT:-900}" "$@" pvpython --force-offscreen-rendering "${APP_DIR}/render-case.py" "${args[@]}" >> "${out}/render.log" 2>&1
    local rc=$?
    if [ -f "${out}/manifest.json" ]; then
        [ "${rc}" -eq 0 ] || echo "render-images: pvpython exited ${rc} after writing every image; keeping them" | tee -a "${out}/render.log"
        return 0
    fi
    return 1
}

# three ways to get a render window, in order: the OSMesa software renderer
# named outright (the official binaries bundle it; VTK's own backend choice
# tried EGL on a node with NVIDIA libraries and no GPU and crashed, gcpsmall
# 2026-10-08), the build's default backend (a site build without OSMesa: EGL on
# a GPU node, X with a display), and a virtual X server for a build that needs one
: > "${out}/render.log"
if ! f_render env VTK_DEFAULT_OPENGL_WINDOW=vtkOSOpenGLRenderWindow; then
    echo "render-images: pvpython failed with the OSMesa backend; retrying with the build's default backend" | tee -a "${out}/render.log"
    if ! f_render env; then
        if [ -z "${DISPLAY:-}" ] && command -v xvfb-run > /dev/null 2>&1; then
            echo "render-images: pvpython failed without a display; retrying under xvfb-run" | tee -a "${out}/render.log"
            f_render xvfb-run -a || { echo "render-images: rendering failed (tail of ${out}/render.log follows)"; tail -n 20 "${out}/render.log"; exit 1; }
        else
            echo "render-images: rendering failed (tail of ${out}/render.log follows)"
            tail -n 20 "${out}/render.log"
            exit 1
        fi
    fi
fi
n=$(ls "${out}"/*.png 2>/dev/null | wc -l)
if [ "${n}" -eq 0 ]; then
    echo "render-images: pvpython exited 0 but wrote no image (tail of ${out}/render.log follows)"
    tail -n 20 "${out}/render.log"
    exit 1
fi
echo "render-images: ${n} images in $(cd "${out}" && pwd): $(cd "${out}" && ls *.png | tr '\n' ' ')"
