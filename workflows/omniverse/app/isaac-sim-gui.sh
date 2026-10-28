#!/bin/bash
# Isaac Sim's own window, from the workflow's Singularity image, on the desktop this
# runs in. The desktop variants start it as the KasmVNC desktop's startup application;
# from a platform desktop session's Terminal it is
#
#     ~/pw/software/omniverse/isaac-sim-gui.sh            # PhysX
#     ~/pw/software/omniverse/isaac-sim-gui.sh newton     # Newton physics
#
# The Singularity runtime's controller installs this file beside the SIF it pulls, so
# any run of the workflow with that runtime leaves both in the install directory. The
# window takes about three minutes to appear; the shader caches it shares with the
# workflow's runs make the next start faster. Kit needs the desktop's DISPLAY and its
# X authority file, which the desktop's terminal (or the kasmvnc workflow) provides;
# a desktop whose X socket is not under /tmp/.X11-unix keeps it beside that file.
set -eo pipefail
app="isaac-sim"
case "${1:-}" in
    ""|physx) ;;
    newton) app="isaac-sim.newton" ;;
    *) echo "usage: $0 [physx|newton]"; exit 1 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
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
echo "Starting ${app} from ${sif} on display ${DISPLAY}; the window takes a few minutes"
exec singularity exec --nv --cleanenv "${userns[@]}" "${fips[@]}" "${sockets[@]}" \
    --home "${cache}:/cache" --bind "${cache}/kit:/isaac-sim/kit/cache" \
    --bind "${xauth}:/tmp/.Xauthority" \
    --env "DISPLAY=${DISPLAY}" --env XAUTHORITY=/tmp/.Xauthority --env ACCEPT_EULA=Y \
    "${sif}" "/isaac-sim/${app}.sh" "${@:2}"
