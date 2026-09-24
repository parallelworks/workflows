#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
# teardown.sh — stop the Ray cluster started by start-template.sh
#
# Cancels the workers on every site (same-resource SLURM jobs from slurm_jobids,
# remote sites over ssh from workers.json plus the sites add_worker appended to
# added_workers.jsonl), stops the Ray head, kills the dashboard wrapper and
# deletes its endpoint. Idempotent; started detached by cancel.sh.
#
# Usage: bash teardown.sh <cluster job dir>

JOB_DIR="${1:-${PW_PARENT_JOB_DIR%/}}"
cd "${JOB_DIR}" || exit 1
# First action: tells cancel.sh this process is out of the caller's process group
touch "${JOB_DIR}/.teardown.started"
# A second caller (trap and submitter cleanup can both run cancel.sh) leaves it to the first
mkdir "${JOB_DIR}/.teardown.lock" 2>/dev/null || { echo "$(date) teardown already running"; exit 0; }

echo "=========================================="
echo "Ray cluster teardown: $(date)"
echo "  Job dir: ${JOB_DIR}"
echo "=========================================="

PW_CMD=""
for try_cmd in pw ~/pw/pw; do
    command -v ${try_cmd} &>/dev/null && { PW_CMD=${try_cmd}; break; }
    [ -x "${try_cmd}" ] && { PW_CMD=${try_cmd}; break; }
done
export PW_CMD

# --- Cancel local SLURM jobs (IDs saved by dispatch_workers.sh, also by add_worker) ---
if [ -f slurm_jobids ]; then
    echo "Cancelling local SLURM jobs..."
    while IFS= read -r jid; do
        [ -n "${jid}" ] && echo "  scancel ${jid}" && scancel "${jid}" 2>/dev/null || true
    done < slurm_jobids
fi

# --- Cancel SLURM/PBS jobs on remote worker sites ---
export JOB_DIR
python3 - <<'PY' 2>&1 || echo "Remote cleanup had errors (non-fatal)"
import json, os, subprocess

job_dir = os.environ['JOB_DIR']
pw_user = os.environ.get('PW_USER', '')
pw_cmd = os.environ.get('PW_CMD') or 'pw'

workers = []
try:
    workers += json.load(open(os.path.join(job_dir, 'workers.json')))
except Exception:
    pass
added = os.path.join(job_dir, 'added_workers.jsonl')
if os.path.exists(added):
    for line in open(added):
        if line.strip():
            workers += json.loads(line)

# Build scheduler type lookup from pw cluster ls
cluster_types = {}
try:
    out = subprocess.check_output([pw_cmd, 'cluster', 'ls'], text=True, timeout=20)
    for line in out.strip().split('\n'):
        parts = line.split()
        if len(parts) >= 3 and parts[0].startswith('pw://'):
            cname = parts[0].split('/')[-1]
            ctype = parts[2]
            if 'slurm' in ctype: cluster_types[cname] = 'slurm'
            elif 'pbs' in ctype: cluster_types[cname] = 'pbs'
            else: cluster_types[cname] = ctype
except Exception as e:
    print(f'Warning: could not list clusters: {e}')

# The head's own resource is a same-resource site: its jobs are in slurm_jobids, and
# a `scancel --name=ray-worker-*` there would hit other clusters of the same user
head_name = ''
try:
    for line in open(os.path.join(job_dir, 'inputs.sh')):
        if 'head_resource_name=' in line:
            head_name = line.split('=', 1)[1].strip().strip('"')
except Exception:
    pass
seen = {head_name} if head_name else set()
for w in workers:
    res = w.get('resource', {})
    if isinstance(res, str):
        name = res
        sched = cluster_types.get(name, '')
    else:
        name = res.get('name', res.get('ip', ''))
        sched = res.get('schedulerType', cluster_types.get(name, ''))
    if not name or name in seen:
        continue
    seen.add(name)
    print(f'Cleaning up {name} (scheduler={sched})...')
    ssh_base = [
        'ssh', '-i', os.path.expanduser('~/.ssh/pwcli'),
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
        '-o', 'ConnectTimeout=15',
        '-o', f'ProxyCommand={pw_cmd} ssh --proxy-command %h',
        f'{pw_user}@{name}',
    ]
    if sched == 'slurm':
        cmd = ('WORK=${PW_PARENT_JOB_DIR:-${HOME}/pw/jobs/ray_worker_remote}; '
               'if [ -f "${WORK}/slurm_jobid" ]; then jid=$(cat "${WORK}/slurm_jobid"); '
               'echo "Cancelling SLURM job ${jid}"; scancel "${jid}" 2>/dev/null; fi; '
               'scancel --name="ray-worker-*" 2>/dev/null; ray stop --force 2>/dev/null; echo "SLURM cleanup done"')
    elif sched == 'pbs':
        cmd = ('WORK=${PW_PARENT_JOB_DIR:-${HOME}/pw/jobs/ray_worker_remote}; '
               'if [ -f "${WORK}/pbs_jobid" ]; then jid=$(cat "${WORK}/pbs_jobid"); '
               'echo "Cancelling PBS job ${jid}"; qdel "${jid}" 2>/dev/null; fi; '
               'ray stop --force 2>/dev/null; echo "PBS cleanup done"')
    else:
        cmd = 'ray stop --force 2>/dev/null || true'
    try:
        subprocess.run(ssh_base + [cmd], timeout=60)
    except Exception as e:
        print(f'  {name}: remote cleanup failed: {e}')
PY

# --- Dispatchers and their SSH sessions ---
# Closing a remote site's session is what tears that site down: its login-node
# script watches the session and cancels its job and proxies when it goes (the
# ssh calls above need pw, whose run key is gone once the run has completed).
kill_tree() {
    local pid=$1 child
    for child in $(pgrep -P "${pid}" 2>/dev/null); do
        kill_tree "${child}"
    done
    kill "${pid}" 2>/dev/null || true
}
if [ -f dispatch.pid ]; then
    kill_tree "$(cat dispatch.pid)"
fi
# add_worker's detached dispatches, one process group each
if [ -f added_dispatch_pgids ]; then
    while IFS= read -r pgid; do
        [ -n "${pgid}" ] || continue
        if ps -o args= -p "${pgid}" 2>/dev/null | grep -q dispatch_workers; then
            echo "Closing add_worker dispatch session group ${pgid}"
            kill -- "-${pgid}" 2>/dev/null || true
        fi
    done < added_dispatch_pgids
fi

# --- Stop Ray head ---
VENV_DIR="$(cat RAY_VENV_DIR 2>/dev/null || echo "")"
if [ -n "${VENV_DIR}" ] && [ -x "${VENV_DIR}/bin/ray" ]; then
    "${VENV_DIR}/bin/ray" stop --force 2>/dev/null || true
elif command -v ray &>/dev/null; then
    ray stop --force 2>/dev/null || true
fi

# --- Dashboard wrapper and its endpoint ---
if [ -f dashboard.pid ]; then
    kill "$(cat dashboard.pid)" 2>/dev/null || true
fi
if [ -f ENDPOINT_NAME ] && [ -n "${PW_CMD}" ]; then
    ${PW_CMD} endpoints delete "$(cat ENDPOINT_NAME)" 2>/dev/null || true
fi

touch TEARDOWN_DONE
echo "$(date) Ray cluster teardown done."
