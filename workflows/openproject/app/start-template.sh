################################################################################
# Interactive Session Service Starter - OpenProject
#
# Purpose: Start the OpenProject all-in-one container (web, worker, PostgreSQL,
#          memcached) in Docker behind a pw endpoint on a pinned subdomain, with
#          ACTIVATE seeded as an OpenID Connect provider when the form carries
#          an OIDC client
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_rundir: holds pgdata/, assets/, .secret_key_base and .lock
#   - service_image: the openproject/openproject image
#   - service_subdomain: subdomain label of the URL (default openproject-<PW_USER>)
#   - service_admin_password: optional; seeds the admin user of a new run directory
#   - service_enterprise_token_file: optional; an OpenProject Enterprise token to import
#   - oidc_client_id, oidc_client_secret, oidc_display_name: optional ACTIVATE OIDC client
################################################################################

set -x

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/openproject
fi
service_rundir=$(realpath -m "${service_rundir}")
if [ -z "${service_image}" ]; then
    service_image=openproject/openproject:17
fi
if [ -z "${oidc_display_name}" ]; then
    oidc_display_name=ACTIVATE
fi
mkdir -p "${service_rundir}/pgdata" "${service_rundir}/assets"

# Ensure the Docker daemon is running (no-op if already running or not systemctl-managed)
sudo systemctl start docker || true

if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "::notice::Docker is accessible without sudo"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "::notice::Docker requires sudo"
else
    echo "::error title=Error::Docker is not available on $(hostname)"
    exit 1
fi

# The OIDC application is registered for one exact redirect URI, so the URL must
# be the same on every run: pin the subdomain instead of taking a random one.
# Path-based endpoints (--no-subdomain) already have a stable URL.
if ! printf '%s' "${pw_endpoints_args}" | grep -q -- '--no-subdomain'; then
    if [ -z "${service_subdomain}" ] || [ "${service_subdomain}" = "undefined" ]; then
        service_subdomain="openproject-${PW_USER}"
    fi
    service_subdomain=$(printf '%s' "${service_subdomain}" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g' | cut -c1-63 | sed 's/^-//; s/-$//')
    in_use=$(pw endpoints list 2>/dev/null | awk -v host="https://${service_subdomain}." \
        '{ for (i = 2; i <= NF; i++) if (index($i, host) == 1) { print $1, $2; break } }' | head -n 1)
    if [ -n "${in_use}" ]; then
        echo "::error title=Error::https://${service_subdomain}.* is already served by endpoint ${in_use%% *} (status: ${in_use#* }). Open that session, delete it with 'pw endpoints delete ${in_use%% *}', or run again with another subdomain"
        exit 1
    fi
    pw_endpoints_args="${pw_endpoints_args} --subdomain ${service_subdomain}"
fi

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the container can actually start
if ! ${docker_cmd} pull "${service_image}"; then
    echo "::error title=Error::Could not pull ${service_image}"
    exit 1
fi
echo "::endgroup::"

# Rails refuses a default or weak SECRET_KEY_BASE and sessions and encrypted
# settings depend on it, so it is generated once and kept with the data
if [ ! -s "${service_rundir}/.secret_key_base" ]; then
    (
        umask 077
        openssl rand -hex 64 > "${service_rundir}/.secret_key_base"
    )
fi

platform_host=${PW_PLATFORM_HOST#https://}
platform_host=${platform_host#http://}
platform_host=${platform_host%%/*}
if [ -n "${oidc_client_id}" ] && [ -z "${platform_host}" ]; then
    echo "::error title=Error::PW_PLATFORM_HOST is empty; the OIDC issuer URL cannot be built"
    exit 1
fi

export docker_cmd service_rundir service_image service_subdomain platform_host oidc_display_name
export container_name="openproject_${PW_RUN_SLUG}"
export env_file="${PWD}/openproject-${PW_JOB_ID}.env"

# The container belongs to the docker daemon, not the endpoint's process tree,
# so teardown needs cancel.sh (run by the cleanup trap) to remove it
cat > cancel.sh <<CANCELEOF
#!/bin/bash
${docker_cmd} rm -f ${container_name} 2>/dev/null || true
rm -f ${env_file}
CANCELEOF
chmod +x cancel.sh

echo "::group::Starting OpenProject"

# pw endpoints run exports PORT, PW_ENDPOINT_HOST, PW_ENDPOINT_PATH and
# PW_ENDPOINT_URL to the wrapped command; the launcher writes the container's
# environment at runtime because OpenProject must know its public host name
# (absolute URLs, the OIDC redirect URI) before it starts. The foreground
# `docker logs -f` keeps the endpoint alive for the life of the container.
cat > launch-openproject-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x

host="${PW_ENDPOINT_HOST}"
if [ -z "${host}" ]; then
    host=$(printf '%s' "${PW_ENDPOINT_URL}" | sed -E 's#^https?://##; s#[/?].*$##')
fi
if [ -z "${host}" ]; then
    echo "::error title=Error::pw endpoints run did not export the endpoint host (PW_ENDPOINT_HOST / PW_ENDPOINT_URL)"
    exit 1
fi
base_path="${PW_ENDPOINT_PATH%/}"
public_url="https://${host}${base_path}/"

# Two servers on one pgdata would both start and corrupt it; the lock is held
# for the life of this launcher, which `exec`s into `docker logs -f`
exec 9>"${service_rundir}/.lock"
if ! flock -n 9; then
    echo "::error title=Error::${service_rundir} is in use by another OpenProject run; choose another run directory or stop that one first"
    exit 75
fi

(
    umask 077
    {
        echo "SECRET_KEY_BASE=$(cat "${service_rundir}/.secret_key_base")"
        echo "OPENPROJECT_HOST__NAME=${host}"
        echo "OPENPROJECT_HTTPS=true"
        echo "OPENPROJECT_DEFAULT__LANGUAGE=en"
        if [ -n "${base_path}" ]; then
            echo "OPENPROJECT_RAILS__RELATIVE__URL__ROOT=${base_path}"
        fi
        if [ -n "${service_admin_password}" ]; then
            echo "OPENPROJECT_SEED_ADMIN_USER_PASSWORD=${service_admin_password}"
            echo "OPENPROJECT_SEED_ADMIN_USER_PASSWORD_RESET=false"
        fi
        if [ -n "${oidc_client_id}" ]; then
            # Seeded into the database on every boot by the image's db:seed; the
            # provider's slug is the first word after OPENID__CONNECT_, and the
            # redirect URI OpenProject uses is <public URL>/auth/<slug>/callback
            issuer="https://${platform_host}/api/oidc"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_DISPLAY__NAME=${oidc_display_name}"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_IDENTIFIER=${oidc_client_id}"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_SECRET=${oidc_client_secret}"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_ISSUER=${issuer}"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_AUTHORIZATION__ENDPOINT=${issuer}/authorize"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_TOKEN__ENDPOINT=${issuer}/token"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_USERINFO__ENDPOINT=${issuer}/userinfo"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_END__SESSION__ENDPOINT=${issuer}/end_session"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_JWKS__URI=https://${platform_host}/api/platform/keys"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_POST__LOGOUT__REDIRECT__URI=${public_url}"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_SCOPE=openid profile email"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_ATTRIBUTE__MAP_LOGIN=preferred_username"
            echo "OPENPROJECT_OPENID__CONNECT_ACTIVATE_ATTRIBUTE__MAP_EMAIL=email"
        fi
    } > "${env_file}"
)

${docker_cmd} rm -f "${container_name}" 2>/dev/null || true
${docker_cmd} run -d \
    --name "${container_name}" \
    -p "127.0.0.1:${PORT}:80" \
    --env-file "${env_file}" \
    -v "${service_rundir}/pgdata:/var/openproject/pgdata" \
    -v "${service_rundir}/assets:/var/openproject/assets" \
    "${service_image}"

# The first boot of a run directory initializes PostgreSQL, migrates and seeds
# the database (minutes); later boots only migrate and seed. Fail here, with
# the container's log, rather than hand a dead container to the endpoint
echo "Waiting for OpenProject to answer on 127.0.0.1:${PORT}"
code=""
for i in $(seq 1 300); do
    if [ -z "$(${docker_cmd} ps -q --filter "name=^${container_name}$")" ]; then
        ${docker_cmd} logs --tail 80 "${container_name}"
        echo "::error title=Error::The OpenProject container exited during start-up (log above)"
        exit 1
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: ${host}" -H 'X-Forwarded-Proto: https' \
        "http://127.0.0.1:${PORT}${base_path}/health_checks/default")
    if [ "${code}" = "200" ]; then
        break
    fi
    sleep 5
done
if [ "${code}" != "200" ]; then
    ${docker_cmd} logs --tail 80 "${container_name}"
    echo "::error title=Error::OpenProject did not answer /health_checks/default within 25 minutes (last status: ${code:-none})"
    exit 1
fi
echo "::notice::OpenProject is serving at ${public_url}"

if [ -n "${oidc_client_id}" ]; then
    echo "::notice::OpenID Connect provider '${oidc_display_name}' (slug activate): redirect URI ${public_url%/}/auth/activate/callback"
fi

# OpenProject gates every SSO provider behind its Enterprise edition. A token
# is imported once per token into the database, which the run directory keeps
if [ -s "${service_enterprise_token_file}" ]; then
    marker="${service_rundir}/.enterprise-token-$(sha256sum "${service_enterprise_token_file}" | cut -c1-16)"
    if [ -f "${marker}" ]; then
        echo "::notice::Enterprise token already imported into ${service_rundir}"
    else
        ${docker_cmd} exec -i "${container_name}" bash -c 'cat > /tmp/enterprise-token.txt && chown app /tmp/enterprise-token.txt' < "${service_enterprise_token_file}"
        if ${docker_cmd} exec -u app -w /app "${container_name}" bundle exec ruby script/import_enterprise_token /tmp/enterprise-token.txt; then
            touch "${marker}"
        else
            echo "::warning::The Enterprise token was not imported (output above); Sign in with ACTIVATE stays hidden until OpenProject has an active Enterprise token"
        fi
        ${docker_cmd} exec "${container_name}" rm -f /tmp/enterprise-token.txt
    fi
fi

exec ${docker_cmd} logs -f "${container_name}"
LAUNCHEOF
chmod +x launch-openproject-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-openproject-${PW_JOB_ID}.sh

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
    if [ -n "${service_subdomain}" ]; then
        echo "::error title=Error::If this is a subdomain conflict, another endpoint (possibly another user's) holds https://${service_subdomain}.*; run again with a different subdomain"
    fi
    exit 1
fi
echo "::endgroup::"
