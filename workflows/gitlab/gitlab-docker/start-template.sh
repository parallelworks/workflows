################################################################################
# Interactive Session Service Starter - GitLab (Docker)
#
# Purpose: Start the GitLab all-in-one container in Docker behind a pw endpoint
#          on a pinned subdomain, with ACTIVATE as an OpenID Connect provider
#          when the form carries an OIDC client, apply a license, register the
#          CI runners (shell on this host, SLURM through Jacamar CI) and start
#          them. What does not depend on Docker is
#          in lib/start.sh (this script) and lib/launcher.sh (the launcher).
# Runs on: Controller node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_image: the gitlab/gitlab-ee or gitlab/gitlab-ce image
#   - the variables lib/start.sh and lib/launcher.sh list
################################################################################

set -x
set -o pipefail

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/start.sh"

if [ -z "${service_image}" ]; then
    service_image=gitlab/gitlab-ee:19.5.1-ee.0
fi

# Ensure the Docker daemon is running (no-op if already running or not systemctl-managed)
sudo -n systemctl start docker 2>/dev/null || true

if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "::notice::Docker is accessible without sudo"
elif sudo -n docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "::notice::Docker requires sudo"
else
    echo "::error title=Error::Docker is not available on $(hostname)"
    exit 1
fi
export docker_cmd service_image
export container_name="gitlab_${PW_RUN_SLUG}"

# The container belongs to the docker daemon: cancel.sh removes it
cat >> cancel.sh <<CANCELEOF
${docker_cmd} rm -f ${container_name} 2>/dev/null || true
CANCELEOF

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the container can actually start
if ! ${docker_cmd} pull "${service_image}"; then
    echo "::error title=Error::Could not pull ${service_image}"
    exit 1
fi
echo "::endgroup::"

echo "::group::Starting GitLab"

# pw endpoints run exports PORT, PW_ENDPOINT_HOST, PW_ENDPOINT_PATH and
# PW_ENDPOINT_URL to the wrapped command; the launcher writes the container's
# configuration at runtime because GitLab must know its public host name
# (external_url: absolute URLs, clone URLs, the OIDC redirect URI) before it
# starts. The foreground `docker logs -f` keeps the endpoint alive for the
# life of the container.
cat > launch-gitlab-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
set -o pipefail

source "${gitlab_lib}/launcher.sh"
gitlab_launcher_init
gitlab_write_nginx_snippet
gitlab_write_omnibus_config 80

gitlab_exec() {
    ${docker_cmd} exec "${container_name}" "$@"
}
gitlab_alive() {
    [ -n "$(${docker_cmd} ps -q --filter "name=^${container_name}$")" ]
}
gitlab_logs() {
    ${docker_cmd} logs --tail 80 "${container_name}"
}

# The 0 a FIPS-mode host hands the container (lib/start.sh)
fips_mount=""
if [ -n "${fips_enabled_file}" ]; then
    fips_mount="-v ${fips_enabled_file}:/proc/sys/crypto/fips_enabled:ro"
fi

${docker_cmd} rm -f "${container_name}" 2>/dev/null || true
${docker_cmd} run -d ${fips_mount} \
    --name "${container_name}" \
    --label "activate.rundir=${service_rundir}" \
    --hostname "${host}" \
    -p "127.0.0.1:${PORT}:80" \
    -p "127.0.0.1:${service_ssh_port}:22" \
    --shm-size 256m \
    --env-file "${run_dir}/gitlab.env" \
    -v "${service_rundir}/config:/etc/gitlab" \
    -v "${service_rundir}/logs:/var/log/gitlab" \
    -v "${service_rundir}/data:/var/opt/gitlab" \
    -v "${run_dir}/activate:/etc/gitlab/activate:ro" \
    "${service_image}"

gitlab_wait_ready
gitlab_setup

${docker_cmd} logs -f "${container_name}" &
wait $!
fail "The GitLab container stopped (its log is above)"
LAUNCHEOF
chmod +x launch-gitlab-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-gitlab-${PW_JOB_ID}.sh
finish_endpoint_run $?
