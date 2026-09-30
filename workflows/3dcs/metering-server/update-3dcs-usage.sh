#!/bin/bash
# Starts the 3DCS usage metering daemon for this user, once. Safe to run by hand or
# from cron (@reboot). Reads PW_PLATFORM_HOST and PW_API_KEY from ~/.3dcs/env (mode 600).
dcs_dir="${HOME}/.3dcs"
script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-3dcs-usage.py"
mkdir -p "${dcs_dir}"

if [ ! -f "${dcs_dir}/env" ]; then
    echo "ERROR: ${dcs_dir}/env not found; it must export PW_PLATFORM_HOST and PW_API_KEY" >&2
    exit 1
fi
set -a
source "${dcs_dir}/env"
set +a
if [ -z "${PW_PLATFORM_HOST}" ] || [ -z "${PW_API_KEY}" ]; then
    echo "ERROR: ${dcs_dir}/env must export PW_PLATFORM_HOST and PW_API_KEY" >&2
    exit 1
fi

# The bracket keeps this shell's own command line from matching
if pids=$(pgrep -u "$(id -u)" -f 'update-3dcs-usage[.]py'); then
    echo "update-3dcs-usage.py is already running (pid $(echo ${pids}))"
    exit 0
fi

nohup python3 "${script}" &> "${dcs_dir}/update-3dcs-usage.out" &
echo $! > "${dcs_dir}/update-3dcs-usage.pid"
sleep 2
if ! kill -0 "$(cat "${dcs_dir}/update-3dcs-usage.pid")" 2>/dev/null; then
    echo "ERROR: update-3dcs-usage.py exited at once:" >&2
    cat "${dcs_dir}/update-3dcs-usage.out" >&2
    exit 1
fi
echo "Started update-3dcs-usage.py (pid $(cat "${dcs_dir}/update-3dcs-usage.pid")); log: ${dcs_dir}/update-3dcs-usage.log"
