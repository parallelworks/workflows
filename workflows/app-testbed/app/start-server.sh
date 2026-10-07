#!/usr/bin/env bash
################################################################################
# App Testbed server: the placeholder server behind a fixed pw endpoint
#
# Purpose: Serve server.py on 127.0.0.1:${server_port} through `pw endpoints run`
#          at a stable address: the endpoint is named after its subdomain
#          (apptest by default), the same every run. The wrapper is detached from
#          the run, so the server outlives it and the next run attaches to it;
#          deleting the endpoint (Sessions page, pw endpoints delete) ends the
#          wrapper's process tree and with it the server, and the workers exit on
#          their own within ~30 s when their websocket drops.
# Runs on: The server host's login node (the worker sites' tunnels end here)
# Called by: The start_server job, after inputs.sh is sourced
#
# Required Environment Variables (from inputs.sh):
#   - deploy_server: false leaves whatever runs untouched (workers-only run)
#   - restart_server: true replaces a running server
#   - server_workdir, server_port, server_subdomain
#   - PW_PARENT_JOB_DIR: the run directory (holds the checked-out app/)
################################################################################
set -o pipefail
command -v pw >/dev/null 2>&1 || export PATH="${PATH}:${HOME}/pw"

APP_DIR="${PW_PARENT_JOB_DIR%/}/workflows/app-testbed/app"
WORKDIR=$(eval echo "${server_workdir:-~/app-testbed}")
PORT="${server_port:-8090}"
NAME="${server_subdomain:-apptest}"
ME=$(id -un)
mkdir -p "${WORKDIR}"

if [ "$(echo "${deploy_server:-true}" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    echo "server deployment disabled; skipping"
    exit 0
fi

# the server's command line ends in "server.py <port>": one server per port and user
server_pid() { pgrep -u "${ME}" -f "server\.py ${PORT}$" | head -1; }
wrapper_pid() { pgrep -u "${ME}" -f "pw endpoints run .*--name ${NAME} " | head -1; }
endpoint_status() { pw endpoints list 2>/dev/null | awk -F'\t' -v n="${NAME}" '$1 == n {print $2}' | head -1; }
endpoint_url() { pw endpoints list 2>/dev/null | awk -F'\t' -v n="${NAME}" '$1 == n {print $3}' | head -1; }

stop_server() {
    # deleting the endpoint takes the wrapper's whole process tree down with it; the
    # kills below are for anything outside a wrapper: a server started by hand, or by
    # the previous generation of this workflow (a bare server.py next to a separate
    # pw endpoints http process and a session-watch loop)
    if [ -n "$(endpoint_status)" ]; then
        echo "deleting endpoint ${NAME} ($(endpoint_status))"
        pw endpoints delete "${NAME}" || true
    fi
    pkill -u "${ME}" -f "pw endpoints run .*--name ${NAME} " 2>/dev/null || true
    pkill -u "${ME}" -f "pw endpoints http .*--name ${NAME}( |$)" 2>/dev/null || true
    pkill -u "${ME}" -f "session[-]watch-${NAME}" 2>/dev/null || true
    pkill -u "${ME}" -f "server\.py ${PORT}$" 2>/dev/null || true
    for _ in $(seq 1 30); do
        [ -z "$(endpoint_status)" ] && [ -z "$(server_pid)" ] && return 0
        sleep 2
    done
    echo "::error title=Error::Endpoint ${NAME} is still listed, or server.py still runs on :${PORT}, after stopping it; delete it with 'pw endpoints delete ${NAME}' and launch again"
    exit 1
}

RESTART=$(echo "${restart_server:-false}" | tr '[:upper:]' '[:lower:]')
pid=$(server_pid)
status=$(endpoint_status)
if [ "${RESTART}" = "true" ] && { [ -n "${pid}" ] || [ -n "${status}" ]; }; then
    echo "restart requested; stopping the server"
    stop_server
elif [ -n "${pid}" ] && [ "${status}" = "running" ]; then
    echo "server already running (pid ${pid}) behind endpoint ${NAME}: $(endpoint_url)"
elif [ -n "${pid}" ] || [ -n "${status}" ]; then
    # one half without the other: a server whose endpoint is gone, or a listing left
    # by a wrapper that is gone (a record can stay listed as stopped). Start over.
    echo "server pid '${pid}', endpoint status '${status:-not listed}': replacing the partial instance"
    stop_server
fi

if [ -z "$(server_pid)" ]; then
    cp "${APP_DIR}/server.py" "${WORKDIR}/server.py"
    rm -f "${WORKDIR}/endpoint.log"
    echo "starting: pw endpoints run --port ${PORT} --subdomain ${NAME} --name ${NAME} -- python3 ${WORKDIR}/server.py {port}"
    # own session, no stdin, output to a file: the wrapper survives this step and the
    # run. The server's own output goes to server.log, the wrapper's to endpoint.log.
    setsid -f pw endpoints run --port "${PORT}" --subdomain "${NAME}" --name "${NAME}" -o text \
        -- sh -c "exec python3 '${WORKDIR}/server.py' {port} >> '${WORKDIR}/server.log' 2>&1" \
        > "${WORKDIR}/endpoint.log" 2>&1 < /dev/null
fi

up=""
for i in $(seq 1 60); do
    curl -sf -m 3 -o /dev/null "http://127.0.0.1:${PORT}/health" && up=1 && break
    # a wrapper that is already gone took the server with it (a port in use, a
    # subdomain another user holds): no point in waiting out the window
    [ "${i}" -gt 3 ] && [ -z "$(wrapper_pid)" ] && [ -z "$(server_pid)" ] && break
    sleep 1
done
if [ -z "${up}" ]; then
    echo "::error title=Error::server not reachable on 127.0.0.1:${PORT} (is the port free? pid '$(server_pid)', wrapper '$(wrapper_pid)')"
    echo "--- ${WORKDIR}/endpoint.log ---"; tail -20 "${WORKDIR}/endpoint.log" 2>/dev/null
    echo "--- ${WORKDIR}/server.log ---"; tail -20 "${WORKDIR}/server.log" 2>/dev/null
    exit 1
fi
# confirm the websocket path answers an upgrade locally
WS=$(curl -si -m 5 --http1.1 -H "Upgrade: websocket" -H "Connection: Upgrade" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "http://127.0.0.1:${PORT}/ws" 2>/dev/null | head -1)
echo "server health OK; local websocket probe: ${WS:-no response}"
