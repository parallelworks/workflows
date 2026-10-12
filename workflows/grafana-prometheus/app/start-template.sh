################################################################################
# Interactive Session Service Starter - Grafana + Prometheus
#
# Purpose: Start Grafana, Prometheus, node-exporter and, on a GPU node,
#          dcgm-exporter with Docker Compose behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - grafana_rundir: holds data/grafana, data/prometheus and the generated configs
#   - grafana_retention: Prometheus retention time (15d)
#   - grafana_image, prometheus_image, node_exporter_image, dcgm_exporter_image
#   - grafana_agent_metrics: true to export the platform agent's metrics
#   - grafana_resource_name: the resource's name, for the agent
#   - grafana_scheduler: optional, true when this script runs in a scheduler job
#   - grafana_extra_targets: optional, extra scrape targets, one host:port per line
# Required files in PW_PARENT_JOB_DIR (written by preprocessing, mode 600):
#   - grafana-admin-password: the admin user's password
################################################################################

set -x

export rundir=$(realpath -m "${grafana_rundir}")
mkdir -p "${rundir}/data/grafana" "${rundir}/data/prometheus" "${rundir}/prometheus" "${rundir}/grafana"

# Both containers write their data directories as the workflow user. The
# grafana-prometheus workflow chowned them to the images' users (472 and 65534)
not_owned=$(find "${rundir}/data" -maxdepth 1 ! -user "$(id -u)" -print -quit)
if [ -n "${not_owned}" ]; then
    echo "::error title=Error::${not_owned} belongs to another user. Choose another Run Directory, or run: sudo chown -R $(id -un) ${rundir}"
    exit 1
fi

# Two Grafanas on one SQLite database and two Prometheus servers on one TSDB
# corrupt them. This script holds the lock for the life of the stack
exec {lock_fd}>>"${rundir}/workflow.lock"
if ! flock -n "${lock_fd}"; then
    echo "::error title=Error::${rundir} is in use by another run ($(cat "${rundir}/workflow.lock")). Stop that run's endpoint or choose another Run Directory."
    exit 1
fi
echo "run ${PW_RUN_SLUG} on $(hostname)" > "${rundir}/workflow.lock"

# The provisioning files (datasource, dashboards) come from the checkout, which
# a job cleanup may remove; the stack mounts the copy in the Run Directory
rm -rf "${rundir}/grafana/provisioning"
if ! cp -r "${PW_PARENT_JOB_DIR}/workflows/grafana-prometheus/app/grafana/provisioning" "${rundir}/grafana/provisioning"; then
    echo "::error title=Error::Cannot copy the Grafana provisioning files from ${PW_PARENT_JOB_DIR}/workflows/grafana-prometheus/app"
    exit 1
fi

# Ensure the Docker daemon is running (no-op if already running or not systemctl-managed)
sudo systemctl start docker || true

# Detect docker command: prefer without sudo, fall back to sudo docker
if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "::notice::Docker is accessible without sudo"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "::notice::Docker requires sudo"
else
    echo "::error title=Error::Docker is not available on this system"
    exit 1
fi
echo "::notice::Using docker command: ${docker_cmd}"

# dcgm-exporter needs a working driver and the NVIDIA container runtime; a
# compose file that reserves a GPU fails on a node without them
gpu=false
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    if ${docker_cmd} info 2>/dev/null | grep -qw nvidia; then
        gpu=true
        echo "::notice::GPU found: exporting its metrics with dcgm-exporter"
    else
        echo "::warning::GPU found, but Docker has no nvidia runtime: no GPU metrics"
    fi
else
    echo "::notice::No GPU on $(hostname): no GPU metrics"
fi

export project_name="grafana_${PW_RUN_SLUG}"
export docker_cmd
export container_uid="$(id -u)"
export container_gid="$(id -g)"
export compose_files="-f docker-compose.yml"
if [ "${gpu}" = true ]; then
    compose_files="${compose_files} -f docker-compose.gpu.yml"
fi

# The compose stack is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to bring it down
cat > cancel.sh <<CANCELEOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --remove-orphans
CANCELEOF
chmod +x cancel.sh

echo "::group::Image Pulls"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the containers can actually start
images="${grafana_image} ${prometheus_image} ${node_exporter_image}"
if [ "${gpu}" = true ]; then
    images="${images} ${dcgm_exporter_image}"
fi
for image in ${images}; do
    if ! ${docker_cmd} pull "${image}"; then
        echo "::error title=Error::Could not pull ${image}"
        exit 1
    fi
done
echo "::endgroup::"

echo "::group::Platform Agent Metrics"
# The platform agent's exporter is a second agent process of the workflow user,
# started with the run's key and kept in the endpoint's process tree. It is a
# controller agent, so it only runs where the login node's agent runs
agent_port=9091
agent_target=""
if [ "${grafana_agent_metrics:-false}" = true ]; then
    if [ "${grafana_scheduler:-false}" = true ]; then
        echo "::warning::Platform agent metrics are exported from the login node only; this job runs on $(hostname)"
    elif (exec 3<>"/dev/tcp/127.0.0.1/${agent_port}") 2>/dev/null; then
        echo "::notice::Port ${agent_port} is already listening on $(hostname); scraping it as the platform agent's exporter"
        agent_target="host.docker.internal:${agent_port}"
    else
        pw agent start-existing --server="${PW_PLATFORM_HOST}" -t=controller \
            --experimental-prometheus-exporter --experimental-prometheus-exporter-port "${agent_port}" \
            -n "${grafana_resource_name}" > pw-agent-exporter.log 2>&1 &
        agent_pid=$!
        echo "kill ${agent_pid} 2>/dev/null || true" >> cancel.sh
        for i in $(seq 1 20); do
            (exec 3<>"/dev/tcp/127.0.0.1/${agent_port}") 2>/dev/null && break
            kill -0 "${agent_pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${agent_pid}" 2>/dev/null && (exec 3<>"/dev/tcp/127.0.0.1/${agent_port}") 2>/dev/null; then
            echo "::notice::Platform agent exporter listening on port ${agent_port} (pid ${agent_pid})"
            agent_target="host.docker.internal:${agent_port}"
        else
            echo "::warning::The platform agent's exporter did not start; no platform agent metrics"
            tail -n 20 pw-agent-exporter.log
        fi
    fi
fi
echo "::endgroup::"

# The editor input arrives with its newlines escaped
extra_targets=$(printf "%b" "${grafana_extra_targets:-}" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')

{
    cat <<PROMEOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: node
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          nodename: $(hostname)

  - job_name: grafana
    static_configs:
      - targets: ['grafana:3000']
PROMEOF
    if [ "${gpu}" = true ]; then
        cat <<PROMEOF

  - job_name: gpu
    static_configs:
      - targets: ['dcgm-exporter:9400']
        labels:
          nodename: $(hostname)
PROMEOF
    fi
    if [ -n "${agent_target}" ]; then
        cat <<PROMEOF

  - job_name: pw-agent
    scrape_interval: 20s
    static_configs:
      - targets: ['${agent_target}']
        labels:
          exported_by: pw-agent
PROMEOF
    fi
    if [ -n "${extra_targets}" ]; then
        cat <<PROMEOF

  - job_name: extra
    static_configs:
      - targets: [$(printf "%s\n" "${extra_targets}" | sed "s/.*/'&'/" | paste -sd, -)]
PROMEOF
    fi
} > "${rundir}/prometheus/prometheus.yml"
cat "${rundir}/prometheus/prometheus.yml"

if [ "${gpu}" = true ]; then
    cat > docker-compose.gpu.yml <<GPUEOF
services:
  dcgm-exporter:
    image: ${dcgm_exporter_image}
    cap_add:
      - SYS_ADMIN
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
GPUEOF
fi

echo "::group::Starting Grafana"

# pw endpoints run exports PORT and PW_ENDPOINT_URL to the wrapped command; the
# launcher writes the compose file at runtime because they are unknown before
# launch. A subdomain endpoint serves Grafana at the root, so no sub path and
# no proxy; the public URL only goes into the links Grafana builds. The
# foreground `compose logs -f grafana` keeps the endpoint alive for the life
# of the Grafana container.
cat > launch-grafana-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
cat > docker-compose.yml <<COMPOSEEOF
services:
  prometheus:
    image: ${prometheus_image}
    user: "${container_uid}:${container_gid}"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${grafana_retention}
    volumes:
      - ${rundir}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${rundir}/data/prometheus:/prometheus
    extra_hosts:
      - host.docker.internal:host-gateway

  node-exporter:
    image: ${node_exporter_image}
    user: "${container_uid}:${container_gid}"
    pid: host
    command:
      - --path.rootfs=/host
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
    volumes:
      - /:/host:ro,rslave

  grafana:
    image: ${grafana_image}
    user: "${container_uid}:${container_gid}"
    depends_on:
      - prometheus
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password
      GF_SERVER_ROOT_URL: "${PW_ENDPOINT_URL%/}"
      GF_SERVER_SERVE_FROM_SUB_PATH: "false"
      GF_SERVER_ENFORCE_DOMAIN: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_NAME: "Main Org."
      GF_AUTH_ANONYMOUS_ORG_ROLE: Admin
      GF_AUTH_DISABLE_LOGIN_FORM: "false"
      GF_SECURITY_COOKIE_SAMESITE: lax
      GF_SECURITY_COOKIE_SECURE: "false"
      GF_USERS_DEFAULT_THEME: light
    secrets:
      - grafana_admin_password
    volumes:
      - ${rundir}/grafana/provisioning:/etc/grafana/provisioning
      - ${rundir}/data/grafana:/var/lib/grafana
    ports:
      - "127.0.0.1:${PORT}:3000"

secrets:
  grafana_admin_password:
    file: ${PW_PARENT_JOB_DIR}/grafana-admin-password
COMPOSEEOF

compose="${docker_cmd} compose -p ${project_name} ${compose_files}"
if ! ${compose} up -d; then
    ${compose} logs --tail 50
    echo "::error title=Error::Could not start the stack"
    exit 1
fi
${compose} ps

for i in $(seq 1 90); do
    curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${PORT}/api/health" && break
    sleep 2
done
exec ${compose} logs -f grafana
LAUNCHEOF
chmod +x launch-grafana-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} --description "Grafana + Prometheus on $(hostname)" -- ./launch-grafana-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Only a
    # launch that never registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
