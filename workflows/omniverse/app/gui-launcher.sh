#!/bin/bash
# The desktop variant's startup command: Isaac Sim's GUI from the SIF, on the KasmVNC
# desktop this runs in. The kasmvnc workflow starts it with DISPLAY and XAUTHORITY set;
# the X socket sits beside the authority file (the desktop container's /tmp), so both
# are bound where Kit looks. app/create-launcher.sh writes it as launch-gui.sh with
# container_sif, cache_dir and gui_app (isaac-sim | isaac-sim.newton) filled in.
set -x
tmp=$(dirname "${XAUTHORITY}")
mkdir -p "${cache_dir}/kit"
userns=()
if ! singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    userns=(--userns)
fi
fips=()
if [ "$(cat /proc/sys/crypto/fips_enabled 2> /dev/null)" = 1 ]; then
    fips=(--env OPENSSL_FORCE_FIPS_MODE=0)
fi
# Kit leads a process group of its own, so ending this launcher ends Kit with it: a
# signal to the starter alone leaves the process inside the container running
setsid singularity exec --nv --cleanenv "${userns[@]}" "${fips[@]}" \
    --home "${cache_dir}:/cache" --bind "${cache_dir}/kit:/isaac-sim/kit/cache" \
    --bind "${tmp}/.X11-unix:/tmp/.X11-unix" --bind "${XAUTHORITY}:/tmp/.Xauthority" \
    --env "DISPLAY=${DISPLAY}" --env XAUTHORITY=/tmp/.Xauthority --env ACCEPT_EULA=Y \
    "${container_sif}" "/isaac-sim/${gui_app}.sh" --/app/window/width=1600 --/app/window/height=960 &
kit=$!
trap 'kill -TERM -- -"${kit}" 2> /dev/null; sleep 2; kill -KILL -- -"${kit}" 2> /dev/null' EXIT INT TERM HUP
wait "${kit}"
