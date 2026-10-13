#!/bin/bash
################################################################################
# App Testbed dispatcher: start one worker per site in the Worker sites list
#
# Runs on: The server host's login node (the dispatch_workers job); the sites
#          are reached from here over pw ssh
# Called by: The dispatch_workers job, after inputs.sh is sourced
#
# Required Environment Variables (from inputs.sh):
#   - server_workdir, server_port: the server's working directory and port
#   - server_resource_uri / server_resource_name / server_resource_user: the
#     server host as the sites address it (the URI resolves across namespaces)
#   - tunnel_method: auto | ssh | pw-forward
#   - wait_for_workers: true blocks until every worker connects and fails otherwise
#   - PW_API_KEY, PW_PLATFORM_HOST: forwarded to the sites (pw ssh shells have
#     no pw context of their own)
#   - PW_PARENT_JOB_DIR: the run directory (workers.json, the checked-out app/)
################################################################################
set -e
APP_DIR="${PW_PARENT_JOB_DIR%/}/workflows/app-testbed/app"
WORKDIR=$(eval echo "${server_workdir:-~/app-testbed}")
mkdir -p "$WORKDIR"
PORT="${server_port:-8090}"
# use the resource URI, not the short name: a shared cluster in
# another namespace only resolves by its pw://owner/name URI
SRV_RES="${server_resource_uri:-}"
[ -n "$SRV_RES" ] || SRV_RES="${server_resource_name:-}"
[ -n "$SRV_RES" ] || { echo "ERROR: the server host's resource name is empty"; exit 1; }
SRV_USER="${server_resource_user:-}"
TMETHOD="${tunnel_method:-auto}"
WAIT_WORKERS=$(echo "${wait_for_workers:-true}" | tr '[:upper:]' '[:lower:]')
# worker names default to worker-<pw user>-<hostname>: hostname
# alone collides when several platform users dispatch to the same
# host, and a same-name registration bumps the earlier worker
PW_USER=$(pw auth whoami 2>/dev/null | tail -1)
WORKERS_JSON=$(cat "${PW_PARENT_JOB_DIR%/}/workers.json" 2>/dev/null || echo '[]')
# the site bootstrap and the worker ride the pw ssh command line as base64:
# the sites run exactly what this host checked out and need no GitHub access
BOOT_B64=$(base64 -w0 < "$APP_DIR/worker-bootstrap.sh")
WORKER_B64=$(base64 -w0 < "$APP_DIR/worker.py")
TSV=$WORKDIR/.workers.tsv
printf '%s' "$WORKERS_JSON" | python3 -c '
import base64, json, sys
try:
    items = json.load(sys.stdin) or []
except Exception:
    items = []
for w in items:
    r = w.get("resource") or {}
    if isinstance(r, str):
        r = {"name": r}
    name = (r.get("uri")
            or ("pw://%s/%s" % (r["namespace"], r["name"]) if r.get("namespace") and r.get("name") else "")
            or r.get("name") or r.get("ip") or "")
    sched = "none"
    if str(w.get("scheduler")).lower() == "true":
        st = (r.get("schedulerType") or "").lower()
        if st in ("slurm", "pbs"):
            sched = st
        else:
            print("WARNING: %s: scheduler requested but schedulerType is %r; running unscheduled" % (name, st), file=sys.stderr)
    sl = w.get("slurm") or {}
    pb = w.get("pbs") or {}
    pq = acct = wt = qos = cpt = dirs = ""
    if sched == "slurm":
        pq, acct, wt = sl.get("partition") or "", sl.get("account") or "", sl.get("time") or ""
        qos, cpt = sl.get("qos") or "", str(sl.get("cpus_per_task") or "")
        dirs = base64.b64encode((sl.get("scheduler_directives") or "").encode()).decode()
    elif sched == "pbs":
        acct = pb.get("account") or ""
        dirs = base64.b64encode((pb.get("scheduler_directives") or "").encode()).decode()
    print(chr(31).join([name, w.get("worker_name") or "", w.get("workdir") or "~/app-testbed-worker", sched, pq, acct, wt, qos, dirs, cpt]))
' > "$TSV"
if [ ! -s "$TSV" ]; then
  echo "no worker sites configured; nothing to do"
  rm -f "$TSV"
  exit 0
fi
# per-poll status probe run on the worker site:
# prints STATE=<queue state>|LOG=<yes/no>|CONN=<connect count>
PROBE_B64=$(base64 -w0 <<'PROBEEOF'
JOBID=$1; JOBLOG=$2; SCHED=$3
if [ "$SCHED" = "slurm" ]; then
  ST=$(squeue -h -j "$JOBID" -o "%T %r" 2>/dev/null | head -1)
else
  ST=$(qstat "$JOBID" 2>/dev/null | tail -1 | awk '{print $5}')
fi
CONN=0; LOGE=no
if [ -f "$JOBLOG" ]; then
  LOGE=yes
  CONN=$(grep -ac "WebSocket Connected" "$JOBLOG" 2>/dev/null)
  CONN=${CONN:-0}
fi
echo "STATE=${ST:-gone}|LOG=$LOGE|CONN=$CONN"
PROBEEOF
)
FAILED=""
# unit-separator delimiter: tab is IFS whitespace and collapses
# empty fields, which would drop a blank worker_name. The TSV is
# read on fd 3: pw ssh in the loop body drains stdin, which on
# fd 0 would swallow every site after the first
while IFS="$(printf '\037')" read -r NAME WNAME WD SCHED PQ ACCT WT QOS DIRS CPT <&3; do
  [ -n "$NAME" ] || continue
  echo ""
  echo "=== dispatching worker to $NAME (scheduler=$SCHED) ==="
  # forward the platform-injected auth env; plain pw ssh shells
  # have no pw context of their own. bash -ls gives a login-shell
  # PATH on the remote side.
  LOCAL=""
  [ "$NAME" = "$SRV_RES" ] && LOCAL=1
  if OUT=$(pw ssh "$NAME" "export PW_API_KEY='$PW_API_KEY' PW_PLATFORM_HOST='$PW_PLATFORM_HOST' APP_TESTBED_WORKER_B64='$WORKER_B64'; echo $BOOT_B64 | base64 -d | bash -ls -- '$PORT' '$SRV_RES' '$WNAME' '$WD' '$SCHED' '$PQ' '$ACCT' '$WT' '$QOS' '$TMETHOD' '$LOCAL' '$SRV_USER' '$DIRS' '$PW_USER' '$CPT'" 2>&1); then
    echo "$OUT"
    JOBID=$(echo "$OUT" | grep -a 'SUBMITTED_JOBID=' | grep -oE 'SUBMITTED_JOBID=[0-9]+' | head -1 | cut -d= -f2)
    JOBLOG=$(echo "$OUT" | grep -a 'JOBLOG=' | grep -oE 'JOBLOG=[^ ]+' | head -1 | cut -d= -f2)
    if [ -z "$JOBID" ]; then
      echo "=== $NAME: OK ==="
    elif [ "$WAIT_WORKERS" != "true" ]; then
      echo "job $JOBID submitted; not waiting for connect. Progress log: $JOBLOG on $NAME"
      echo "=== $NAME: OK (submitted) ==="
    else
      # watch from this step so queue states stream into the run
      # log in real time
      echo "watching job $JOBID on $NAME (polling every ~15s, up to ~35 min)"
      LAST=""; CONN=0; LOGE=no; ST=""; SCONW=0
      for i in $(seq 1 120); do
        P=$(pw ssh "$NAME" "echo $PROBE_B64 | base64 -d | bash -s -- '$JOBID' '$JOBLOG' '$SCHED'" 2>/dev/null | grep -a '^STATE=' | head -1)
        if [ -z "$P" ]; then echo "  (probe failed; retrying)"; sleep 15; continue; fi
        ST=$(echo "$P" | sed -n 's/^STATE=\([^|]*\).*/\1/p')
        LOGE=$(echo "$P" | sed -n 's/.*|LOG=\([^|]*\).*/\1/p')
        CONN=$(echo "$P" | sed -n 's/.*|CONN=\([0-9]*\)$/\1/p'); CONN=${CONN:-0}
        [ "$ST" != "$LAST" ] && echo "  queue: $ST"
        LAST=$ST
        [ "$CONN" -ge 1 ] && break
        if [ "$LOGE" = "yes" ]; then
          SCONW=$((SCONW+1))
          [ "$SCONW" = "1" ] && echo "  job is running; waiting for worker websocket connect..."
          [ "$SCONW" -ge 24 ] && break
        fi
        [ "$ST" = "gone" ] && break
        sleep 15
      done
      if [ "$CONN" -ge 1 ]; then
        echo "--- worker connected; job log highlights ---"
        pw ssh "$NAME" "grep -a 'registered\|Connected' '$JOBLOG' 2>/dev/null | head -3; true" 2>/dev/null
        echo "=== $NAME: OK (job $JOBID, worker connected) ==="
      elif [ "$LOGE" = "yes" ] || [ "$ST" = "gone" ]; then
        echo "ERROR: worker on $NAME did not connect (job $JOBID, state ${ST:-?}); job log tail:"
        pw ssh "$NAME" "tail -20 '$JOBLOG' 2>/dev/null; true" 2>/dev/null
        echo "=== $NAME: FAILED ==="
        FAILED="$FAILED $NAME"
      else
        echo "NOTE: job $JOBID still queued (state $ST) after the watch window; the worker registers when it starts"
        echo "=== $NAME: OK (submitted; still queued) ==="
      fi
    fi
  else
    echo "$OUT"
    echo "=== $NAME: FAILED ==="
    FAILED="$FAILED $NAME"
  fi
done 3< "$TSV"
rm -f "$TSV"
[ -z "$FAILED" ] || { echo "ERROR: worker dispatch failed on:$FAILED"; exit 1; }
echo "all worker sites dispatched"
