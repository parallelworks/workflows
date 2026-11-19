#!/bin/bash
# A platform desktop session on this node with Isaac Sim in it, for the desktop
# workflow (yamls/general-desktop.yaml), which sources inputs.sh first.
#
# pw sessions create starts the session's VNC server on this node, the resource's login
# node. The display the session opened is the one Xvnc of this user that was not running
# before; Isaac Sim is started on it through isaac-sim-gui.sh, detached, and the step
# ends when Kit reports "app ready". Isaac Sim exits by itself when the session is
# stopped, because its X server goes away, so stopping the session (the platform's
# Sessions page, or pw sessions stop <name>) is the whole teardown.
#
# Reads session_name, session_resource, desktop_app, desktop_stage,
# service_parent_install_dir and ready_minutes. Writes isaac-sim.log and, once Kit is
# ready, isaac-sim.ready, which tells the step's cleanup to leave the session running.
set -eo pipefail

launcher="${service_parent_install_dir}/omniverse/isaac-sim-gui.sh"
log="${PWD}/isaac-sim.log"
rm -f isaac-sim.ready

stop_session() {
    pw sessions stop "${session_name}" > /dev/null 2>&1 || true
}

f_fail() {
    echo "::error title=Error::$1"
    stop_session
    exit 1
}

# This user's Xvnc servers on this node, one "<display> <X authority file>" per line
xvnc_displays() {
    local pid arg display auth previous
    for pid in $(pgrep -u "$(id -u)" -x Xvnc || true); do
        display=""
        auth=""
        previous=""
        while IFS= read -r -d '' arg; do
            case "${arg}" in
                :[0-9]*) [ -z "${display}" ] && display="${arg#:}" ;;
            esac
            [ "${previous}" = -auth ] && auth="${arg}"
            previous="${arg}"
        done < "/proc/${pid}/cmdline" 2> /dev/null
        if [ -n "${display}" ]; then
            echo "${display} ${auth}"
        fi
    done | sort
}

if ! [ -f "${launcher}" ]; then
    echo "::error title=Error::No ${launcher}; the controller step installs it"
    exit 1
fi

before="$(xvnc_displays)"
echo "Starting the desktop session ${session_name} on ${session_resource}"
if ! pw sessions create --type desktop --name "${session_name}" --wait "${session_resource}"; then
    f_fail "pw sessions create could not start the desktop session ${session_name} on ${session_resource}"
fi

# The session reports running once its VNC server is up; allow a minute regardless
new=""
for _ in $(seq 1 30); do
    new="$(comm -13 <(echo "${before}") <(xvnc_displays) | sed '/^$/d')"
    [ -n "${new}" ] && break
    sleep 2
done
if [ -z "${new}" ]; then
    f_fail "The session ${session_name} started no VNC server on $(hostname); Isaac Sim needs the session on this node"
fi
if [ "$(echo "${new}" | wc -l)" -gt 1 ]; then
    f_fail "Two desktops started on $(hostname) at once (displays $(echo "${new}" | cut -d' ' -f1 | tr '\n' ' ')), so the session's display is unknown; run the workflow again"
fi
display="${new%% *}"
auth="${new#* }"
echo "The session's display is :${display}"

# Detached in its own session, so it outlives this step and the run
DISPLAY=":${display}" XAUTHORITY="${auth}" setsid bash "${launcher}" "${desktop_app}" "${desktop_stage:-}" > "${log}" 2>&1 < /dev/null &
pid=$!
echo "Isaac Sim started (pid ${pid}); its output goes to ${log}"

budget=$(( ${ready_minutes:-15} * 60 ))
start=${SECONDS}
until grep -q "app ready" "${log}" 2> /dev/null; do
    if ! kill -0 "${pid}" 2> /dev/null; then
        tail -n 20 "${log}"
        f_fail "Isaac Sim exited before its window opened; its output is in ${log}"
    fi
    if (( SECONDS - start > budget )); then
        tail -n 20 "${log}"
        kill -TERM "${pid}" 2> /dev/null || true
        f_fail "Isaac Sim was not ready after ${ready_minutes:-15} minutes; its output is in ${log}"
    fi
    sleep 5
done
touch isaac-sim.ready

url="https://${PW_PLATFORM_HOST}/sessions/${PW_USER}/${session_name}/vnc"
echo "::notice title=Desktop session::Isaac Sim is open in the desktop session ${session_name} after $(( SECONDS - start )) seconds: ${url} (also under Sessions). Stopping the session (pw sessions stop ${session_name}) ends Isaac Sim."
echo "SESSION_NAME=${session_name}" >> "${OUTPUTS:-/dev/null}"
echo "SESSION_URL=${url}" >> "${OUTPUTS:-/dev/null}"
