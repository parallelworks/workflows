################################################################################
# Interactive Session Service Starter - GitLab
#
# Purpose: Start the GitLab all-in-one container in Docker behind a pw endpoint
#          on a pinned subdomain, with ACTIVATE as an OpenID Connect provider
#          when the form carries an OIDC client, apply a license, register the
#          CI runners (shell on this host, SLURM through Jacamar CI) and start
#          them, and create the demo project
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_rundir: holds config/, data/, logs/, runner/ and the generated secrets
#   - service_image: the gitlab/gitlab-ee or gitlab/gitlab-ce image
#   - service_subdomain: subdomain label of the URL (default gitlab-<PW_USER>)
#   - service_ssh_port: loopback port published for GitLab's SSH
#   - service_root_password_file: optional; the root password for a first start
#   - service_license_file: optional; a .gitlab-license to apply
#   - runners_shell, runners_slurm, runners_demo_project: CI/CD options
#   - service_parent_install_dir: holds gitlab-runner/current and
#     jacamar-ci/current, installed by controller.sh when needed
#   - oidc_client_id, oidc_client_secret_file, oidc_display_name,
#     oidc_block_new_users: optional ACTIVATE OIDC client
################################################################################

set -x

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/gitlab
fi
service_rundir=$(realpath -m "${service_rundir}")
if [ -z "${service_image}" ]; then
    service_image=gitlab/gitlab-ee:19.5.1-ee.0
fi
if [ -z "${service_ssh_port}" ]; then
    service_ssh_port=2222
fi
if [ -z "${oidc_display_name}" ]; then
    oidc_display_name=ACTIVATE
fi
if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
gitlab_runner_bin="${service_parent_install_dir}/gitlab-runner/current/gitlab-runner"
jacamar_bin="${service_parent_install_dir}/jacamar-ci/current/jacamar"
if [ "${runners_shell}" = "true" ] || [ "${runners_slurm}" = "true" ]; then
    if ! [ -x "${gitlab_runner_bin}" ]; then
        echo "::error title=Error::gitlab-runner is not installed at ${gitlab_runner_bin} (the controller installs it)"
        exit 1
    fi
fi
if [ "${runners_slurm}" = "true" ] && ! [ -x "${jacamar_bin}" ]; then
    echo "::error title=Error::Jacamar CI is not installed at ${jacamar_bin} (the controller installs it)"
    exit 1
fi
mkdir -p "${service_rundir}/config" "${service_rundir}/data" "${service_rundir}/logs" "${service_rundir}/runner"

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

for tool in openssl curl flock python3; do
    if ! command -v ${tool} >/dev/null 2>&1; then
        echo "::error title=Error::${tool} is not installed on $(hostname)"
        exit 1
    fi
done

export docker_cmd
export container_name="gitlab_${PW_RUN_SLUG}"
export env_file="${PWD}/gitlab-${PW_JOB_ID}.env"
export run_dir="${PWD}/run"
mkdir -p "${run_dir}"

# The container belongs to the docker daemon and the runner is started in a
# session of its own, so neither is in the endpoint's process tree: teardown
# needs cancel.sh (run by the cleanup trap) to stop them
cat > cancel.sh <<CANCELEOF
#!/bin/bash
if [ -s "${run_dir}/runner.pid" ]; then
    pid=\$(cat "${run_dir}/runner.pid")
    pkill -TERM -s "\${pid}" 2>/dev/null
    for i in \$(seq 1 20); do
        pgrep -s "\${pid}" >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -KILL -s "\${pid}" 2>/dev/null
fi
${docker_cmd} rm -f ${container_name} 2>/dev/null || true
rm -f ${env_file}
CANCELEOF
chmod +x cancel.sh

# GitLab builds its clone URLs and the OIDC redirect URI from its address, so
# the subdomain is pinned instead of taking a random one
if printf '%s' "${pw_endpoints_args}" | grep -q -- '--no-subdomain'; then
    echo "::error title=Error::GitLab serves at the root of its address and needs a subdomain endpoint; this platform has no session subdomains"
    exit 1
fi
if [ -z "${service_subdomain}" ] || [ "${service_subdomain}" = "undefined" ]; then
    service_subdomain="gitlab-${PW_USER}"
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

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the container can actually start
if ! ${docker_cmd} pull "${service_image}"; then
    echo "::error title=Error::Could not pull ${service_image}"
    exit 1
fi
echo "::endgroup::"

# The root password only applies when the database is created, on the first
# start of a run directory; it is kept beside the data so a later run can
# tell the user where it is
root_password_file="${service_rundir}/.root_password"
if [ -s "${service_root_password_file}" ]; then
    if [ -d "${service_rundir}/data/postgresql/data" ]; then
        echo "::warning::${service_rundir} already holds a database: the root password of the form is ignored; change it in GitLab (root's profile -> Password)"
    else
        (
            umask 077
            tr -d '\n' < "${service_root_password_file}" > "${root_password_file}"
        )
    fi
elif [ ! -s "${root_password_file}" ] && [ ! -d "${service_rundir}/data/postgresql/data" ]; then
    (
        umask 077
        openssl rand -base64 18 | tr -d '/+=' | cut -c1-20 > "${root_password_file}"
    )
    echo "::notice::Generated the root password into ${root_password_file}"
fi

platform_host=${PW_PLATFORM_HOST#https://}
platform_host=${platform_host#http://}
platform_host=${platform_host%%/*}
if [ -n "${oidc_client_id}" ] && [ -z "${platform_host}" ]; then
    echo "::error title=Error::PW_PLATFORM_HOST is empty; the OIDC issuer URL cannot be built"
    exit 1
fi

export service_rundir service_image service_subdomain service_ssh_port platform_host oidc_display_name root_password_file gitlab_runner_bin jacamar_bin

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

host="${PW_ENDPOINT_HOST}"
if [ -z "${host}" ]; then
    host=$(printf '%s' "${PW_ENDPOINT_URL}" | sed -E 's#^https?://##; s#[/?].*$##')
fi
if [ -z "${host}" ]; then
    echo "::error title=Error::pw endpoints run did not export the endpoint host (PW_ENDPOINT_HOST / PW_ENDPOINT_URL)"
    exit 1
fi
if [ -n "${PW_ENDPOINT_PATH%/}" ]; then
    echo "::error title=Error::GitLab serves at the root of its address; the endpoint path ${PW_ENDPOINT_PATH} is not supported"
    exit 1
fi
public_url="https://${host}/"
api="http://127.0.0.1:${PORT}/api/v4"

# Two servers on one data directory would both start and corrupt it; the lock
# is held for the life of this launcher, which `exec`s into `docker logs -f`
exec 9>"${service_rundir}/.lock"
if ! flock -n 9; then
    echo "::error title=Error::${service_rundir} is in use by another GitLab run; choose another run directory or stop that one first"
    exit 75
fi

# The platform proxy forwards X-Forwarded-Proto: http, under which GitLab (an
# https external_url) redirects every page to itself and refuses to write its
# Secure session cookie, so the bundled nginx sets the forwarded headers
# itself. The same proxy also rewrites every redirect to another host onto
# the session's own host, which would send the browser to <this host>/api/
# oidc/authorize instead of the platform's sign-in: for the one route that
# redirects to the identity provider, nginx intercepts the 3xx and answers a
# 200 page that navigates there itself (redirects within this host are
# re-issued as they were). The file is mounted into the config volume and
# included from the server block, so the host's user can rewrite it on every
# start although the volume belongs to root
host_re=$(printf '%s' "${host}" | sed 's/[.]/\\./g')
cat > "${run_dir}/nginx-activate.conf" <<NGINXEOF
location = /users/auth/openid_connect {
    proxy_pass http://gitlab-workhorse;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host_with_default;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Ssl on;
    proxy_intercept_errors on;
    error_page 301 302 303 307 308 = @activate_hop;
}
location @activate_hop {
    add_header Set-Cookie \$upstream_http_set_cookie;
    add_header Cache-Control no-store;
    if (\$upstream_http_location ~* "^https?://${host_re}(/|\$|[?#])") { return 302 \$upstream_http_location; }
    default_type text/html;
    return 200 '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=\$upstream_http_location"><title>Redirecting</title></head><body><p>Continue to <a href="\$upstream_http_location">sign in</a>.</p></body></html>';
}
NGINXEOF

# One Ruby line: a docker env file takes no newlines. Secrets are read from
# their files here, so they stay out of the set -x trace
set +x
ruby_quote() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }
config=(
    "external_url 'https://${host}'"
    "nginx['listen_port'] = 80"
    "nginx['listen_https'] = false"
    "nginx['proxy_set_headers'] = { 'Host' => '\$http_host_with_default', 'X-Real-IP' => '\$remote_addr', 'X-Forwarded-For' => '\$proxy_add_x_forwarded_for', 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on', 'Upgrade' => '\$http_upgrade', 'Connection' => '\$connection_upgrade' }"
    "nginx['custom_gitlab_server_config'] = 'include /etc/gitlab/activate/nginx.conf;'"
    "letsencrypt['enable'] = false"
    "prometheus_monitoring['enable'] = false"
    "puma['worker_processes'] = 2"
    "sidekiq['concurrency'] = 10"
    "gitlab_rails['gitlab_shell_ssh_port'] = ${service_ssh_port}"
)
if [ -s "${root_password_file}" ]; then
    config+=("gitlab_rails['initial_root_password'] = '$(ruby_quote "$(cat "${root_password_file}")")'")
fi
if [ -n "${oidc_client_id}" ]; then
    issuer="https://${platform_host}/api/oidc"
    block_new_users=false
    if [ "${oidc_block_new_users}" = "true" ]; then
        block_new_users=true
    fi
    config+=(
        "gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']"
        "gitlab_rails['omniauth_block_auto_created_users'] = ${block_new_users}"
        "gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']"
        "gitlab_rails['omniauth_providers'] = [{ name: 'openid_connect', label: '$(ruby_quote "${oidc_display_name}")', args: { name: 'openid_connect', scope: ['openid', 'profile', 'email'], response_type: 'code', issuer: '${issuer}', discovery: false, uid_field: 'preferred_username', pkce: true, client_options: { identifier: '$(ruby_quote "${oidc_client_id}")', secret: '$(ruby_quote "$(cat "${oidc_client_secret_file}")")', redirect_uri: '${public_url}users/auth/openid_connect/callback', authorization_endpoint: '${issuer}/authorize', token_endpoint: '${issuer}/token', userinfo_endpoint: '${issuer}/userinfo', jwks_uri: 'https://${platform_host}/api/platform/keys', end_session_endpoint: '${issuer}/end_session' } } }]"
    )
else
    config+=("gitlab_rails['omniauth_providers'] = []")
fi
(
    umask 077
    {
        printf 'GITLAB_OMNIBUS_CONFIG='
        sep=""
        for line in "${config[@]}"; do
            printf '%s%s' "${sep}" "${line}"
            sep="; "
        done
        printf '\n'
    } > "${env_file}"
)
set -x

${docker_cmd} rm -f "${container_name}" 2>/dev/null || true
${docker_cmd} run -d \
    --name "${container_name}" \
    --hostname "${host}" \
    -p "127.0.0.1:${PORT}:80" \
    -p "127.0.0.1:${service_ssh_port}:22" \
    --shm-size 256m \
    --env-file "${env_file}" \
    -v "${service_rundir}/config:/etc/gitlab" \
    -v "${service_rundir}/logs:/var/log/gitlab" \
    -v "${service_rundir}/data:/var/opt/gitlab" \
    -v "${run_dir}/nginx-activate.conf:/etc/gitlab/activate/nginx.conf:ro" \
    "${service_image}"

# The first boot of a run directory runs the whole configuration (minutes);
# later boots only reconfigure and migrate. The endpoint is already listed
# (the host name had to be known before the container could start), so a boot
# that fails must end this launcher, with the container's log, well inside
# the wait job's budget. The sign-in page, probed without a forwarded protocol
# like the platform does, answers 200 only when the header fix is in place
# (302 to itself otherwise)
echo "Waiting for GitLab to answer on 127.0.0.1:${PORT}"
code=""
for i in $(seq 1 360); do
    if [ -z "$(${docker_cmd} ps -q --filter "name=^${container_name}$")" ]; then
        ${docker_cmd} logs --tail 80 "${container_name}"
        echo "::error title=Error::The GitLab container exited during start-up (log above)"
        exit 1
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: ${host}" "http://127.0.0.1:${PORT}/users/sign_in")
    if [ "${code}" = "200" ]; then
        break
    fi
    if [ $((i % 12)) -eq 0 ]; then
        echo "GitLab is still starting ($((i * 5)) s, last status ${code:-none})"
    fi
    sleep 5
done
if [ "${code}" != "200" ]; then
    ${docker_cmd} logs --tail 80 "${container_name}"
    echo "::error title=Error::GitLab's sign-in page did not answer 200 within 30 minutes (last status: ${code:-none})"
    exit 1
fi
echo "::notice::GitLab is serving at ${public_url}"

# Everything after the boot goes through the API with a root token that lives
# for this launcher only; it is revoked at the end. The token never enters
# the trace
set +x
admin_token=$(${docker_cmd} exec "${container_name}" gitlab-rails runner \
    "t = User.find_by_username('root').personal_access_tokens.create!(scopes: ['api', 'create_runner'], name: 'activate-workflow-${PW_RUN_SLUG}', expires_at: 1.day.from_now); puts t.token" 2>/dev/null | tail -n 1)
if [ -z "${admin_token}" ]; then
    echo "::error title=Error::Could not create a root API token in the container (gitlab-rails runner failed)"
    exit 1
fi
api_call() {
    # api_call <method> <path> [curl args...]: sets api_status and api_body
    local method=$1 path=$2 out
    shift 2
    out=$(curl -s -w '\n%{http_code}' -X "${method}" -H "PRIVATE-TOKEN: ${admin_token}" -H "Host: ${host}" "$@" "${api}${path}")
    api_status=${out##*$'\n'}
    api_body=${out%$'\n'*}
}
json_get() {
    # json_get <key> reads a JSON object from stdin
    python3 -c 'import json, sys; d = json.load(sys.stdin); v = d.get(sys.argv[1], ""); print(v if v is not None else "")' "$1"
}

if [ -s "${service_license_file}" ]; then
    marker="${service_rundir}/.license-$(sha256sum "${service_license_file}" | cut -c1-16)"
    if [ -f "${marker}" ]; then
        echo "::notice::The license of the form is already applied to ${service_rundir}"
    else
        api_call POST /license --data-urlencode "license@${service_license_file}"
        if [ "${api_status}" = "201" ]; then
            touch "${marker}"
            echo "::notice::License applied: plan $(printf '%s' "${api_body}" | json_get plan), expires $(printf '%s' "${api_body}" | json_get expires_at)"
        else
            echo "::warning::The license was not applied (HTTP ${api_status}): ${api_body}. Add it under Admin -> Settings -> General -> Add License"
        fi
    fi
fi

# Each runner's authentication token is kept in the run directory, so a later
# run finds its runners again; the configuration is rewritten on every start
# because the GitLab port changes with the endpoint
runner_root="${service_rundir}/runner"
mkdir -p "${runner_root}/tokens"
chmod 700 "${runner_root}/tokens"
register_runner() {
    # register_runner <kind> <run_untagged>
    local kind=$1 untagged=$2 token_file="${runner_root}/tokens/$1.token" token
    if [ -s "${token_file}" ]; then
        api_call POST /runners/verify --data-urlencode "token@${token_file}"
        if [ "${api_status}" = "200" ]; then
            echo "The ${kind} runner is already registered"
            return 0
        fi
        echo "The stored ${kind} runner token is no longer valid (HTTP ${api_status}); registering again"
    fi
    api_call POST /user/runners \
        --data "runner_type=instance_type" \
        --data-urlencode "description=${kind} runner on $(hostname) (ACTIVATE run ${PW_RUN_SLUG})" \
        --data "tag_list=${kind}" \
        --data "run_untagged=${untagged}" \
        --data "paused=false"
    token=$(printf '%s' "${api_body}" | json_get token)
    if [ "${api_status}" != "201" ] || [ -z "${token}" ]; then
        # The body of a success carries the token, so only the message is shown
        echo "::error title=Error::Could not register the ${kind} runner (HTTP ${api_status}): $(printf '%s' "${api_body}" | json_get message)"
        return 1
    fi
    (
        umask 077
        printf '%s' "${token}" > "${token_file}"
    )
    echo "Registered the ${kind} runner"
}
runner_block() {
    # runner_block <kind> <executor>
    local kind=$1 executor=$2
    cat <<TOMLEOF

[[runners]]
  name = "${kind} runner on $(hostname)"
  url = "http://127.0.0.1:${PORT}/"
  clone_url = "http://127.0.0.1:${PORT}"
  token = "$(cat "${runner_root}/tokens/${kind}.token")"
  executor = "${executor}"
  shell = "bash"
  builds_dir = "${runner_root}/builds/${kind}"
  cache_dir = "${runner_root}/cache/${kind}"
TOMLEOF
}
runners=""
if [ "${runners_shell}" = "true" ]; then
    register_runner shell true || exit 1
    runners="${runners} shell"
fi
if [ "${runners_slurm}" = "true" ]; then
    register_runner slurm false || exit 1
    runners="${runners} slurm"
fi
if [ -n "${runners}" ]; then
    mkdir -p "${runner_root}/builds" "${runner_root}/cache"
    (
        umask 077
        {
            echo "concurrent = 4"
            echo "check_interval = 3"
            if [ "${runners_shell}" = "true" ]; then
                runner_block shell shell
            fi
            if [ "${runners_slurm}" = "true" ]; then
                runner_block slurm custom
                cat <<TOMLEOF
  [runners.custom]
    config_exec = "${jacamar_bin}"
    config_args = ["config", "--configuration", "${runner_root}/jacamar.toml"]
    prepare_exec = "${jacamar_bin}"
    prepare_args = ["prepare"]
    run_exec = "${jacamar_bin}"
    run_args = ["run"]
    cleanup_exec = "${jacamar_bin}"
    cleanup_args = ["cleanup", "--configuration", "${runner_root}/jacamar.toml"]
    graceful_kill_timeout = 600
    force_kill_timeout = 300
TOMLEOF
            fi
        } > "${runner_root}/config.toml"
    )
    if [ "${runners_slurm}" = "true" ]; then
        mkdir -p "${runner_root}/jacamar"
        chmod 700 "${runner_root}/jacamar"
        cat > "${runner_root}/jacamar.toml" <<TOMLEOF
[general]
  executor = "slurm"
  data_dir = "${runner_root}/jacamar"
TOMLEOF
    fi
    # The runner outlives this run like the container does and must not die
    # with the endpoint's process tree by accident, so it gets a session of
    # its own, which cancel.sh kills by session id
    setsid nohup "${gitlab_runner_bin}" run \
        --config "${runner_root}/config.toml" \
        --working-directory "${runner_root}" \
        > "${runner_root}/runner.log" 2>&1 < /dev/null &
    echo $! > "${run_dir}/runner.pid"
    sleep 3
    if ! kill -0 "$(cat "${run_dir}/runner.pid")" 2>/dev/null; then
        tail -n 30 "${runner_root}/runner.log"
        echo "::error title=Error::gitlab-runner exited right after starting (log above)"
        exit 1
    fi
    echo "::notice::CI runners started:${runners} (log: ${runner_root}/runner.log)"
fi

if [ "${runners_demo_project}" = "true" ] && [ -n "${runners}" ]; then
    api_call GET /projects/root%2Fhpc-ci-demo
    if [ "${api_status}" = "200" ]; then
        echo "The hpc-ci-demo project already exists"
    else
        api_call POST /projects --data "name=hpc-ci-demo" --data "visibility=private" \
            --data-urlencode "description=Pipelines on the ACTIVATE cluster: a shell job on the service host and, with the SLURM runner, a job submitted to the scheduler"
        project_id=$(printf '%s' "${api_body}" | json_get id)
        if [ "${api_status}" != "201" ] || [ -z "${project_id}" ]; then
            echo "::warning::Could not create the hpc-ci-demo project (HTTP ${api_status}): ${api_body}"
        else
            ci_yaml="stages: [test]

hello-service-host:
  stage: test
  tags: [shell]
  script:
    - echo \"Running on \$(hostname) as \$(id -un)\"
    - nproc
    - df -h \"\$HOME\" | tail -n 1
"
            if [ "${runners_slurm}" = "true" ]; then
                ci_yaml="${ci_yaml}
hello-slurm:
  stage: test
  tags: [slurm]
  variables:
    SCHEDULER_PARAMETERS: \"--nodes=1 --time=00:10:00\"
  script:
    - echo \"SLURM job \$SLURM_JOB_ID on \$SLURM_NODELIST\"
    - hostname
    - srun hostname
"
            fi
            readme="# hpc-ci-demo

Pipelines of this project run on the GitLab runners registered by the ACTIVATE workflow:
a shell job on the service host and, when the SLURM runner is enabled, a job that Jacamar CI
submits to the scheduler with the sbatch options in \`SCHEDULER_PARAMETERS\`.
"
            payload=$(python3 -c 'import json, sys; print(json.dumps({"branch": "main", "commit_message": "Add the demo pipeline", "actions": [{"action": "create", "file_path": ".gitlab-ci.yml", "content": sys.argv[1]}, {"action": "create", "file_path": "README.md", "content": sys.argv[2]}]}))' "${ci_yaml}" "${readme}")
            api_call POST "/projects/${project_id}/repository/commits" -H "Content-Type: application/json" --data "${payload}"
            if [ "${api_status}" = "201" ]; then
                echo "::notice::Created the hpc-ci-demo project; its first pipeline is running"
            else
                echo "::warning::Created the hpc-ci-demo project but not its pipeline (HTTP ${api_status}): ${api_body}"
            fi
        fi
    fi
fi

api_call DELETE /personal_access_tokens/self
unset admin_token
set -x

echo "::notice::Sign in as root with the password in ${root_password_file} (first start) or the one you set in GitLab"
if [ -n "${oidc_client_id}" ]; then
    echo "::notice::Sign in with ${oidc_display_name} from GitLab's own tab (${public_url}users/sign_in): redirect URI ${public_url}users/auth/openid_connect/callback"
fi
echo "::notice::Git over HTTP from this host: http://127.0.0.1:${PORT}/<group>/<project>.git; from your machine: pw forward -L ${PORT}:localhost:${PORT} <cluster> (or -L ${service_ssh_port}:localhost:${service_ssh_port} for SSH)"

exec ${docker_cmd} logs -f "${container_name}"
LAUNCHEOF
chmod +x launch-gitlab-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-gitlab-${PW_JOB_ID}.sh

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
    if [ -n "${service_subdomain}" ]; then
        echo "::error title=Error::If this is a subdomain conflict, another endpoint (possibly another user's) holds https://${service_subdomain}.*; run again with a different subdomain"
    fi
    exit 1
fi
echo "::endgroup::"
