#!/bin/bash
# The desktop variant's startup command: Isaac Sim's GUI from the SIF, on the KasmVNC
# desktop this runs in. The kasmvnc workflow starts it with DISPLAY and XAUTHORITY set;
# the X socket sits beside the authority file (the desktop container's /tmp), so both
# are bound where Kit looks. Written by preprocessing with the paths filled in, as
# launch-gui.sh; the desktop variant passes `bash <job dir>/launch-gui.sh`.
#
# Variables filled in: container_sif, cache_dir, gui_app (isaac-sim | isaac-sim.newton)
set -x
trap 'kill -- -$$ 2> /dev/null' EXIT
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
singularity exec --nv --cleanenv "${userns[@]}" "${fips[@]}" \
    --home "${cache_dir}:/cache" --bind "${cache_dir}/kit:/isaac-sim/kit/cache" \
    --bind "${tmp}/.X11-unix:/tmp/.X11-unix" --bind "${XAUTHORITY}:/tmp/.Xauthority" \
    --env "DISPLAY=${DISPLAY}" --env XAUTHORITY=/tmp/.Xauthority --env ACCEPT_EULA=Y \
    "${container_sif}" "/isaac-sim/${gui_app}.sh" --/app/window/width=1600 --/app/window/height=960 &
wait $!
