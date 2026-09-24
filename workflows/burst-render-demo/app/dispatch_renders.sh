#!/bin/bash
# dispatch_renders.sh — Dispatch tile rendering across N compute sites
#
# Runs on the dashboard host. For each target site:
#   - a site on the dashboard host's own resource renders here: render_tiles.sh runs on
#     this node, or on compute nodes through srun, which reach the dashboard on this
#     node's hostname. No tunnel and no platform SSH key are needed, which is what
#     makes a cloud login node (no ~/.ssh/pwcli) a valid dashboard host for itself.
#   - any other site is reached over SSH with a reverse tunnel back to the dashboard;
#     the site clones this repository (sparse, the app/ directory) and runs
#     render_tiles.sh, through srun plus a TCP proxy that exposes the tunnel to the
#     compute nodes when the site schedules.
#
# REMOTE-SHELL COMPATIBILITY (bash, tcsh, sh)
# ===========================================
# Compute sites may use any login shell — DoD HPC sites (ERDC, ARL) commonly
# default to tcsh. To stay portable, every command this script sends for the
# remote login shell to interpret must obey these rules:
#
#   1. Only POSIX-common syntax in the remote command string.
#      Safe: `echo`, `hostname`, `&&`, `||`, `;`, `$VAR` expansion, single quotes.
#      Unsafe: bash arrays, `[[...]]`, process substitution, `\"` inside `"..."`
#              (tcsh does NOT honor backslash-escape inside double quotes).
#
#   2. To run a script body on the remote, pipe it via stdin to `bash -s`:
#          ssh ... 'bash -s' < script_file
#      The remote login shell only sees the word `bash`; the script body
#      runs inside bash and may use any bash feature freely.
#
#   3. To run a remote python program, pipe the source via stdin to `python3`:
#          ssh ... python3 <<'PYEOF' ... PYEOF
#      Use direct `ssh` (not `pw ssh`) — `pw ssh` does not forward stdin
#      to the remote command.
#
# Environment variables:
#   TARGETS_JSON       - JSON array of target objects from workflow inputs
#   HEAD_RESOURCE_NAME - Resource name of the dashboard host (its sites render locally)
#   DASHBOARD_PORT     - Dashboard port on this host
#   TOTAL_TILES        - Total number of tiles to render
#   GRID_SIZE          - Grid dimension
#   IMAGE_SIZE         - Tile resolution
#   PALETTE            - Color palette
#   PARALLELISM        - Worker count ("auto" or number)
#   REPO_URL           - Repository remote sites clone for the render scripts
<<<<<<< HEAD
#                        (default: the origin of the checkout in the job directory)
#   REPO_BRANCH        - Branch of that repository
#                        (default: the branch that checkout is on, else canary)
=======
#   REPO_BRANCH        - Branch of that repository
>>>>>>> origin/canary
#   PW_RUN_SLUG        - Names the per-run work directory on remote sites

set -eo pipefail

JOB_DIR="${PW_PARENT_JOB_DIR%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_REL="workflows/burst-render-demo/app"
<<<<<<< HEAD
# Remote sites clone the same repository and branch the dashboard host checked out, so a
# run started from a development branch dispatches that branch's scripts and there is no
# second place to keep in sync. parallelworks/checkout leaves its clone in the job dir;
# the defaults apply when it cannot be read (no git, detached HEAD, a copied job dir).
if [ -z "${REPO_URL}" ]; then
    REPO_URL=$(git -C "${JOB_DIR}" config --get remote.origin.url 2>/dev/null || true)
fi
if [ -z "${REPO_BRANCH}" ]; then
    REPO_BRANCH=$(git -C "${JOB_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi
case "${REPO_URL}" in '') REPO_URL="https://github.com/parallelworks/workflows.git" ;; esac
case "${REPO_BRANCH}" in ''|HEAD) REPO_BRANCH="canary" ;; esac
=======
REPO_URL="${REPO_URL:-https://github.com/parallelworks/workflows.git}"
REPO_BRANCH="${REPO_BRANCH:-canary}"
>>>>>>> origin/canary
WORK_DIR=$(mktemp -d)
trap "rm -rf ${WORK_DIR}" EXIT

# Find Python and pw
PYTHON_CMD=""
for cmd in python3 python; do
    command -v $cmd &>/dev/null && { PYTHON_CMD=$cmd; break; }
done
if [ -z "${PYTHON_CMD}" ]; then
    echo "[ERROR] Python not found"
    exit 1
fi

PW_CMD=""
for cmd in pw ~/pw/pw; do
    command -v $cmd &>/dev/null && { PW_CMD=$cmd; break; }
    [ -x "$cmd" ] && { PW_CMD=$cmd; break; }
done
if [ -z "${PW_CMD}" ]; then
    echo "[ERROR] pw CLI not found"
    exit 1
fi

<<<<<<< HEAD
# Parse targets JSON to get site list with scheduler config.
# Every python -c below is single-quoted and reads its JSON from the environment or
# stdin: a JSON document pasted into a python string literal is un-escaped by python
# first, so a form value containing a newline (the hsp directives default) or a quote
# reaches json.loads as an invalid control character.
SITES_JSON=$(${PYTHON_CMD} -c '
import json, os

targets = json.loads(os.environ["TARGETS_JSON"])
head_name = os.environ.get("HEAD_RESOURCE_NAME", "")
sites = []
for i, t in enumerate(targets):
    res = t.get("resource", {})
    # Handle resource as string (CLI) or object (UI)
    if isinstance(res, str):
        res = {"name": res.rsplit("/", 1)[-1]}
    # Scheduler config
    use_scheduler = t.get("scheduler", False)
    if isinstance(use_scheduler, str):
        use_scheduler = use_scheduler.lower() == "true"
    scheduler_type = res.get("schedulerType", "")
    # Default to slurm when scheduler requested but type unknown
    if use_scheduler and not scheduler_type:
        scheduler_type = "slurm"
    slurm = t.get("slurm", {}) or {}
    name = res.get("name", "site-%d" % i)
    sites.append({
        "index": i,
        "name": name,
        "ip": res.get("ip", ""),
        "user": res.get("user", ""),
        "scheduler_type": scheduler_type,
        "use_scheduler": use_scheduler,
        "is_local": bool(head_name) and name == head_name,
        "slurm_partition": slurm.get("partition", ""),
        "slurm_account": slurm.get("account", ""),
        "slurm_qos": slurm.get("qos", ""),
        "slurm_time": slurm.get("time", "00:05:00"),
        "slurm_nodes": slurm.get("nodes", "1"),
        "slurm_directives": slurm.get("scheduler_directives", ""),
    })
print(json.dumps(sites))
')
export SITES_JSON

NUM_SITES=$(${PYTHON_CMD} -c 'import json, os; print(len(json.loads(os.environ["SITES_JSON"])))')
=======
# Parse targets JSON to get site list with scheduler config
SITES_JSON=$(${PYTHON_CMD} -c "
import json, sys, os

targets = json.loads(os.environ['TARGETS_JSON'])
head_name = os.environ.get('HEAD_RESOURCE_NAME', '')
sites = []
for i, t in enumerate(targets):
    res = t.get('resource', {})
    # Handle resource as string (CLI) or object (UI)
    if isinstance(res, str):
        res = {'name': res.rsplit('/', 1)[-1]}
    # Scheduler config
    use_scheduler = t.get('scheduler', False)
    if isinstance(use_scheduler, str):
        use_scheduler = use_scheduler.lower() == 'true'
    scheduler_type = res.get('schedulerType', '')
    # Default to slurm when scheduler requested but type unknown
    if use_scheduler and not scheduler_type:
        scheduler_type = 'slurm'
    slurm = t.get('slurm', {}) or {}
    name = res.get('name', f'site-{i}')
    sites.append({
        'index': i,
        'name': name,
        'ip': res.get('ip', ''),
        'user': res.get('user', ''),
        'scheduler_type': scheduler_type,
        'use_scheduler': use_scheduler,
        'is_local': bool(head_name) and name == head_name,
        'slurm_partition': slurm.get('partition', ''),
        'slurm_account': slurm.get('account', ''),
        'slurm_qos': slurm.get('qos', ''),
        'slurm_time': slurm.get('time', '00:05:00'),
        'slurm_nodes': slurm.get('nodes', '1'),
        'slurm_directives': slurm.get('scheduler_directives', ''),
    })
print(json.dumps(sites))
")

NUM_SITES=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(len(json.load(sys.stdin)))")
>>>>>>> origin/canary

echo "=========================================="
echo "Dispatch Renders: $(date)"
echo "=========================================="
echo "Sites:          ${NUM_SITES}"
echo "Total tiles:    ${TOTAL_TILES}"
echo "Grid:           ${GRID_SIZE}x${GRID_SIZE}"
echo "Image size:     ${IMAGE_SIZE}px"
echo "Dashboard:      localhost:${DASHBOARD_PORT} on $(hostname)"
echo "Dashboard host: ${HEAD_RESOURCE_NAME:-unknown}"
echo "Render scripts: ${REPO_URL}@${REPO_BRANCH} (${APP_REL})"

# Calculate tile ranges for each site
<<<<<<< HEAD
TILE_RANGES=$(${PYTHON_CMD} -c '
import json, os

sites = json.loads(os.environ["SITES_JSON"])
total = int(os.environ["TOTAL_TILES"])
=======
TILE_RANGES=$(${PYTHON_CMD} -c "
import json, sys, os, math

sites = json.loads('''${SITES_JSON}''')
total = int(os.environ['TOTAL_TILES'])
>>>>>>> origin/canary
n = len(sites)

# Distribute tiles as evenly as possible
base = total // n
extra = total % n
start = 0
ranges = []
for i in range(n):
    count = base + (1 if i < extra else 0)
<<<<<<< HEAD
    ranges.append({"index": i, "name": sites[i]["name"], "start": start, "end": start + count})
    start += count
print(json.dumps(ranges))
')
export TILE_RANGES

echo ""
echo "Tile assignments:"
${PYTHON_CMD} -c '
import json, os
ranges = json.loads(os.environ["TILE_RANGES"])
sites = json.loads(os.environ["SITES_JSON"])
for r in ranges:
    s = sites[r["index"]]
    mode = s.get("scheduler_type", "ssh") if s.get("use_scheduler") else "ssh"
    where = "this host" if s.get("is_local") else "remote"
    print("  Site {} ({}): tiles {}-{} ({} tiles) [{}, {}]".format(
        r["index"], r["name"], r["start"], r["end"] - 1, r["end"] - r["start"], mode, where))
'
=======
    ranges.append({'index': i, 'name': sites[i]['name'], 'start': start, 'end': start + count})
    start += count
print(json.dumps(ranges))
")

echo ""
echo "Tile assignments:"
echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "
import sys, json, os
ranges = json.load(sys.stdin)
sites = json.loads('''${SITES_JSON}''')
for r in ranges:
    s = sites[r['index']]
    mode = s.get('scheduler_type', 'ssh') if s.get('use_scheduler') else 'ssh'
    where = 'this host' if s.get('is_local') else 'remote'
    print(f\"  Site {r['index']} ({r['name']}): tiles {r['start']}-{r['end']-1} ({r['end']-r['start']} tiles) [{mode}, {where}]\")
"
>>>>>>> origin/canary

# srun options for a SLURM site. Additional directives arrive as #SBATCH lines; srun
# takes the same long options, so they are appended as options (trailing comments and
# commented-out ##SBATCH lines are dropped)
build_srun_cmd() {
    local partition=$1 account=$2 qos=$3 time=$4 nodes=$5 directives=$6
    local cmd="srun"
    [ -n "${partition}" ] && cmd="${cmd} --partition=${partition}"
    [ -n "${account}" ] && cmd="${cmd} --account=${account}"
    [ -n "${qos}" ] && cmd="${cmd} --qos=${qos}"
    [ -n "${time}" ] && cmd="${cmd} --time=${time}"
    cmd="${cmd} --nodes=${nodes:-1} --ntasks=${nodes:-1}"
    local extra
    extra=$(printf '%s\n' "${directives}" | sed -n 's/^[[:space:]]*#SBATCH[[:space:]]\{1,\}//p' | sed 's/[[:space:]]#.*$//' | tr '\n' ' ')
    [ -n "${extra// /}" ] && cmd="${cmd} ${extra}"
    echo "${cmd}"
}

# Render function for a site on the dashboard host's own resource: no tunnel, no clone
render_site_local() {
    local site_index=$1
    local site_name=$2
    local tile_start=$3
    local tile_end=$4
    local dispatch_mode=$5
    local srun_cmd=$6

    local site_id="site-$((site_index + 1))"
    local num_tiles=$((tile_end - tile_start))

    echo ""
    echo "[${site_id}] Starting render on ${site_name} (this host): ${num_tiles} tiles [${dispatch_mode}]"

    export SITE_ID="${site_id}"
    export CLUSTER_NAME="${site_name}"
    export TILE_START=${tile_start}
    export TILE_END=${tile_end}
    export GRID_SIZE IMAGE_SIZE PALETTE
    [ "${PARALLELISM}" != "auto" ] && export NUM_WORKERS="${PARALLELISM}"

    if [ "${dispatch_mode}" = "slurm" ]; then
        # Compute nodes reach the login node directly; the dashboard binds 0.0.0.0
        export DASHBOARD_URL="http://$(hostname):${DASHBOARD_PORT}"
        export SCHEDULER_TYPE="slurm"
        echo "[${site_id}] Submitting to SLURM: ${srun_cmd} bash ${APP_REL}/render_tiles.sh"
        ${srun_cmd} bash "${SCRIPT_DIR}/render_tiles.sh" 2>&1 | sed "s/^/[${site_id}] /"
    else
        export DASHBOARD_URL="http://localhost:${DASHBOARD_PORT}"
        export SCHEDULER_TYPE="ssh"
        bash "${SCRIPT_DIR}/render_tiles.sh" 2>&1 | sed "s/^/[${site_id}] /"
    fi
}

# Render function for a site on another resource: SSH with a reverse tunnel
render_site() {
    local site_index=$1
    local site_name=$2
    local site_ip=$3
    local tile_start=$4
    local tile_end=$5
    local dispatch_mode=$6
    local srun_cmd=$7

    local site_id="site-$((site_index + 1))"
    local num_tiles=$((tile_end - tile_start))

    echo ""
    echo "[${site_id}] Starting render on ${site_name} (${site_ip}): ${num_tiles} tiles [${dispatch_mode}]"
    echo "[${site_id}] Dispatching to remote site ${site_name} [${dispatch_mode}]..."

    if [ ! -f ~/.ssh/pwcli ]; then
        echo "[${site_id}] [ERROR] ~/.ssh/pwcli not found on $(hostname): this host cannot open SSH tunnels to other resources"
        echo "[${site_id}] [HINT] Run the dashboard on the user workspace (or an on-prem resource), or add ${site_name} as the dashboard host itself"
        return 1
    fi

    # Probe SSH reachability first — gives a clear error on fresh accounts
    # where site credentials / SSH keys may not be provisioned yet.
    # The probe also reports the remote login shell so future shell-related
    # issues are easy to diagnose. `$SHELL` expansion is identical in
    # bash/tcsh/sh, and `&&` is supported by all three.
    echo "[${site_id}] Probing SSH to ${site_name} via: ${PW_CMD} ssh ${site_name} ..."
    local probe_stderr="${WORK_DIR}/probe_${site_id}.err"
    local probe_stdout
    set +e
    probe_stdout=$(${PW_CMD} ssh "${site_name}" 'echo PW_SSH_OK && hostname && echo "shell=$SHELL"' 2>"${probe_stderr}")
    local probe_rc=$?
    set -e
    if [ ${probe_rc} -ne 0 ] || [[ "${probe_stdout}" != *PW_SSH_OK* ]]; then
        echo "[${site_id}] [ERROR] pw ssh to '${site_name}' failed (exit ${probe_rc})"
        echo "[${site_id}] [ERROR] stdout: ${probe_stdout:-<empty>}"
        if [ -s "${probe_stderr}" ]; then
            echo "[${site_id}] [ERROR] stderr:"
            sed "s/^/[${site_id}]   /" "${probe_stderr}"
        fi
        echo "[${site_id}] [HINT] Common causes on fresh accounts:"
        echo "[${site_id}] [HINT]   - ~/.ssh/pwcli key not yet provisioned (run 'pw ssh ${site_name} hostname' manually)"
        echo "[${site_id}] [HINT]   - Site '${site_name}' not authorized for this user (check Activate resource access)"
        echo "[${site_id}] [HINT]   - Site requires additional onboarding (PIV/CAC, Kerberos, HPC account)"
        return 1
    fi
    echo "[${site_id}] SSH OK — remote reports: ${probe_stdout}"

    # No connection multiplexing: the workspace's ssh config sets a ControlMaster, and
    # the tunnel this connection carries must not be shared with a control master
    local ssh_base=(
        -i ~/.ssh/pwcli
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ControlMaster=no
        -o ControlPath=none
        -o ConnectTimeout=30
        -o "ProxyCommand=${PW_CMD} ssh --proxy-command %h"
    )

    # Allocate a port on the remote for the dashboard tunnel.
    # Use direct ssh (not `pw ssh`) because:
    #   - `pw ssh` does not reliably forward stdin to the remote command,
    #     so heredoc-piped Python produces no output.
    #   - Embedding the Python as a -c argument breaks under tcsh login
    #     shells (ERDC/ARL), which don't honor \" as an escape inside "...".
    local tunnel_port tunnel_stderr="${WORK_DIR}/tunnel_${site_id}.err"
    set +e
    tunnel_port=$(ssh "${ssh_base[@]}" "${PW_USER}@${site_name}" python3 2>"${tunnel_stderr}" <<'PYEOF'
import socket
s = socket.socket()
s.bind(("", 0))
print(s.getsockname()[1])
s.close()
PYEOF
)
    local tunnel_rc=$?
    set -e
    tunnel_port=$(echo "${tunnel_port}" | tail -1 | tr -d '[:space:]')

    if [ ${tunnel_rc} -ne 0 ] || [ -z "${tunnel_port}" ] || ! [[ "${tunnel_port}" =~ ^[0-9]+$ ]]; then
        echo "[${site_id}] [ERROR] Failed to allocate tunnel port (exit ${tunnel_rc}, got: '${tunnel_port}')"
        if [ -s "${tunnel_stderr}" ]; then
            echo "[${site_id}] [ERROR] stderr:"
            sed "s/^/[${site_id}]   /" "${tunnel_stderr}"
        fi
        return 1
    fi
    echo "[${site_id}] Tunnel port: ${tunnel_port} (remote localhost -> dashboard)"

    # Build the remote render script: a per-run work directory, a sparse clone of this
    # repository for the render scripts, then render_tiles.sh
    local script_file="${WORK_DIR}/render_${site_id}.sh"
    cat > "${script_file}" <<RENDER_SCRIPT
#!/bin/bash
set -eo pipefail
WORK="\${HOME}/pw/jobs/burst_render_remote/${PW_RUN_SLUG:-manual}"
mkdir -p "\${WORK}"
cd "\${WORK}"
echo "Work dir: \${WORK} on \$(hostname)"

command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 not found on \$(hostname)"; exit 1; }
echo "Python: \$(python3 --version 2>&1)"

echo "Checking out ${REPO_URL}@${REPO_BRANCH} (${APP_REL})..."
rm -rf _checkout_tmp workflows
git clone --quiet --depth 1 --branch ${REPO_BRANCH} --sparse --filter=blob:none ${REPO_URL} _checkout_tmp
(cd _checkout_tmp && git sparse-checkout set ${APP_REL})
cp -r _checkout_tmp/workflows . && rm -rf _checkout_tmp
[ -f "${APP_REL}/render_tiles.sh" ] || { echo "[ERROR] ${APP_REL}/render_tiles.sh missing after checkout"; exit 1; }

export SITE_ID='${site_id}'
export CLUSTER_NAME='${site_name}'
export TILE_START=${tile_start}
export TILE_END=${tile_end}
export GRID_SIZE=${GRID_SIZE}
export IMAGE_SIZE=${IMAGE_SIZE}
export PALETTE='${PALETTE}'
$([ "${PARALLELISM}" != "auto" ] && echo "export NUM_WORKERS=${PARALLELISM}")
RENDER_SCRIPT

    if [ "${dispatch_mode}" = "slurm" ]; then
        # SLURM mode: run on login node, use srun to dispatch to compute node.
        # The reverse tunnel only binds to localhost on the login node, so a TCP proxy
        # on the login node's hostname exposes it to the compute nodes.
        cat >> "${script_file}" <<RENDER_SCRIPT

PROXY_PORT=\$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
python3 -c "
import socket, threading, sys, os
def proxy(src, dst):
    try:
        while True:
            d = src.recv(65536)
            if not d: break
            dst.sendall(d)
    except: pass
    finally: src.close(); dst.close()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', int(sys.argv[1])))
s.listen(64)
open(sys.argv[3], 'w').write(str(os.getpid()))
while True:
    c, _ = s.accept()
    r = socket.create_connection(('localhost', int(sys.argv[2])))
    threading.Thread(target=proxy, args=(c,r), daemon=True).start()
    threading.Thread(target=proxy, args=(r,c), daemon=True).start()
" \${PROXY_PORT} ${tunnel_port} "\${WORK}/.proxy_pid" &
sleep 1

LOGIN_HOST=\$(hostname)
echo "TCP proxy: \${LOGIN_HOST}:\${PROXY_PORT} -> localhost:${tunnel_port}"

cleanup() { kill \$(cat "\${WORK}/.proxy_pid" 2>/dev/null) 2>/dev/null; }
trap cleanup EXIT

# Render via srun — compute node reaches dashboard through login node proxy
export DASHBOARD_URL="http://\${LOGIN_HOST}:\${PROXY_PORT}"
export SCHEDULER_TYPE='slurm'

echo "Submitting to SLURM: ${srun_cmd} bash ${APP_REL}/render_tiles.sh"
${srun_cmd} bash ${APP_REL}/render_tiles.sh
RENDER_SCRIPT
    else
        # SSH mode: run directly on the remote host; the dashboard is reachable
        # through the reverse tunnel on localhost
        cat >> "${script_file}" <<RENDER_SCRIPT

export DASHBOARD_URL='http://localhost:${tunnel_port}'
export SCHEDULER_TYPE='ssh'

bash ${APP_REL}/render_tiles.sh
RENDER_SCRIPT
    fi

    # Pipe script via stdin to avoid quoting issues with embedded Python/heredocs
    # -R forwards remote's tunnel_port to dashboard host's DASHBOARD_PORT
    ssh "${ssh_base[@]}" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        -o TCPKeepAlive=yes \
        -R "${tunnel_port}:localhost:${DASHBOARD_PORT}" \
        "${PW_USER}@${site_name}" \
        'bash -s' < "${script_file}" 2>&1 | \
        sed "s/^/[${site_id}] /"
}

# Launch all sites in parallel
PIDS=()
SITE_NAMES=()

for i in $(seq 0 $((NUM_SITES - 1))); do
<<<<<<< HEAD
    site() { SITE_KEY="$1" SITE_INDEX="${i}" ${PYTHON_CMD} -c 'import json, os; print(json.loads(os.environ["SITES_JSON"])[int(os.environ["SITE_INDEX"])].get(os.environ["SITE_KEY"], ""))'; }
=======
    site() { echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('$1',''))"; }
>>>>>>> origin/canary
    site_name=$(site name)
    site_ip=$(site ip)
    is_local=$(site is_local)
    use_scheduler=$(site use_scheduler)
    scheduler_type=$(site scheduler_type)
<<<<<<< HEAD
    range() { RANGE_KEY="$1" SITE_INDEX="${i}" ${PYTHON_CMD} -c 'import json, os; print(json.loads(os.environ["TILE_RANGES"])[int(os.environ["SITE_INDEX"])][os.environ["RANGE_KEY"]])'; }
    tile_start=$(range start)
    tile_end=$(range end)
=======
    tile_start=$(echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['start'])")
    tile_end=$(echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['end'])")
>>>>>>> origin/canary

    dispatch_mode="ssh"
    srun_cmd=""
    if [ "${use_scheduler}" = "True" ] && [ "${scheduler_type}" = "slurm" ]; then
        dispatch_mode="slurm"
        srun_cmd=$(build_srun_cmd "$(site slurm_partition)" "$(site slurm_account)" "$(site slurm_qos)" \
            "$(site slurm_time)" "$(site slurm_nodes)" "$(site slurm_directives)")
    fi

    # Notify dashboard this site is pending (before dispatch begins)
    curl -s -X POST "http://localhost:${DASHBOARD_PORT}/api/worker/pending" \
        -H "Content-Type: application/json" \
        -d "{\"site_id\": \"site-$((i + 1))\", \"cluster_name\": \"${site_name}\", \"scheduler_type\": \"${dispatch_mode}\"}" \
        >/dev/null 2>&1 || true

    if [ "${is_local}" = "True" ]; then
        render_site_local "${i}" "${site_name}" "${tile_start}" "${tile_end}" "${dispatch_mode}" "${srun_cmd}" &
    else
        render_site "${i}" "${site_name}" "${site_ip}" "${tile_start}" "${tile_end}" "${dispatch_mode}" "${srun_cmd}" &
    fi
    PIDS+=($!)
    SITE_NAMES+=("${site_name}")
done

echo ""
echo "All ${NUM_SITES} sites dispatched, waiting for completion..."

# Wait for all and collect exit codes
FAILED=0
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        echo "[site-$((i+1))] ${SITE_NAMES[$i]}: COMPLETED"
    else
        echo "[site-$((i+1))] ${SITE_NAMES[$i]}: FAILED (exit $?)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=========================================="
echo "All renders complete!"
echo "  Sites: ${NUM_SITES}"
echo "  Failed: ${FAILED}"
echo "=========================================="

if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
