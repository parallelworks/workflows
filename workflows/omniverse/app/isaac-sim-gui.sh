#!/bin/bash
# Isaac Sim's own window, from the workflow's Singularity image, on the desktop this
# runs in. The desktop workflow starts it in the platform desktop session it creates;
# from any desktop session's terminal on a GPU node it is
#
#     ~/pw/software/omniverse/isaac-sim-gui.sh            # PhysX
#     ~/pw/software/omniverse/isaac-sim-gui.sh newton     # Newton physics
#     ~/pw/software/omniverse/isaac-sim-gui.sh physx ~/pw/omniverse/stages/study
#
# and the Applications menu's Isaac Sim entry runs the first.
#
# A stage after the application (a .usd/.usda/.usdc file, or a directory holding
# study.usda, as the usd-export workflow writes it) is opened once it exists and
# reloaded whenever it or a layer it uses changes on disk (kit-scripts/stage-follow.py),
# so designs appear as they are exported. Arguments that start with a dash go to Kit, in
# place of the stage or after it.
#
# The Singularity runtime's controller installs this file beside the SIF it pulls, so
# any run of the workflow with that runtime leaves both in the install directory. The
# first start on a node compiles the shaders (a few minutes); the caches it shares with
# the workflow's runs make later starts take under a minute. Kit needs the desktop's
# DISPLAY and its X authority file, which the desktop's terminal provides, and the GLX
# extension in its X server, which is checked first; a desktop whose X socket is not
# under /tmp/.X11-unix keeps it beside the authority file.
set -eo pipefail
app="isaac-sim"
case "${1:-}" in
    ""|physx) ;;
    newton) app="isaac-sim.newton" ;;
    *) echo "usage: $0 [physx|newton] [stage] [kit arguments]"; exit 1 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
follow=()
kit_args=()
stage=""
passthrough=("${@:2}")
case "${2:-}" in
    -*) ;;
    ""|undefined) passthrough=("${@:3}") ;;
    *) stage="$2"; passthrough=("${@:3}") ;;
esac
if [ -n "${stage}" ]; then
    # Kit splits the exec string below on spaces
    case "${stage}" in
        *[[:space:]]*) echo "The stage path cannot contain spaces: ${stage}" >&2; exit 1 ;;
    esac
    case "${stage}" in
        *.usd|*.usda|*.usdc) ;;
        *) stage="${stage%/}/study.usda" ;;
    esac
    stage="$(realpath -m "${stage}")"
    mkdir -p "$(dirname "${stage}")"
    if ! [ -f "${here}/kit-scripts/stage-follow.py" ]; then
        echo "No ${here}/kit-scripts/stage-follow.py: run the omniverse workflow with the Singularity runtime once" >&2
        exit 1
    fi
    echo "Following ${stage}; it opens once it exists"
    # Kit spreads each frame over every GPU it finds by default; the viewer renders on one
    follow=(--bind "$(dirname "${stage}")" --bind "${here}/kit-scripts:/kit-scripts:ro")
    kit_args=(--/renderer/multiGpu/enabled=false --exec "/kit-scripts/stage-follow.py ${stage}")
fi
sif="${OMNIVERSE_SIF:-$(ls -t "${here}"/containers/isaac-sim-*.sif 2> /dev/null | head -n 1 || true)}"
if [ -z "${sif}" ] || ! [ -f "${sif}" ]; then
    echo "No Isaac Sim image under ${here}/containers: run the omniverse workflow with the Singularity runtime once, or set OMNIVERSE_SIF" >&2
    exit 1
fi
if [ -z "${DISPLAY:-}" ]; then
    echo "DISPLAY is not set: run this from the terminal of a desktop session" >&2
    exit 1
fi
# The desktop's X authority file: the terminal exports it, or the VNC server's own
xauth="${XAUTHORITY:-${HOME}/.Xauthority}"
if ! [ -f "${xauth}" ]; then
    display="${DISPLAY#:}"
    xauth="${HOME}/.vnc/xauth-${display%%.*}"
fi
if ! [ -f "${xauth}" ]; then
    echo "No X authority file for ${DISPLAY} (XAUTHORITY unset, none under ~/.vnc)" >&2
    exit 1
fi
display="${DISPLAY#:}"
display="${display%%.*}"
sockets=()
if ! [ -S "/tmp/.X11-unix/X${display}" ] && [ -S "$(dirname "${xauth}")/.X11-unix/X${display}" ]; then
    sockets=(--bind "$(dirname "${xauth}")/.X11-unix:/tmp/.X11-unix")
fi
cache="${here}/cache"
mkdir -p "${cache}/kit"
if ! which singularity > /dev/null 2>&1; then
    module load apptainer 2> /dev/null || module load singularity 2> /dev/null || { echo "singularity/apptainer not found" >&2; exit 1; }
fi
userns=()
if ! singularity exec "${sif}" /bin/true > /dev/null 2>&1; then
    userns=(--userns)
fi
fips=()
if [ "$(cat /proc/sys/crypto/fips_enabled 2> /dev/null)" = 1 ]; then
    fips=(--env OPENSSL_FORCE_FIPS_MODE=0)
fi
# --nv binds the driver libraries listed in the runtime's nvliblist.conf, which in
# apptainer 1.3 leaves out libnvidia-ngx.so.1; without it RTX has no DLSS denoiser
# ("Failed to create NGX context") and lit surfaces render grainy
ngx=()
ngx_lib=$(ldconfig -p 2> /dev/null | awk '/libnvidia-ngx\.so\.1 \(.*x86-64/ && !n {print $NF; n=1}' || true)
ngx_conf=$(singularity buildcfg 2> /dev/null | sed -n 's/^SYSCONFDIR=//p' || true)
if [ -r "${ngx_lib}" ] && ! grep -qs '^libnvidia-ngx' "${ngx_conf}"/{apptainer,singularity}/nvliblist.conf; then
    ngx=(--bind "${ngx_lib}:/.singularity.d/libs/libnvidia-ngx.so.1")
fi
# NVIDIA's driver crashes while Kit opens its window on an X server without GLX, so
# that is checked first, with the image's own Python and Xlib
glx_check='
import ctypes, sys
x = ctypes.CDLL("libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
d = x.XOpenDisplay(None)
if not d:
    sys.exit(2)
n = ctypes.c_int()
sys.exit(0 if x.XQueryExtension(ctypes.c_void_p(d), b"GLX", ctypes.byref(n), ctypes.byref(n), ctypes.byref(n)) else 3)'
glx=0
singularity -s exec --cleanenv "${userns[@]}" "${sockets[@]}" --bind "${xauth}:/tmp/.Xauthority" \
    --env "DISPLAY=${DISPLAY}" --env XAUTHORITY=/tmp/.Xauthority \
    "${sif}" /isaac-sim/kit/python/bin/python3 -c "${glx_check}" || glx=$?
case "${glx}" in
    0) ;;
    2) echo "Cannot open display ${DISPLAY} with ${xauth}" >&2; exit 1 ;;
    3) echo "The X server of ${DISPLAY} has no GLX extension, which Isaac Sim needs to open its window; a desktop session started by a newer platform agent has it" >&2; exit 1 ;;
    *) echo "Could not check ${DISPLAY} for GLX (exit status ${glx})" >&2; exit 1 ;;
esac
echo "Starting ${app} from ${sif} on display ${DISPLAY}; the window takes a few minutes"
exec singularity exec --nv --cleanenv "${userns[@]}" "${fips[@]}" "${ngx[@]}" "${sockets[@]}" "${follow[@]}" \
    --home "${cache}:/cache" --bind "${cache}/kit:/isaac-sim/kit/cache" \
    --bind "${xauth}:/tmp/.Xauthority" \
    --env "DISPLAY=${DISPLAY}" --env XAUTHORITY=/tmp/.Xauthority --env ACCEPT_EULA=Y \
    "${sif}" "/isaac-sim/${app}.sh" "${kit_args[@]}" "${passthrough[@]}"
