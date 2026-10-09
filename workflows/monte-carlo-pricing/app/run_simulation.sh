#!/bin/bash
# run_simulation.sh — Run Monte Carlo simulation batches and POST results to dashboard
#
# Environment variables:
#   DASHBOARD_URL   - Base URL of dashboard (e.g., http://host:port)
#   SITE_ID         - Identifier for this compute site (e.g., site-1)
#   BATCH_START     - First batch index (inclusive)
#   BATCH_END       - Last batch index (exclusive)
#   BATCH_SIZE      - Number of paths per batch
#   OPTION_TYPE     - Option type (asian_call, european_call, etc.)
#   SPOT_PRICE      - Underlying spot price
#   STRIKE_PRICE    - Strike price
#   VOLATILITY      - Volatility (sigma)
#   RISK_FREE_RATE  - Risk-free rate
#   TIME_TO_EXPIRY  - Time to expiry in years
#   BARRIER_LEVEL   - Barrier level (for barrier options)
#   MONITORING_POINTS - Number of monitoring points (time steps)
#   CLUSTER_NAME    - PW cluster name (auto-discovered if empty)
#   SCHEDULER_TYPE  - Scheduler type (e.g., ssh, slurm)
#   NUM_WORKERS     - Number of parallel workers (default: auto-detect)
#   PYTHON_CMD      - Interpreter for simulator.py (default: python3 from PATH)

set -e

# Discover cluster name and scheduler type if not provided
PW_CMD=""
for cmd in pw ~/pw/pw; do
    command -v $cmd &>/dev/null && { PW_CMD=$cmd; break; }
    [ -x "$cmd" ] && { PW_CMD=$cmd; break; }
done

if [ -z "${CLUSTER_NAME}" ] || [ -z "${SCHEDULER_TYPE}" ]; then
    if [ -n "${PW_CMD}" ]; then
        MY_HOST=$(hostname -s)
        while IFS= read -r line; do
            uri=$(echo "$line" | awk '{print $1}')
            ctype=$(echo "$line" | awk '{print $3}')
            name="${uri##*/}"
            if echo "${MY_HOST}" | grep -qi "${name}"; then
                [ -z "${CLUSTER_NAME}" ] && CLUSTER_NAME="${name}"
                if [ -z "${SCHEDULER_TYPE}" ]; then
                    case "${ctype}" in
                        *slurm*) SCHEDULER_TYPE="slurm" ;;
                        *pbs*)   SCHEDULER_TYPE="pbs" ;;
                        existing) SCHEDULER_TYPE="ssh" ;;
                        *)       SCHEDULER_TYPE="${ctype}" ;;
                    esac
                fi
                break
            fi
        done < <(${PW_CMD} cluster list 2>/dev/null | grep "^pw://${PW_USER}/" | grep "active")
    fi
    [ -z "${CLUSTER_NAME}" ] && CLUSTER_NAME="$(hostname -s)"
    [ -z "${SCHEDULER_TYPE}" ] && SCHEDULER_TYPE="ssh"
fi

# Multi-node SLURM: every task of the srun step runs this script, so each takes its
# share of the site's batch range by SLURM_PROCID (one range per task would post
# every batch once per node)
if [ -n "${SLURM_NTASKS}" ] && [ "${SLURM_NTASKS}" -gt 1 ] && [ -n "${SLURM_PROCID}" ]; then
    ORIGINAL_START=${BATCH_START}
    ORIGINAL_END=${BATCH_END}
    RANGE=$((ORIGINAL_END - ORIGINAL_START))
    BASE=$((RANGE / SLURM_NTASKS))
    EXTRA=$((RANGE % SLURM_NTASKS))
    if [ "${SLURM_PROCID}" -lt "${EXTRA}" ]; then
        BATCH_START=$((ORIGINAL_START + SLURM_PROCID * (BASE + 1)))
        BATCH_END=$((BATCH_START + BASE + 1))
    else
        BATCH_START=$((ORIGINAL_START + EXTRA * (BASE + 1) + (SLURM_PROCID - EXTRA) * BASE))
        BATCH_END=$((BATCH_START + BASE))
    fi
    echo "SLURM multi-node: task ${SLURM_PROCID}/${SLURM_NTASKS} on $(hostname -s), batches ${BATCH_START}-$((BATCH_END - 1)) (of ${ORIGINAL_START}-$((ORIGINAL_END - 1)))"
fi

if [ "${BATCH_END}" -le "${BATCH_START}" ]; then
    echo "No batches assigned to ${SITE_ID} on $(hostname -s); nothing to simulate"
    exit 0
fi

echo "=========================================="
echo "Monte Carlo Simulator Starting: $(date)"
echo "=========================================="
echo "Site:       ${SITE_ID}"
echo "Cluster:    ${CLUSTER_NAME}"
echo "Scheduler:  ${SCHEDULER_TYPE:-unknown}"
echo "Dashboard:  ${DASHBOARD_URL}"
echo "Batches:    ${BATCH_START} to ${BATCH_END}"
echo "Batch size: ${BATCH_SIZE}"
echo "Option:     ${OPTION_TYPE}"
echo "Spot:       ${SPOT_PRICE}"
echo "Strike:     ${STRIKE_PRICE}"
echo "Volatility: ${VOLATILITY}"
echo "Rate:       ${RISK_FREE_RATE}"
echo "Expiry:     ${TIME_TO_EXPIRY}"
echo "Barrier:    ${BARRIER_LEVEL}"
echo "Steps:      ${MONITORING_POINTS}"

# Find Python: the dispatcher passes one that imports numpy when the site has it
if [ -n "${PYTHON_CMD}" ] && ! command -v "${PYTHON_CMD}" &>/dev/null; then
    echo "[WARN] ${PYTHON_CMD} is not runnable on $(hostname -s); using python3 from PATH"
    PYTHON_CMD=""
fi
if [ -z "${PYTHON_CMD}" ]; then
    for cmd in python3 python; do
        command -v $cmd &>/dev/null && { PYTHON_CMD=$cmd; break; }
    done
fi
if [ -z "${PYTHON_CMD}" ]; then
    echo "[ERROR] Python not found"
    exit 1
fi
echo "Python:     ${PYTHON_CMD} ($(${PYTHON_CMD} -c 'import sys; print(sys.version.split()[0])'), numpy $(${PYTHON_CMD} -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo 'missing: pure Python fallback'))"

# simulator.py sits next to this script (the checked-out app/ directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMULATOR="${SCRIPT_DIR}/simulator.py"

if [ ! -f "${SIMULATOR}" ]; then
    echo "[ERROR] simulator.py not found at ${SIMULATOR}"
    exit 1
fi

# Working directory for temp files
WORK_DIR=$(mktemp -d)
trap "rm -rf ${WORK_DIR}" EXIT

# Determine number of workers
if [ -z "${NUM_WORKERS}" ]; then
    NUM_WORKERS=$(nproc 2>/dev/null || echo 4)
    TOTAL=$((BATCH_END - BATCH_START))
    [ "${NUM_WORKERS}" -gt "${TOTAL}" ] && NUM_WORKERS=${TOTAL}
    [ "${NUM_WORKERS}" -gt 16 ] && NUM_WORKERS=16
fi

echo "Workers:    ${NUM_WORKERS}"
echo "Work dir:   ${WORK_DIR}"
echo ""

TOTAL=$((BATCH_END - BATCH_START))

# Shared counters via files
echo "0" > "${WORK_DIR}/completed"
echo "0" > "${WORK_DIR}/errors"
LOCK_DIR="${WORK_DIR}/lock"

# Atomic increment helper
atomic_inc() {
    local file="$1"
    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do :; done
    local val=$(cat "$file")
    echo $((val + 1)) > "$file"
    echo $((val + 1))
    rmdir "${LOCK_DIR}"
}

# Worker function: simulate one batch and POST result
simulate_one() {
    local batch_id=$1

    # Run simulation
    local META
    META=$(${PYTHON_CMD} "${SIMULATOR}" \
        --batch-id "${batch_id}" \
        --batch-size "${BATCH_SIZE}" \
        --option-type "${OPTION_TYPE}" \
        --spot-price "${SPOT_PRICE}" \
        --strike-price "${STRIKE_PRICE}" \
        --volatility "${VOLATILITY}" \
        --risk-free-rate "${RISK_FREE_RATE}" \
        --time-to-expiry "${TIME_TO_EXPIRY}" \
        --barrier-level "${BARRIER_LEVEL}" \
        --monitoring-points "${MONITORING_POINTS}" \
        --site-id "${SITE_ID}" \
        --cluster-name "${CLUSTER_NAME}" \
        --scheduler-type "${SCHEDULER_TYPE}" \
        --num-workers "${NUM_WORKERS}" \
    )

    # POST JSON result to dashboard
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${DASHBOARD_URL}/api/batch" \
        -H "Content-Type: application/json" \
        -d "${META}" \
        --connect-timeout 10 \
        --max-time 30 \
    ) || HTTP_CODE="000"

    local count
    count=$(atomic_inc "${WORK_DIR}/completed")

    if [ "${HTTP_CODE}" = "200" ]; then
        local sim_ms
        sim_ms=$(echo "${META}" | ${PYTHON_CMD} -c 'import sys,json;print(json.load(sys.stdin)["simulation_time_ms"])' 2>/dev/null || echo '?')
        echo "[${count}/${TOTAL}] Batch ${batch_id} -> OK (${sim_ms}ms)"
    else
        atomic_inc "${WORK_DIR}/errors" > /dev/null
        echo "[${count}/${TOTAL}] Batch ${batch_id} -> FAILED (HTTP ${HTTP_CODE})"
    fi
}

export -f simulate_one atomic_inc
export PYTHON_CMD SIMULATOR BATCH_SIZE OPTION_TYPE SPOT_PRICE STRIKE_PRICE
export VOLATILITY RISK_FREE_RATE TIME_TO_EXPIRY BARRIER_LEVEL MONITORING_POINTS
export SITE_ID CLUSTER_NAME SCHEDULER_TYPE DASHBOARD_URL WORK_DIR TOTAL LOCK_DIR NUM_WORKERS

# Launch batches across workers using xargs for parallel execution
seq ${BATCH_START} $((BATCH_END - 1)) | xargs -P "${NUM_WORKERS}" -I{} bash -c 'simulate_one "$@"' _ {}

ERRORS=$(cat "${WORK_DIR}/errors")
COMPLETED=$(cat "${WORK_DIR}/completed")

echo ""
echo "=========================================="
echo "Simulation complete!"
echo "  Batches simulated: ${COMPLETED}"
echo "  Workers: ${NUM_WORKERS}"
echo "  Errors: ${ERRORS}"
echo "=========================================="

if [ "${ERRORS}" -gt 0 ]; then
    echo "[ERROR] ${ERRORS} of ${TOTAL} batches did not reach the dashboard"
    exit 1
fi
