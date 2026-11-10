# Sourced by the scripts that run in the user workspace, from the run's directory.

run_dir="${PWD}"
app_dir="${run_dir}/workflows/start_gt_scheduler/app"

# ControlPath=none: the workspace's ssh_config shares connections, and a forward
# requested through a shared master would outlive the process this run tracks
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ControlMaster=no -o ControlPath=none"
USERCONTAINER_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

controller_ssh() {
    ssh ${SSH_OPTIONS} -o ConnectTimeout=10 "${controller}" "$@"
}

# up: the controller reaches this workspace through its usercontainer host entry
# down: the controller answers but that hop does not
# unreachable: the controller itself does not answer, which says nothing about the hop
usercontainer_state() {
    local answer
    answer=$(controller_ssh "ssh ${USERCONTAINER_OPTIONS} -o BatchMode=yes -o ConnectTimeout=10 usercontainer hostname 2> /dev/null || echo usercontainer-down" 2> /dev/null)
    if [ "${answer}" == "$(hostname)" ]; then
        echo up
    elif [ -n "${answer}" ]; then
        echo down
    else
        echo unreachable
    fi
}

# The tunnel this run opens is found by the log file on its command line, which only
# this run's has: a pid file would miss one cancelled between its start and the write.
# A tunnel that was already there and working is used as it is and left alone.
reverse_tunnel_log="${run_dir}/reverse-tunnel.out"

reverse_tunnel_running() {
    pgrep -u "$(id -u)" -f -- "-E ${reverse_tunnel_log}" > /dev/null
}

start_reverse_tunnel() {
    setsid ssh ${SSH_OPTIONS} -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=5 \
        -N -T -E "${reverse_tunnel_log}" -R "localhost:${usercontainer_port}:localhost:22" "${controller}" \
        > /dev/null 2>&1 < /dev/null &
}

stop_reverse_tunnel() {
    pkill -u "$(id -u)" -f -- "-E ${reverse_tunnel_log}"
    return 0
}

# Opens the tunnel only when none is there. One whose process is alive is never
# replaced: the license tunnel runs through it, and would be cut for a hop that may
# be failing for another reason.
ensure_usercontainer() {
    local state attempt
    state=$(usercontainer_state)
    [ "${state}" == "up" ] && return 0
    [ "${state}" == "down" ] || return 1
    if reverse_tunnel_running; then
        return 1
    fi
    start_reverse_tunnel
    for attempt in 1 2 3 4 5 6; do
        sleep 5
        [ "$(usercontainer_state)" == "up" ] && return 0
    done
    return 1
}
