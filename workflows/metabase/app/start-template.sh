################################################################################
# Interactive Session Service Starter - Metabase
#
# Purpose: Start Metabase (metabase/metabase) with Docker Compose behind a
#          pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - metabase_image: Docker image
#   - metabase_data_dir: holds the H2 application database and the plugins
#   - metabase_env: optional, extra MB_* variables, one KEY=VALUE per line
################################################################################

set -x

mkdir -p "${metabase_data_dir}/plugins"

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

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the container can actually start
${docker_cmd} pull "${metabase_image}"
echo "::endgroup::"

export project_name="metabase_${PW_RUN_SLUG}"
export docker_cmd
# The image's entrypoint creates its metabase user with these ids, so the
# application database it writes under the data directory belongs to the
# workflow user instead of the image's uid 2000
export container_uid="$(id -u)"
export container_gid="$(id -g)"

# The editor input arrives with its newlines escaped
printf "%b" "${metabase_env:-}" > metabase.env

# The compose stack is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to bring it down
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --remove-orphans
EOF
chmod +x cancel.sh

echo "::group::Starting Metabase"

# pw endpoints run exports PORT to the wrapped command, so the launcher writes
# the compose file at runtime. The foreground `compose logs -f` keeps the
# endpoint alive for the container's life.
cat > launch-metabase-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
cat > docker-compose.yml <<COMPOSEEOF
services:
  metabase:
    image: ${metabase_image}
    environment:
      MUID: "${container_uid}"
      MGID: "${container_gid}"
      MB_DB_FILE: /metabase-data/metabase.db
      MB_PLUGINS_DIR: /metabase-data/plugins
    env_file:
      - metabase.env
    volumes:
      - ${metabase_data_dir}:/metabase-data
    ports:
      - "${PORT}:3000"
COMPOSEEOF

${docker_cmd} compose -p "${project_name}" up -d
${docker_cmd} compose -p "${project_name}" ps
exec ${docker_cmd} compose -p "${project_name}" logs -f
LAUNCHEOF
chmod +x launch-metabase-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-metabase-${PW_JOB_ID}.sh

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
