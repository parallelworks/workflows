################################################################################
# Interactive Session Service Starter - OpenProject (Singularity)
#
# Purpose: Run OpenProject from one SIF as the workflow user, no root and no
#          Docker daemon: PostgreSQL 17, the seeder, puma, the good_job worker
#          and nginx (which sets X-Forwarded-Proto for the app) behind a pw
#          endpoint on a pinned subdomain, with ACTIVATE seeded as an OpenID
#          Connect provider when the form carries an OIDC client
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: where containers/openproject.sif lives
#   - service_rundir: pgdata/, assets/, tmp/, log/, files/, run/, nginx/, secrets
#   - service_subdomain: subdomain label of the URL (default openproject-<PW_USER>)
#   - service_admin_password: optional; seeds the admin user of a new run directory
#   - service_enterprise_token_file: optional; an OpenProject Enterprise token to import
#   - oidc_client_id, oidc_client_secret, oidc_display_name: optional ACTIVATE OIDC client
################################################################################

set -x

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/openproject
fi
service_rundir=$(realpath -m "${service_rundir}")
if [ -z "${oidc_display_name}" ]; then
    oidc_display_name=ACTIVATE
fi
container_sif=${service_parent_install_dir}/containers/openproject.sif
sandbox_dir=${service_parent_install_dir}/containers/openproject-sandbox

mkdir -p "${service_rundir}"/{pgdata,assets,tmp,log,files,run,nginx}
chmod 700 "${service_rundir}/pgdata"

# Load singularity/apptainer if not already in PATH
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
fi
for tool in openssl curl flock python3; do
    if ! command -v ${tool} >/dev/null 2>&1; then
        echo "::error title=Error::${tool} is not installed on $(hostname)"
        exit 1
    fi
done
if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi

export service_rundir
export env_file="${PWD}/openproject-${PW_JOB_ID}.env"

# Each service runs in its own process group (setsid), detached from the
# endpoint's process tree, so teardown needs cancel.sh (run by the cleanup
# trap) to signal the groups: TERM for nginx, the worker and puma, INT (fast
# shutdown) for PostgreSQL. Signalling the group, not the container starter,
# is what reaches the process inside the container when the starter has
# already exited (the good_job worker outlived a TERM to its starter)
cat > cancel.sh <<CANCELEOF
#!/bin/bash
run_dir="${service_rundir}/run"
for svc in nginx worker web; do
    pid=\$(cat "\${run_dir}/\${svc}.pid" 2>/dev/null) && kill -TERM -- "-\${pid}" 2>/dev/null
done
pid=\$(cat "\${run_dir}/postgres.pid" 2>/dev/null) && kill -INT -- "-\${pid}" 2>/dev/null
for i in \$(seq 1 30); do
    alive=0
    for svc in nginx worker web postgres; do
        pid=\$(cat "\${run_dir}/\${svc}.pid" 2>/dev/null) && kill -0 -- "-\${pid}" 2>/dev/null && alive=1
    done
    [ "\${alive}" = 0 ] && break
    sleep 1
done
for svc in nginx worker web postgres; do
    pid=\$(cat "\${run_dir}/\${svc}.pid" 2>/dev/null) && kill -KILL -- "-\${pid}" 2>/dev/null
done
rm -f "\${run_dir}"/*.pid ${env_file}
CANCELEOF
chmod +x cancel.sh

# A run directory another OpenProject run holds is refused later by the lock;
# stale PID files from a killed run are cleaned up here
for svc in nginx worker web postgres; do
    pid=$(cat "${service_rundir}/run/${svc}.pid" 2>/dev/null)
    if [ -n "${pid}" ] && ! kill -0 -- "-${pid}" 2>/dev/null; then
        rm -f "${service_rundir}/run/${svc}.pid"
    fi
done

# Host environments (module paths, LD_LIBRARY_PATH on HPC) must not leak into
# the container; the app's environment comes from the image and the env file
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Prefer running the SIF directly; some nodes cannot mount it (no squashfs
# kernel/FUSE support), in which case unpack it once into a sandbox directory
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    echo "::notice::SIF image is runnable on this node"
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; using sandbox directory"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi
export container_ref

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

# Rails refuses a default or weak SECRET_KEY_BASE and sessions and encrypted
# settings depend on it; the database password only matters to this host's
# loopback. Both are generated once and kept with the data
(
    umask 077
    if [ ! -s "${service_rundir}/.secret_key_base" ]; then
        openssl rand -hex 64 > "${service_rundir}/.secret_key_base"
    fi
    if [ ! -s "${service_rundir}/.pgpassword" ]; then
        openssl rand -hex 24 > "${service_rundir}/.pgpassword"
    fi
)

platform_host=${PW_PLATFORM_HOST#https://}
platform_host=${platform_host#http://}
platform_host=${platform_host%%/*}
if [ -n "${oidc_client_id}" ] && [ -z "${platform_host}" ]; then
    echo "::error title=Error::PW_PLATFORM_HOST is empty; the OIDC issuer URL cannot be built"
    exit 1
fi
export service_subdomain platform_host oidc_display_name

echo "::group::Starting OpenProject"

# pw endpoints run exports PORT, PW_ENDPOINT_HOST, PW_ENDPOINT_PATH and
# PW_ENDPOINT_URL to the wrapped command; the launcher writes the app's
# environment at runtime because OpenProject must know its public host name
# (absolute URLs, the OIDC redirect URI) before it starts. nginx on the endpoint
# port is the launcher's foreground process: its exit ends the endpoint, and
# cancel.sh stops the rest.
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
run_dir="${service_rundir}/run"
log_dir="${service_rundir}/log"

# Two servers on one pgdata would both start and corrupt it; the lock is held
# for the life of this launcher
exec 9>"${service_rundir}/.lock"
if ! flock -n 9; then
    echo "::error title=Error::${service_rundir} is in use by another OpenProject run; choose another run directory or stop that one first"
    exit 75
fi

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
pg_port=$(free_port)
web_port=$(free_port)
pg_password=$(cat "${service_rundir}/.pgpassword")

# Apptainer evaluates --env-file like a shell script, so every value is
# single-quoted (a space in the OIDC scope aborted every container start)
envline() {
    printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}
set +x
(
    umask 077
    {
        envline DATABASE_URL "postgres://openproject:${pg_password}@127.0.0.1:${pg_port}/openproject"
        envline SECRET_KEY_BASE "$(cat "${service_rundir}/.secret_key_base")"
        envline OPENPROJECT_HOST__NAME "${host}"
        envline OPENPROJECT_HTTPS "true"
        envline OPENPROJECT_DEFAULT__LANGUAGE "en"
        envline OPENPROJECT_RAILS__CACHE__STORE "file_store"
        if [ -n "${base_path}" ]; then
            envline OPENPROJECT_RAILS__RELATIVE__URL__ROOT "${base_path}"
        fi
        if [ -n "${service_admin_password}" ]; then
            envline OPENPROJECT_SEED_ADMIN_USER_PASSWORD "${service_admin_password}"
            envline OPENPROJECT_SEED_ADMIN_USER_PASSWORD_RESET "false"
        fi
        if [ -n "${oidc_client_id}" ]; then
            # Applied by the seeder on every boot; the provider's slug is the first
            # word after OPENID__CONNECT_, and the redirect URI OpenProject uses is
            # <public URL>/auth/<slug>/callback
            issuer="https://${platform_host}/api/oidc"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_DISPLAY__NAME "${oidc_display_name}"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_IDENTIFIER "${oidc_client_id}"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_SECRET "${oidc_client_secret}"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_ISSUER "${issuer}"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_AUTHORIZATION__ENDPOINT "${issuer}/authorize"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_TOKEN__ENDPOINT "${issuer}/token"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_USERINFO__ENDPOINT "${issuer}/userinfo"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_END__SESSION__ENDPOINT "${issuer}/end_session"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_JWKS__URI "https://${platform_host}/api/platform/keys"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_POST__LOGOUT__REDIRECT__URI "${public_url}"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_SCOPE "openid profile email"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_ATTRIBUTE__MAP_LOGIN "preferred_username"
            envline OPENPROJECT_OPENID__CONNECT_ACTIVATE_ATTRIBUTE__MAP_EMAIL "email"
        fi
    } > "${env_file}"
    printf '127.0.0.1:%s:*:openproject:%s\n' "${pg_port}" "${pg_password}" > "${service_rundir}/.pgpass"
)
set -x

# One option list for every container process: the image's read-only paths
# the app writes to are bound from the run directory, the host environment is
# dropped, the app's comes from the env file (a later --env overrides it)
container_args=(
    --cleanenv --writable-tmpfs
    --bind "${service_rundir}"
    --bind "${service_rundir}/tmp:/app/tmp"
    --bind "${service_rundir}/log:/app/log"
    --bind "${service_rundir}/files:/app/files"
    --bind "${service_rundir}/assets:/var/openproject/assets"
    --env-file "${env_file}"
    --env PGPASSFILE="${service_rundir}/.pgpass"
    --pwd /app
)
# Background services are started as plain commands (nohup cannot run a shell
# function), each as the leader of its own process group, so the PID file holds
# a PGID that cancel.sh can signal as a whole
start_bg() {
    local name=$1
    shift
    setsid nohup "$@" > "${log_dir}/${name}.log" 2>&1 < /dev/null &
    echo $! > "${run_dir}/${name}.pid"
}
pg() {
    local tool=$1
    shift
    singularity exec "${container_args[@]}" "${container_ref}" "/usr/lib/postgresql/17/bin/${tool}" "$@"
}

if [ ! -f "${service_rundir}/pgdata/PG_VERSION" ]; then
    echo "::notice::Initializing PostgreSQL in ${service_rundir}/pgdata"
    if ! pg initdb -D "${service_rundir}/pgdata" -U openproject --encoding=UTF8 --locale=C.UTF-8 \
            --auth-host=scram-sha-256 --auth-local=trust --pwfile="${service_rundir}/.pgpassword"; then
        echo "::error title=Error::initdb failed"
        exit 1
    fi
fi
# A killed server leaves postmaster.pid behind, which makes the next one start
# in crash recovery; the lock above guarantees no live server holds it
rm -f "${service_rundir}/pgdata/postmaster.pid"
start_bg postgres singularity exec "${container_args[@]}" "${container_ref}" /usr/lib/postgresql/17/bin/postgres \
    -D "${service_rundir}/pgdata" -p "${pg_port}" \
    -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp
for i in $(seq 1 60); do
    pg pg_isready -h 127.0.0.1 -p "${pg_port}" >/dev/null 2>&1 && break
    sleep 1
done
if ! pg pg_isready -h 127.0.0.1 -p "${pg_port}"; then
    tail -n 30 "${log_dir}/postgres.log"
    echo "::error title=Error::PostgreSQL did not start (log above)"
    exit 1
fi
if ! pg psql -h 127.0.0.1 -p "${pg_port}" -U openproject -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = 'openproject'" | grep -q 1; then
    pg createdb -h 127.0.0.1 -p "${pg_port}" -U openproject openproject || exit 1
fi

# Schema load or migrations, then db:seed, which also creates or updates the
# OpenID Connect provider from the env file. Fail here, with the log, rather
# than start a web server on a half-migrated database
echo "::notice::Migrating and seeding the database"
if ! singularity exec "${container_args[@]}" "${container_ref}" ./docker/prod/seeder > "${log_dir}/seeder.log" 2>&1; then
    tail -n 60 "${log_dir}/seeder.log"
    echo "::error title=Error::The OpenProject seeder failed (log above)"
    exit 1
fi
grep -i 'OpenID provider' "${log_dir}/seeder.log" || true

start_bg web singularity exec "${container_args[@]}" --env PORT="${web_port}" --env BIND=127.0.0.1 "${container_ref}" ./docker/prod/web
start_bg worker singularity exec "${container_args[@]}" "${container_ref}" ./docker/prod/worker

# nginx in front of puma sets X-Forwarded-Proto: the platform proxy forwards
# http, under which OpenProject's HTTPS mode redirects every page to itself and
# drops its Secure session cookie. Every path nginx writes is in the run
# directory, so it runs unprivileged
nginx_dir="${service_rundir}/nginx"
mkdir -p "${nginx_dir}"/{body,proxy,fastcgi,uwsgi,scgi}
# nginx's own pid file stays out of run/, where nginx.pid holds the process group
cat > "${nginx_dir}/nginx.conf" <<NGINXEOF
pid ${nginx_dir}/nginx-master.pid;
error_log ${log_dir}/nginx-error.log warn;
worker_processes 2;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    access_log ${log_dir}/nginx-access.log;
    client_body_temp_path ${nginx_dir}/body;
    proxy_temp_path ${nginx_dir}/proxy;
    fastcgi_temp_path ${nginx_dir}/fastcgi;
    uwsgi_temp_path ${nginx_dir}/uwsgi;
    scgi_temp_path ${nginx_dir}/scgi;
    client_max_body_size 0;
    server_tokens off;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    server {
        listen 127.0.0.1:${PORT};
        location ${base_path:-/} {
            proxy_pass http://127.0.0.1:${web_port};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 600s;
        }
    }
}
NGINXEOF
start_bg nginx singularity exec "${container_args[@]}" "${container_ref}" nginx -p "${nginx_dir}" -c "${nginx_dir}/nginx.conf" -g 'daemon off;'
nginx_pid=$(cat "${run_dir}/nginx.pid")

# The login page, probed through nginx without a forwarded protocol like the
# platform does, answers 200 only once puma serves and the header fix works
echo "Waiting for OpenProject to answer on 127.0.0.1:${PORT}"
code=""
for i in $(seq 1 180); do
    for svc in postgres web nginx; do
        pid=$(cat "${run_dir}/${svc}.pid" 2>/dev/null)
        if [ -z "${pid}" ] || ! kill -0 -- "-${pid}" 2>/dev/null; then
            tail -n 40 "${log_dir}/${svc}.log"
            echo "::error title=Error::${svc} exited during start-up (log above)"
            exit 1
        fi
    done
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Host: ${host}" "http://127.0.0.1:${PORT}${base_path}/login")
    if [ "${code}" = "200" ]; then
        break
    fi
    sleep 5
done
if [ "${code}" != "200" ]; then
    tail -n 40 "${log_dir}/web.log"
    echo "::error title=Error::OpenProject's login page did not answer 200 within 15 minutes (last status: ${code:-none})"
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
    elif singularity exec "${container_args[@]}" --bind "$(dirname "${service_enterprise_token_file}")" "${container_ref}" \
            bundle exec ruby script/import_enterprise_token "${service_enterprise_token_file}"; then
        touch "${marker}"
    else
        echo "::warning::The Enterprise token was not imported (output above); Sign in with ACTIVATE stays hidden until OpenProject has an active Enterprise token"
    fi
fi

wait "${nginx_pid}"
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
