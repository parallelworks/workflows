################################################################################
# Interactive Session Service Starter - File Browser
#
# Purpose: Start File Browser (filebrowser/filebrowser) with Docker Compose
#          behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - filebrowser_image: Docker image
#   - filebrowser_rundir: holds config/ and database/
#   - filebrowser_data_dir: the directory File Browser serves
#   - filebrowser_auth_method: noauth (platform login only) or json (File Browser users)
#   - filebrowser_admin_password: optional, the admin user's password (json)
################################################################################

set -x

mkdir -p "${filebrowser_rundir}/config" "${filebrowser_rundir}/database" "${filebrowser_data_dir}"

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
${docker_cmd} pull "${filebrowser_image}"
echo "::endgroup::"

export project_name="filebrowser_${PW_RUN_SLUG}"
export docker_cmd
# The container runs as the workflow user so the files it creates under the
# served directory belong to that user, not to the image's uid 1000
export container_uid="$(id -u)"
export container_gid="$(id -g)"
export filebrowser_auth_method="${filebrowser_auth_method:-noauth}"

# The compose stack is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to bring it down
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --remove-orphans
EOF
chmod +x cancel.sh

echo "::group::Starting File Browser"

# pw endpoints run exports PORT and PW_ENDPOINT_PATH to the wrapped command; the
# launcher writes the compose file at runtime because they are unknown before
# launch. PW_ENDPOINT_PATH is / on a subdomain endpoint and the full prefix on a
# path-based one (--no-subdomain); File Browser takes it without the trailing
# slash. The foreground `compose logs -f` keeps the endpoint alive for the
# container's life.
cat > launch-filebrowser-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
cat > docker-compose.yml <<COMPOSEEOF
services:
  filebrowser:
    image: ${filebrowser_image}
    user: "${container_uid}:${container_gid}"
    environment:
      FB_ADDRESS: "0.0.0.0"
      FB_PORT: "80"
      FB_BASE_URL: "${PW_ENDPOINT_PATH%/}"
      FB_LOG: stdout
    volumes:
      - ${filebrowser_data_dir}:/srv
      - ${filebrowser_rundir}/config:/config
      - ${filebrowser_rundir}/database:/database
    ports:
      - "${PORT}:80"
COMPOSEEOF

fb() {
    ${docker_cmd} compose -p "${project_name}" run --rm -T filebrowser "$@"
}

# The form decides the authentication on every start, not only when the
# database is created: --noauth and --password are quick-setup flags that a
# later start ignores, so the database is bootstrapped and updated with the CLI
if [ ! -f "${filebrowser_rundir}/database/filebrowser.db" ]; then
    fb config init --auth.method="${filebrowser_auth_method}"
    set +x
    if [ -z "${filebrowser_admin_password}" ]; then
        filebrowser_admin_password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
        if [ "${filebrowser_auth_method}" = "json" ]; then
            echo "::notice title=File Browser admin password::${filebrowser_admin_password}"
        fi
    fi
    fb users add admin "${filebrowser_admin_password}" --perm.admin
    set -x
else
    fb config set --auth.method="${filebrowser_auth_method}"
    if [ -n "${filebrowser_admin_password}" ]; then
        set +x
        fb users update admin --password "${filebrowser_admin_password}" \
            || echo "::warning::Could not update the password of the admin user; the existing database keeps its users"
        set -x
    fi
fi

${docker_cmd} compose -p "${project_name}" up -d
${docker_cmd} compose -p "${project_name}" ps
exec ${docker_cmd} compose -p "${project_name}" logs -f
LAUNCHEOF
chmod +x launch-filebrowser-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-filebrowser-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Treating
    # that as a failure cancelled the whole run from inside the compute job:
    # ollama_gguf runs 24-26 finished "canceled" with the service up, until
    # #1055 disabled this line for that service. Only a launch that never
    # registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
