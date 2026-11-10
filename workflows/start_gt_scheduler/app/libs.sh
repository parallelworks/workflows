# Sourced by the scripts that run in the user workspace, from the run's directory.

app_dir="${PW_PARENT_JOB_DIR%/}/workflows/start_gt_scheduler/app"

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

start_reverse_tunnel() {
    setsid ssh ${SSH_OPTIONS} -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=5 \
        -N -T -R "localhost:${usercontainer_port}:localhost:22" "${controller}" > reverse-tunnel.out 2>&1 < /dev/null &
    echo $! > reverse-tunnel.pid
}

# Only a tunnel this run opened has a pid file: one that was already there and
# working is used as it is and left alone at the end
stop_reverse_tunnel() {
    if [ -f reverse-tunnel.pid ]; then
        kill "$(cat reverse-tunnel.pid)" 2> /dev/null
        rm -f reverse-tunnel.pid
    fi
}

# Opens the tunnel only when none is there. One whose process is alive is never
# replaced: the license tunnel runs through it, and would be cut for a hop that may
# be failing for another reason.
ensure_usercontainer() {
    local state attempt
    state=$(usercontainer_state)
    [ "${state}" == "up" ] && return 0
    [ "${state}" == "down" ] || return 1
    if [ -f reverse-tunnel.pid ] && kill -0 "$(cat reverse-tunnel.pid)" 2> /dev/null; then
        return 1
    fi
    start_reverse_tunnel
    for attempt in 1 2 3 4 5 6; do
        sleep 5
        [ "$(usercontainer_state)" == "up" ] && return 0
    done
    return 1
}
