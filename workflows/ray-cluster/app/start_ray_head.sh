#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
# start_ray_head.sh — Start Ray head node + custom dashboard, dispatch the workers
#
# The head is a pure coordinator (--num-cpus=0): no compute tasks run here.
# Workers are dispatched by dispatch_workers.sh, started from here once the
# dashboard is up. This script lives as long as the dashboard's pw endpoint.
#
# Creates coordination files:
#   - HOSTNAME      — Dashboard hostname
#   - SESSION_PORT  — Dashboard port
#   - RAY_HEAD_IP   — Ray head node IP
#   - job.started   — Signals job has started
#
# Environment variables:
#   RAY_VERSION  - Ray version to install (default: 2.40.0)

set -e

JOB_DIR="${PW_PARENT_JOB_DIR%/}"
cd "${JOB_DIR}"

SCRIPT_DIR="${JOB_DIR}/workflows/ray-cluster/app"
RAY_VERSION="${RAY_VERSION:-2.40.0}"
RAY_PORT=6379

echo "=========================================="
echo "Ray Head + Dashboard Starting: $(date)"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "Job dir:  ${PW_PARENT_JOB_DIR}"

# Verify bash is available and warn on csh/tcsh login shells
if [ -x "${SCRIPT_DIR}/check_shell.sh" ]; then
    "${SCRIPT_DIR}/check_shell.sh" || exit 1
fi

# Verify scripts were checked out
if [ ! -f "${SCRIPT_DIR}/dashboard.py" ]; then
    echo "[ERROR] dashboard.py not found at ${SCRIPT_DIR}/dashboard.py"
    ls -la "${JOB_DIR}" 2>&1
    exit 1
fi

# =============================================================================
# Install Ray + dependencies
# =============================================================================
bash "${SCRIPT_DIR}/setup.sh"

# Determine Python from venv (setup.sh writes the path to RAY_VENV_DIR)
VENV_DIR="$(cat "${JOB_DIR}/RAY_VENV_DIR" 2>/dev/null || echo "${JOB_DIR}/.venv")"
if [ -f "${VENV_DIR}/bin/python" ]; then
    PYTHON_CMD="${VENV_DIR}/bin/python"
    source "${VENV_DIR}/bin/activate"
    # Keep uv cache alongside the venv (avoids filling small HOME quotas)
    export UV_CACHE_DIR="$(dirname "${VENV_DIR}")/.uv-cache"
else
    PYTHON_CMD="python3"
fi
echo "Python: ${PYTHON_CMD}"

# Install dashboard dependencies
${PYTHON_CMD} -c "import fastapi" 2>/dev/null || {
    echo "Installing dashboard dependencies..."
    UV_CMD=""
    # Check venv bin first (symlinked by setup.sh), then common install locations
    for uv_path in "${VENV_DIR}/bin/uv" "${WORKDIR:-/nonexistent}/pw/software/.uv/uv" "$HOME/pw/software/.uv/uv" "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
        if [ -x "${uv_path}" ]; then UV_CMD="${uv_path}"; break; fi
    done
    if [ -z "${UV_CMD}" ]; then command -v uv &>/dev/null && UV_CMD="uv"; fi

    if [ -n "${UV_CMD}" ]; then
        ${UV_CMD} pip install --python "${PYTHON_CMD}" fastapi uvicorn websockets httpx 2>&1 || {
            echo "[ERROR] Failed to install dashboard dependencies via uv"
            exit 1
        }
    else
        ${PYTHON_CMD} -m pip install --quiet fastapi uvicorn websockets httpx 2>&1 || {
            echo "[ERROR] Failed to install dashboard dependencies"
            exit 1
        }
    fi
}

# =============================================================================
# Start Ray head node (coordinator only — no compute tasks)
# =============================================================================
echo "Stopping any existing Ray processes..."
ray stop --force 2>/dev/null || true

# Aggressive cleanup: `ray stop` only kills processes whose session metadata
# it can find. Orphaned gcs_server/raylet/dashboard processes from a
# cancelled prior run can survive and either bind RAY_PORT or, more
# subtly, race the new head down within seconds of `ray start`. Nuke them.
for proc in gcs_server raylet 'ray/_private/log_monitor' 'ray.dashboard'; do
    pkill -9 -f "${proc}" 2>/dev/null || true
done
# Prune session dirs older than 1h so /tmp/ray/session_latest doesn't
# drift and stale plasma files don't confuse the new raylet.
find /tmp/ray -maxdepth 1 -name "session_*" -type d -mmin +60 \
    -exec rm -rf {} \; 2>/dev/null || true

# Give the kernel a beat to release ports before we re-bind.
sleep 1

# Get real network IP (not loopback)
HEAD_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "${HEAD_IP}" ] || [[ "${HEAD_IP}" == 127.* ]]; then
    HEAD_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n 1)
fi
echo "Ray head IP: ${HEAD_IP}"

# Pin BLAS/OpenMP to 1 thread per process so Ray tasks don't oversubscribe cores.
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

# Tolerate brief network interruptions (e.g., SSH tunnel drops) without marking
# workers as DEAD. Default is ~10s; we raise to ~90s to survive 30-60s blips.
export RAY_HEALTH_CHECK_PERIOD_MS=5000
export RAY_HEALTH_CHECK_FAILURE_THRESHOLD=18
export RAY_NUM_HEARTBEATS_TIMEOUT=90

echo "Starting Ray head node (coordinator only, --num-cpus=0)..."
ray start --head \
    --port=${RAY_PORT} \
    --node-ip-address=${HEAD_IP} \
    --num-cpus=0 \
    --dashboard-host=0.0.0.0 \
    --dashboard-port=8265

# Verify Ray GCS is listening
echo "Checking Ray GCS port binding..."
ss -tlnp 2>/dev/null | grep ":${RAY_PORT}" || netstat -tlnp 2>/dev/null | grep ":${RAY_PORT}" || echo "  (port check tools unavailable)"

echo "Ray head started on ${HEAD_IP}:${RAY_PORT}"
ray status

# Record exact Python version for worker matching
PYTHON_MICRO=$($PYTHON_CMD -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
echo "${PYTHON_MICRO}" > PYTHON_VERSION
echo "Python version (for workers to match): ${PYTHON_MICRO}"

# =============================================================================
# Port allocation for custom dashboard
# =============================================================================
PW_CMD=""
for cmd in pw ~/pw/pw; do
    command -v $cmd &>/dev/null && { PW_CMD=$cmd; break; }
    [ -x "$cmd" ] && { PW_CMD=$cmd; break; }
done
if [ -z "${PW_CMD}" ]; then
    echo "[ERROR] pw CLI not found"
    exit 1
fi
service_port=$(${PW_CMD} agent open-port 2>/dev/null)

if [ -z "${service_port}" ] || ! [[ "${service_port}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Failed to allocate port (got: '${service_port}')"
    exit 1
fi
echo "Dashboard port: ${service_port}"

# =============================================================================
# Write coordination files
# =============================================================================
hostname > HOSTNAME
echo "${service_port}" > SESSION_PORT
echo "${HEAD_IP}" > RAY_HEAD_IP
touch job.started

echo "Coordination files written:"
echo "  HOSTNAME=$(cat HOSTNAME)"
echo "  SESSION_PORT=$(cat SESSION_PORT)"
echo "  RAY_HEAD_IP=$(cat RAY_HEAD_IP)"

# =============================================================================
# Start custom dashboard behind a pw endpoint
# =============================================================================
mkdir -p logs

export DASHBOARD_PORT="${service_port}"
export RAY_HEAD_IP="${HEAD_IP}"
export PYTHON_VERSION="${PYTHON_MICRO}"

# The endpoint pins the local port to the one allocated above: workers reach the
# dashboard on it through their tunnels and SESSION_PORT is already written. The
# wrapper's process tree is the cluster's lifetime: pw endpoints delete kills it,
# this script then returns and its caller's trap tears the workers down.
ENDPOINT_NAME="${RAY_ENDPOINT_NAME:-ray-cluster-${PW_RUN_SLUG}}"
echo "${ENDPOINT_NAME}" > ENDPOINT_NAME
echo "Endpoint: ${ENDPOINT_NAME}"

${PW_CMD} endpoints run --name "${ENDPOINT_NAME}" --port "${service_port}" \
    -- ${PYTHON_CMD} -m uvicorn dashboard:app \
    --host 0.0.0.0 \
    --port "${service_port}" \
    --app-dir "${SCRIPT_DIR}" \
    > logs/dashboard.log 2>&1 &
SERVER_PID=$!
echo "Dashboard PID: ${SERVER_PID}"
echo "${SERVER_PID}" > dashboard.pid

# The endpoint registers itself before it starts the dashboard; wait for the port to answer
for _i in $(seq 1 30); do
    curl -s -o /dev/null --connect-timeout 2 "http://localhost:${service_port}/" && break
    kill -0 ${SERVER_PID} 2>/dev/null || break
    sleep 2
done

if ! kill -0 ${SERVER_PID} 2>/dev/null; then
    echo "[ERROR] Dashboard failed to start"
    cat logs/dashboard.log >&2
    exit 1
fi

echo "=========================================="
echo "Ray Head + Dashboard RUNNING"
echo "  Ray: ${HEAD_IP}:${RAY_PORT}"
echo "  Dashboard: port ${service_port}"
echo "=========================================="

# Auto-detect cluster name and register head node with dashboard
CLUSTER_NAME=""
SCHEDULER_TYPE=""
PW_CMD=""
for cmd in pw ~/pw/pw; do
    command -v $cmd &>/dev/null && { PW_CMD=$cmd; break; }
    [ -x "$cmd" ] && { PW_CMD=$cmd; break; }
done
if [ -n "${PW_CMD}" ]; then
    MY_HOST=$(hostname -s)
    while IFS= read -r line; do
        uri=$(echo "$line" | awk '{print $1}')
        ctype=$(echo "$line" | awk '{print $3}')
        name="${uri##*/}"
        if echo "${MY_HOST}" | grep -qi "${name}"; then
            CLUSTER_NAME="${name}"
            case "${ctype}" in
                *slurm*) SCHEDULER_TYPE="slurm" ;;
                *pbs*)   SCHEDULER_TYPE="pbs" ;;
                existing) SCHEDULER_TYPE="ssh" ;;
                *)       SCHEDULER_TYPE="${ctype}" ;;
            esac
            break
        fi
    done < <(${PW_CMD} cluster list 2>/dev/null | grep "^pw://${PW_USER}/" | grep "active")
fi
[ -z "${CLUSTER_NAME}" ] && CLUSTER_NAME="$(hostname -s)"
[ -z "${SCHEDULER_TYPE}" ] && SCHEDULER_TYPE="ssh"

echo "Registering head node: ${CLUSTER_NAME} (${SCHEDULER_TYPE})"
curl -s -X POST "http://localhost:${service_port}/api/head" \
    -H "Content-Type: application/json" \
    -d "{\"ip\": \"${HEAD_IP}\", \"cluster_name\": \"${CLUSTER_NAME}\", \"scheduler_type\": \"${SCHEDULER_TYPE}\"}" \
    2>/dev/null || echo "Warning: Could not register head node with dashboard"


# cluster_only mode: tell the dashboard before any worker registers (the config
# post resets the topology)
if [ "${WORKLOAD_TYPE:-}" = "cluster_only" ]; then
    curl -s -X POST "http://localhost:${service_port}/api/config" \
        -H "Content-Type: application/json" \
        -d "{\"workload_type\": \"cluster_only\", \"ray_head_ip\": \"${HEAD_IP}\"}" >/dev/null 2>&1 || true
fi

# Dispatch the workers. The dispatcher lives as long as remote SSH tunnels do; its
# exit status is recorded for the jobs that wait for the workers.
rm -f DISPATCH_FAILED
(
    bash "${SCRIPT_DIR}/dispatch_workers.sh" 2>&1 | tee logs/dispatch.out
    rc=${PIPESTATUS[0]}
    [ ${rc} -ne 0 ] && touch DISPATCH_FAILED
    echo "dispatch_workers.sh exited with status ${rc}"
) &
echo $! > dispatch.pid

# Watch Ray itself while the endpoint wrapper lives. The dashboard staying up
# tells us nothing about GCS/raylet — those can die independently (seen on
# rerun: gcs_server exits ~10s after start without errors in its logs). Detect
# persistent `ray status` failures and drop the dashboard: workers see
# /api/worker fail immediately instead of timing out, the endpoint disappears
# and the teardown runs.
RAY_FAILS=0
RAY_FAIL_THRESHOLD=3
while kill -0 ${SERVER_PID} 2>/dev/null; do
    if ray status >/dev/null 2>&1; then
        RAY_FAILS=0
    else
        RAY_FAILS=$((RAY_FAILS + 1))
        echo "Ray health check FAILED (${RAY_FAILS}/${RAY_FAIL_THRESHOLD}): $(date)"
        if [ ${RAY_FAILS} -ge ${RAY_FAIL_THRESHOLD} ]; then
            echo "[FATAL] Ray head ($(cat /tmp/ray/session_latest/node_ip_address 2>/dev/null || echo "${HEAD_IP}"):${RAY_PORT}) is unreachable after ${RAY_FAILS} checks." >&2
            echo "[FATAL] GCS or raylet died; worker tunnels will fail. Ending the cluster." >&2
            kill ${SERVER_PID} 2>/dev/null || true
            exit 1
        fi
    fi
    sleep 10
done

# The wrapper is gone: pw endpoints delete killed it, or it died. Either way the
# cluster ends here.
if ${PW_CMD} endpoints list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qxF "${ENDPOINT_NAME}"; then
    echo "Dashboard wrapper exited while endpoint ${ENDPOINT_NAME} is still listed"
    exit 0
fi
echo "Endpoint ${ENDPOINT_NAME} is gone: the cluster ends"
exit 1
