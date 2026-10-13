#!/bin/bash
################################################################################
# App Testbed worker bootstrap: runs on a worker site, once per site and run
#
# Shipped by dispatch_workers.sh as base64 over `pw ssh` and run as
#   bash -ls -- PORT SRV_RES WNAME ROOT SCHED PQ ACCT WT QOS TMETHOD IS_LOCAL \
#               SRV_USER DIR_B64 PW_USER CPT
# with worker.py in APP_TESTBED_WORKER_B64 and the run's PW_API_KEY and
# PW_PLATFORM_HOST exported. On the server host (IS_LOCAL set) the worker
# connects over localhost; elsewhere it opens a persistent SSH tunnel to the
# server host, probes HTTP and the WebSocket upgrade through it, and starts the
# worker on the login node, or submits it as a SLURM/PBS job with the tunnel
# bound to the submit node's cluster-internal IP so the compute node reaches it
# over the cluster fabric. Re-runs are idempotent: a connected worker or a
# queued/running job is left alone.
################################################################################
set -e
PORT=$1; SRV_RES=$2; WNAME=$3; ROOT_IN=$4
SCHED=${5:-none}; PQ=${6:-}; ACCT=${7:-}; WT=${8:-}; QOS=${9:-}; TMETHOD=${10:-auto}; IS_LOCAL=${11:-}; SRV_USER=${12:-}; DIR_B64=${13:-}; PW_USER=${14:-}; CPT=${15:-}
ROOT=$(eval echo "$ROOT_IN")
mkdir -p "$ROOT"
health() { curl -sf -m 3 -o /dev/null "http://127.0.0.1:$PORT/health"; }
# websocket probe: a 101/403 response means upgrades pass through
# the tunnel; a timeout means the tunnel is stale
ws_ok() { curl -si -m 8 --http1.1 -H "Upgrade: websocket" -H "Connection: Upgrade" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$1/ws" 2>/dev/null | head -1 | grep -qE "HTTP/1.[01] (101|403)"; }
# tunnel method is selectable so pw forward releases can be
# verified against the websocket probe; auto prefers plain ssh
# via the platform proxy command when the pwcli key exists
start_tunnel() { # $1 = bind spec, e.g. IP:PORT:localhost:PORT
  USE=$TMETHOD
  [ "$USE" = "auto" ] && { [ -f "$HOME/.ssh/pwcli" ] && USE=ssh || USE=pw-forward; }
  if [ "$USE" = "ssh" ] && [ ! -f "$HOME/.ssh/pwcli" ]; then
    echo "WARNING: ssh tunnel requested but no pwcli key; using pw forward"
    USE=pw-forward
  fi
  echo "starting $USE tunnel to $SRV_RES"
  if [ "$USE" = "ssh" ]; then
    setsid -f ssh -i "$HOME/.ssh/pwcli" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o "ProxyCommand=pw ssh --proxy-command %h" -N -L "$1" "${PW_USER:-${SRV_USER:-$USER}}@$SRV_RES" > "$ROOT/tunnel.log" 2>&1 < /dev/null
  else
    setsid -f pw forward -L "$1" "$SRV_RES" > "$ROOT/tunnel.log" 2>&1 < /dev/null
  fi
}
# a stale pwcli.pub next to the key (old install, rotated key)
# makes ssh refuse to sign with the private key entirely
# ("identity_sign: contents do not match public"); regenerate it
# from the private key, or drop a corrupt pair for re-adoption
if [ "$TMETHOD" != "pw-forward" ] && [ -f "$HOME/.ssh/pwcli" ]; then
  want=$(ssh-keygen -y -f "$HOME/.ssh/pwcli" 2>/dev/null | awk '{print $1" "$2}')
  if [ -z "$want" ]; then
    echo "platform ssh key unreadable; removing it for re-adoption"
    rm -f "$HOME/.ssh/pwcli" "$HOME/.ssh/pwcli.pub"
  elif [ -f "$HOME/.ssh/pwcli.pub" ] && [ "$want" != "$(awk '{print $1" "$2}' "$HOME/.ssh/pwcli.pub" 2>/dev/null)" ]; then
    echo "repairing mismatched pwcli.pub from the private key"
    ssh-keygen -y -f "$HOME/.ssh/pwcli" > "$HOME/.ssh/pwcli.pub"
  fi
fi
# sites without the platform ssh key adopt the server host's:
# the per-user key is accepted across resources, and it rides
# pw ssh stdout rather than a command line. Skipped when
# pw forward was requested explicitly.
if [ "$TMETHOD" != "pw-forward" ] && [ ! -f "$HOME/.ssh/pwcli" ] && [ -z "$IS_LOCAL" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  # < /dev/null is load-bearing: this script arrives on stdin of
  # bash -ls, and pw ssh drains stdin — without the redirect it
  # swallows the rest of the script and the bootstrap silently
  # exits 0 right after this block
  ( umask 077; pw ssh "$SRV_RES" "cat ~/.ssh/pwcli" 2>/dev/null < /dev/null | sed -n "/BEGIN/,/END/p" > "$HOME/.ssh/pwcli.tmp" ) || true
  if grep -q "PRIVATE KEY" "$HOME/.ssh/pwcli.tmp" 2>/dev/null; then
    mv "$HOME/.ssh/pwcli.tmp" "$HOME/.ssh/pwcli"
    echo "adopted the server host's platform ssh key for tunnels"
  else
    rm -f "$HOME/.ssh/pwcli.tmp"
  fi
fi
# a pw forward tunnel left over from a run without the key is
# replaced by the plain-ssh tunnel
if [ "$TMETHOD" != "pw-forward" ] && [ -f "$HOME/.ssh/pwcli" ] && pgrep -f "pw forward -L [^ ]*$PORT:localhost:$PORT" >/dev/null; then
  echo "replacing leftover pw forward tunnel with plain ssh"
  pkill -f "pw forward -L [^ ]*$PORT:localhost:$PORT" || true
  sleep 1
fi
# worker.py arrives with this script: the dispatcher ships the copy the server
# host checked out (APP_TESTBED_WORKER_B64), so the site runs the same code and
# needs no GitHub access. The supervisor below and the scheduler probe both grep
# its "WebSocket Connected" line.
[ -n "$APP_TESTBED_WORKER_B64" ] || { echo "ERROR: worker.py was not shipped with the bootstrap (APP_TESTBED_WORKER_B64 is empty)"; exit 1; }
printf '%s' "$APP_TESTBED_WORKER_B64" | base64 -d > "$ROOT/worker.py"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROOT/worker.py" || { echo "ERROR: the shipped worker.py does not parse"; exit 1; }
if [ "$SCHED" = "slurm" ] || [ "$SCHED" = "pbs" ]; then
  JOBNAME="worker-${WNAME:-testbed}"
  # live states only; canceled jobs linger in CG for a while and
  # must not block resubmission
  if [ "$SCHED" = "slurm" ]; then
    QUEUED=$(squeue -h -u "$USER" -n "$JOBNAME" -t PENDING,RUNNING,CONFIGURING,SUSPENDED 2>/dev/null | head -1)
  else
    QUEUED=$(qstat 2>/dev/null | grep -F "$JOBNAME" | awk '$5 ~ /^(Q|R|H|W|T)$/' | head -1)
  fi
  if [ -n "$QUEUED" ]; then
    echo "worker batch job already queued/running: $QUEUED"
    exit 0
  fi
  # compute nodes may lack outbound network access, so the tunnel
  # terminates on the submit node, bound to its cluster-internal
  # IP; batch jobs only need internal routing to this node
  SELF_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$SELF_IP" ] || SELF_IP=$(hostname -i | awk '{print $1}')
  if [ -n "$IS_LOCAL" ]; then
    curl -sf -m 5 "http://$SELF_IP:$PORT/health" >/dev/null || {
      echo "ERROR: server not reachable at http://$SELF_IP:$PORT from other nodes"; exit 1; }
  else
    TPAT="[-]L [^ ]*$PORT:localhost:$PORT"
    if pgrep -f "$TPAT" >/dev/null && ! ws_ok "http://$SELF_IP:$PORT"; then
      echo "existing tunnel fails the websocket probe; recreating it"
      pkill -f "$TPAT" || true
      sleep 1
    fi
    if ! pgrep -f "$TPAT" >/dev/null; then
      start_tunnel "$SELF_IP:$PORT:localhost:$PORT"
    fi
    ok=""
    for i in $(seq 1 20); do curl -sf -m 3 "http://$SELF_IP:$PORT/health" >/dev/null && ws_ok "http://$SELF_IP:$PORT" && ok=1 && break; sleep 1; done
    [ -n "$ok" ] || { echo "ERROR: server unreachable through submit-node tunnel; tunnel.log:"; tail -20 "$ROOT/tunnel.log"; exit 1; }
  fi
  # the worker runs in the foreground so the allocation lives as
  # long as the worker; restart it until the Connected line
  # appears, since a transient tunnel blip would otherwise strand
  # the first attempt
  cat > "$ROOT/worker-job.sh" <<JOBEOF
#!/bin/bash
JOBEOF
  # both schedulers read directives embedded in the script; the
  # picker-driven options ride the submit command line and
  # override these where they overlap
  if [ -n "$DIR_B64" ]; then
    echo "$DIR_B64" | base64 -d >> "$ROOT/worker-job.sh"
  fi
  cat >> "$ROOT/worker-job.sh" <<JOBEOF
set -e
curl -sf -m 5 "http://$SELF_IP:$PORT/health" >/dev/null || { echo "ERROR: cannot reach server from \$(hostname)"; exit 1; }
NAME="$WNAME"
[ -n "\$NAME" ] || NAME=worker-${PW_USER:+$PW_USER-}\$(hostname -s)
# the worker's output goes to its own file: PBS spools the job's
# stdout and only writes the -o file at job end, so the job log
# cannot be polled during the run
: > "$ROOT/worker-run.log"
MARK=0
for ATT in 1 2 3 4 5; do
  python3 "$ROOT/worker.py" "$SELF_IP" "$PORT" "\$NAME" < /dev/null >> "$ROOT/worker-run.log" 2>&1 &
  WPID=\$!
  for i in \$(seq 1 30); do
    CONNS=\$(grep -ac "WebSocket Connected" "$ROOT/worker-run.log" 2>/dev/null || true); CONNS=\${CONNS:-0}
    [ "\$CONNS" -gt "\$MARK" ] && break
    kill -0 \$WPID 2>/dev/null || break
    sleep 2
  done
  CONNS=\$(grep -ac "WebSocket Connected" "$ROOT/worker-run.log" 2>/dev/null || true); CONNS=\${CONNS:-0}
  if [ "\$CONNS" -gt "\$MARK" ]; then
    echo "worker connected on attempt \$ATT"
    wait \$WPID
    exit \$?
  fi
  MARK=\$CONNS
  echo "attempt \$ATT: no websocket connect within 60s; restarting worker"
  kill -9 \$WPID 2>/dev/null || true
  pkill -9 -f "$ROOT/worker.py" 2>/dev/null || true
  sleep 3
done
echo "ERROR: worker failed to connect after 5 attempts"
exit 1
JOBEOF
  chmod +x "$ROOT/worker-job.sh"
  if [ "$SCHED" = "slurm" ]; then
    CMD=(sbatch --job-name="$JOBNAME" --output="$ROOT/worker-job.log" --nodes=1)
    [ -n "$PQ" ] && CMD+=(--partition="$PQ")
    [ -n "$ACCT" ] && CMD+=(--account="$ACCT")
    [ -n "$QOS" ] && CMD+=(--qos="$QOS")
    [ -n "$CPT" ] && CMD+=(--cpus-per-task="$CPT")
    [ -n "$WT" ] && CMD+=(--time="$WT")
  else
    # -V exports the submit environment into the job. Queue,
    # walltime etc. come from the #PBS lines embedded in the
    # script.
    CMD=(qsub -V -N "$JOBNAME" -o "$ROOT/worker-job.log" -j oe)
    [ -n "$ACCT" ] && CMD+=(-A "$ACCT")
  fi
  rm -f "$ROOT/worker-job.log" "$ROOT/worker-run.log"
  SUBMIT_OUT=$("${CMD[@]}" "$ROOT/worker-job.sh")
  echo "$SUBMIT_OUT"
  JOBID=$(echo "$SUBMIT_OUT" | grep -oE '[0-9]+' | head -1)
  # pw ssh buffers remote stdout until exit, so waiting here would
  # show nothing until the end; the dispatch step polls the queue
  # instead and parses this line:
  echo "SUBMITTED_JOBID=${JOBID:-unknown} JOBLOG=$ROOT/worker-run.log"
  exit 0
fi
[ -n "$WNAME" ] || WNAME=worker-${PW_USER:+$PW_USER-}$(hostname -s)
if [ -z "$IS_LOCAL" ]; then
  # remote sites must go through the tunnel; if the port answers
  # with no tunnel present, another service owns it
  TPAT="[-]L [^ ]*$PORT:localhost:$PORT"
  if ! pgrep -f "$TPAT" >/dev/null; then
    if health; then
      echo "ERROR: 127.0.0.1:$PORT already answers on this site but no tunnel to $SRV_RES exists; another service owns the port"
      exit 1
    fi
  elif ! ws_ok "http://127.0.0.1:$PORT"; then
    echo "existing tunnel fails the websocket probe; recreating it"
    pkill -f "$TPAT" || true
    sleep 1
  fi
  if ! pgrep -f "$TPAT" >/dev/null; then
    start_tunnel "$PORT:localhost:$PORT"
  fi
  ok=""
  for i in $(seq 1 20); do health && ws_ok "http://127.0.0.1:$PORT" && ok=1 && break; sleep 1; done
  [ -n "$ok" ] || { echo "ERROR: server unreachable through tunnel; tunnel.log:"; tail -20 "$ROOT/tunnel.log"; exit 1; }
elif ! health; then
  echo "ERROR: this is the server host but the server is not answering on :$PORT"
  exit 1
fi
if pgrep -f "worker.py 127.0.0.1 $PORT $WNAME" >/dev/null; then
  # a running process is not enough: a server restart empties the
  # registry and strands the worker on a dead websocket (the
  # worker does not reconnect on its own)
  CONN=$(curl -s -m 5 "http://127.0.0.1:$PORT/workers" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get(sys.argv[1],{}).get('connected') else 'no')" "$WNAME" 2>/dev/null)
  if [ "$CONN" = "yes" ]; then
    echo "worker already running and connected (pid $(pgrep -f "worker.py 127.0.0.1 $PORT $WNAME" | head -1))"
    exit 0
  fi
  echo "worker process exists but is not connected; restarting it"
  pkill -f "worker.py 127.0.0.1 $PORT $WNAME" || true
  sleep 1
fi
# restart until the Connected line appears; a transient tunnel
# blip would otherwise strand the first attempt
rm -f "$ROOT/worker.log"
for ATT in 1 2 3; do
  setsid -f python3 "$ROOT/worker.py" 127.0.0.1 "$PORT" "$WNAME" > "$ROOT/worker.log" 2>&1 < /dev/null
  ok=""
  for i in $(seq 1 15); do
    grep -aq "WebSocket Connected" "$ROOT/worker.log" 2>/dev/null && ok=1 && break
    sleep 2
  done
  [ -n "$ok" ] && break
  echo "attempt $ATT: worker did not connect; retrying"
  pkill -f "worker.py 127.0.0.1 $PORT $WNAME" || true
  sleep 2
done
grep -aq "WebSocket Connected" "$ROOT/worker.log" 2>/dev/null || {
  echo "ERROR: worker did not connect; log:"; tail -20 "$ROOT/worker.log"; exit 1; }
echo "worker '$WNAME' running on $(hostname) (log: $ROOT/worker.log)"
