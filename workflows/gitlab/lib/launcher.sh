################################################################################
# GitLab launcher library, shared by gitlab-docker and gitlab-singularity
#
# Purpose: Everything the script that pw endpoints run executes does that does
#          not depend on the container runtime: the public host and the lock,
#          the nginx snippet (forwarded headers, the OIDC hop page and the
#          readiness gate), the Linux package's configuration, the wait for the
#          sign-in page, and the setup after the boot (license, CI runners,
#          demo project). The launcher sources it, defines gitlab_exec (run a
#          command in the container), gitlab_alive (is the container running)
#          and gitlab_logs (print the tail of its log) for its runtime, starts
#          the container and calls gitlab_wait_ready, then gitlab_setup.
# Runs on: Controller or compute node, under pw endpoints run (PORT,
#          PW_ENDPOINT_HOST, PW_ENDPOINT_PATH, PW_ENDPOINT_URL exported)
#
# Required Environment Variables (exported by lib/start.sh):
#   - run_dir: this job's run/ directory (activate/, gitlab.env, launcher.exit)
#   - service_rundir, service_ssh_port, root_password_file, service_license_file
#   - runners_shell, runners_slurm, runners_demo_project, gitlab_runner_bin, jacamar_bin
#   - platform_host, oidc_client_id, oidc_client_secret_file, oidc_display_name,
#     oidc_block_new_users
################################################################################

# A failure here ends pw endpoints run with the endpoint already registered,
# which the start script cannot tell from the cancel that releases a healthy
# run: the exit file says which it was
fail() {
    echo "::error title=Error::$1"
    echo "${2:-1}" > "${run_dir}/launcher.exit"
    exit "${2:-1}"
}

gitlab_launcher_init() {
    rm -f "${run_dir}/launcher.exit"
    host="${PW_ENDPOINT_HOST}"
    if [ -z "${host}" ]; then
        host=$(printf '%s' "${PW_ENDPOINT_URL}" | sed -E 's#^https?://##; s#[/?].*$##')
    fi
    if [ -z "${host}" ]; then
        fail "pw endpoints run did not export the endpoint host (PW_ENDPOINT_HOST / PW_ENDPOINT_URL)"
    fi
    if [ -n "${PW_ENDPOINT_PATH%/}" ]; then
        fail "GitLab serves at the root of its address; the endpoint path ${PW_ENDPOINT_PATH} is not supported"
    fi
    public_url="https://${host}/"
    api="http://127.0.0.1:${PORT}/api/v4"

    # Two servers on one data directory would both start and corrupt it; the
    # lock is held on fd 9 for the life of the launcher, which therefore waits
    # for its foreground command instead of exec'ing into it (sudo closes
    # inherited fds)
    exec 9>"${service_rundir}/.lock"
    if ! flock -n 9; then
        fail "${service_rundir} is in use by another GitLab run; choose another run directory or stop that one first" 75
    fi
}

# The platform proxy forwards X-Forwarded-Proto: http, under which GitLab (an
# https external_url) redirects every page to itself and refuses to write its
# Secure session cookie, so the bundled nginx sets the forwarded headers
# itself. The same proxy also rewrites every redirect to another host onto
# the session's own host, which would send the browser to <this host>/api/
# oidc/authorize instead of the platform's sign-in: for the one route that
# redirects to the identity provider, nginx intercepts the 3xx and answers a
# 200 page that navigates there itself (redirects within this host are
# re-issued as they were). The directory is mounted into the config volume
# and its file included from the server block, so the host's user can rewrite
# it on every start although the volume belongs to the container.
#
# The run completes as soon as the platform's probe of /users/sign_in gets a
# 200, while the runners are registered after GitLab answers: until this
# launcher touches the ready marker that page answers 503 to everyone but
# this launcher's own probe, so a setup failure fails the run instead of
# leaving a completed run whose service the cleanup then removed
gitlab_write_nginx_snippet() {
    local host_re
    host_re=$(printf '%s' "${host}" | sed 's/[.]/\\./g')
    # nginx's workers (an unprivileged user in the container) test the marker,
    # so the directory stays readable whatever the umask here
    mkdir -p "${run_dir}/activate"
    chmod 755 "${run_dir}/activate"
    rm -f "${run_dir}/activate/ready"
    cat > "${run_dir}/activate/nginx.conf" <<NGINXEOF
location = /users/sign_in {
    set \$activate_gate 0;
    if (!-f /etc/gitlab/activate/ready) { set \$activate_gate 1; }
    if (\$http_x_activate_probe) { set \$activate_gate 0; }
    if (\$activate_gate = 1) { return 503; }
    proxy_pass http://gitlab-workhorse;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host_with_default;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Ssl on;
}
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
    chmod 644 "${run_dir}/activate/nginx.conf"
}

# gitlab_write_omnibus_config <nginx listen port> [more Ruby statements...]
# writes run/gitlab.env: GITLAB_OMNIBUS_CONFIG=<one Ruby line>, in the format
# of a docker --env-file. One line because that file takes no newlines; the
# Linux package evaluates it after gitlab.rb on every start. Secrets are read
# from their files here, so they stay out of the set -x trace
gitlab_write_omnibus_config() {
    local listen_port=$1
    shift
    set +x
    ruby_quote() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }
    local config=(
        "external_url 'https://${host}'"
        "nginx['listen_port'] = ${listen_port}"
        "nginx['listen_https'] = false"
        "nginx['proxy_set_headers'] = { 'Host' => '\$http_host_with_default', 'X-Real-IP' => '\$remote_addr', 'X-Forwarded-For' => '\$proxy_add_x_forwarded_for', 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on', 'Upgrade' => '\$http_upgrade', 'Connection' => '\$connection_upgrade' }"
        "nginx['custom_gitlab_server_config'] = 'include /etc/gitlab/activate/nginx.conf;'"
        "letsencrypt['enable'] = false"
        "prometheus_monitoring['enable'] = false"
        "puma['worker_processes'] = 2"
        "sidekiq['concurrency'] = 10"
        "gitlab_rails['gitlab_shell_ssh_port'] = ${service_ssh_port}"
        "$@"
    )
    if [ -s "${root_password_file}" ]; then
        config+=("gitlab_rails['initial_root_password'] = '$(ruby_quote "$(cat "${root_password_file}")")'")
    fi
    if [ -n "${oidc_client_id}" ]; then
        local issuer="https://${platform_host}/api/oidc" block_new_users=false
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
            local sep="" line
            for line in "${config[@]}"; do
                printf '%s%s' "${sep}" "${line}"
                sep="; "
            done
            printf '\n'
        } > "${run_dir}/gitlab.env"
    )
    set -x
}

# The first boot of a run directory runs the whole configuration (minutes);
# later boots only reconfigure and migrate. The endpoint is already listed
# (the host name had to be known before the container could start), so a boot
# that fails must end this launcher, with the container's log, well inside
# the wait job's budget. The sign-in page, probed without a forwarded protocol
# like the platform does, answers 200 only when the header fix is in place
# (302 to itself otherwise)
gitlab_wait_ready() {
    echo "Waiting for GitLab to answer on 127.0.0.1:${PORT}"
    local code="" i
    for i in $(seq 1 360); do
        if ! gitlab_alive; then
            gitlab_logs
            fail "The GitLab container exited during start-up (log above)"
        fi
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Host: ${host}" -H "X-Activate-Probe: 1" "http://127.0.0.1:${PORT}/users/sign_in")
        if [ "${code}" = "200" ]; then
            break
        fi
        if [ $((i % 12)) -eq 0 ]; then
            echo "GitLab is still starting ($((i * 5)) s, last status ${code:-none})"
        fi
        sleep 5
    done
    if [ "${code}" != "200" ]; then
        gitlab_logs
        fail "GitLab's sign-in page did not answer 200 within 30 minutes (last status: ${code:-none})"
    fi
    echo "::notice::GitLab is serving at ${public_url}"
}

# Everything after the boot goes through the API with a root token that lives
# for this launcher only; it is revoked at the end. The token never enters
# the trace
gitlab_setup() {
    set +x
    local admin_token
    admin_token=$(gitlab_exec gitlab-rails runner \
        "t = User.find_by_username('root').personal_access_tokens.create!(scopes: ['api', 'create_runner'], name: 'activate-workflow-${PW_RUN_SLUG}', expires_at: 1.day.from_now); puts t.token" 2>/dev/null | tail -n 1)
    if [ -z "${admin_token}" ]; then
        fail "Could not create a root API token in the container (gitlab-rails runner failed)"
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
        local marker="${service_rundir}/.license-$(sha256sum "${service_license_file}" | cut -c1-16)"
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

    # Each runner's authentication token is kept in the run directory, so a
    # later run finds its runners again; the configuration is rewritten on
    # every start because the GitLab port changes with the endpoint
    local runner_root="${service_rundir}/runner"
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
    local runners=""
    if [ "${runners_shell}" = "true" ]; then
        register_runner shell true || fail "The shell runner was not registered (above)"
        runners="${runners} shell"
    fi
    if [ "${runners_slurm}" = "true" ]; then
        register_runner slurm false || fail "The SLURM runner was not registered (above)"
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
                    # Plain jacamar (no jacamar-auth in front) refuses to run
                    # without --no-auth; every stage takes it
                    cat <<TOMLEOF
  [runners.custom]
    config_exec = "${jacamar_bin}"
    config_args = ["--no-auth", "config", "--configuration", "${runner_root}/jacamar.toml"]
    prepare_exec = "${jacamar_bin}"
    prepare_args = ["--no-auth", "prepare"]
    run_exec = "${jacamar_bin}"
    run_args = ["--no-auth", "run"]
    cleanup_exec = "${jacamar_bin}"
    cleanup_args = ["--no-auth", "cleanup", "--configuration", "${runner_root}/jacamar.toml"]
    graceful_kill_timeout = 600
    force_kill_timeout = 300
TOMLEOF
                fi
            } > "${runner_root}/config.toml"
        )
        if [ "${runners_slurm}" = "true" ]; then
            mkdir -p "${runner_root}/jacamar"
            chmod 700 "${runner_root}/jacamar"
            # Jacamar verifies the job's id token against GitLab's keys; fetched
            # through the public URL they come back as the platform's sign-in page
            cat > "${runner_root}/jacamar.toml" <<TOMLEOF
[general]
  executor = "slurm"
  data_dir = "${runner_root}/jacamar"
  gitlab_server = "http://127.0.0.1:${PORT}"
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
            fail "gitlab-runner exited right after starting (log above)"
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
            local project_id
            project_id=$(printf '%s' "${api_body}" | json_get id)
            if [ "${api_status}" != "201" ] || [ -z "${project_id}" ]; then
                echo "::warning::Could not create the hpc-ci-demo project (HTTP ${api_status}): ${api_body}"
            else
                # Jacamar reads the job's id token; without the default every
                # SLURM job would have to declare it
                local ci_yaml readme payload
                ci_yaml="default:
  id_tokens:
    CI_JOB_JWT:
      aud: \$CI_SERVER_URL

stages: [test]

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

    # Opens the sign-in page to the platform's probe: the run completes from here
    touch "${run_dir}/activate/ready"
    chmod 644 "${run_dir}/activate/ready"
}
