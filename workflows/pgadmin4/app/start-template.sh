################################################################################
# Interactive Session Service Starter - pgAdmin 4
#
# Purpose: Start pgAdmin 4 (dpage/pgadmin4) with Docker Compose on a loopback
#          port, check that the account logs in, then publish that port as a
#          pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - pgadmin_image: Docker image
#   - pgadmin_email: the account's email (PGADMIN_DEFAULT_EMAIL)
#   - pgadmin_data_dir: holds pgadmin4.db (account, servers, preferences),
#     sessions/ and storage/ (the account's files: backups, exports)
#   - pgadmin_server_host: optional, a PostgreSQL server registered when the
#     data directory is new, with pgadmin_server_port (5432),
#     pgadmin_server_db (postgres) and pgadmin_server_user (postgres)
# Required files in PW_PARENT_JOB_DIR (written by preprocessing, mode 600):
#   - pgadmin-password: the account's password
################################################################################

set -x

# The email lands in the compose file and in the account; pgAdmin rejects
# special-use domains (.local, .test, localhost) when it creates the account
if ! [[ "${pgadmin_email:-}" =~ ^[^[:space:]\"\'\\]+@[^[:space:]\"\'\\]+$ ]]; then
    echo "::error title=Error::Invalid email '${pgadmin_email:-}'"
    exit 1
fi
if ! [ -s "${PW_PARENT_JOB_DIR}/pgadmin-password" ]; then
    echo "::error title=Error::A password is required"
    exit 1
fi
mkdir -p "${pgadmin_data_dir}"

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

export project_name="pgadmin4_${PW_RUN_SLUG}"

# The compose stack is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to bring it down
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --remove-orphans
EOF
chmod +x cancel.sh

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the container can actually start
if ! ${docker_cmd} pull "${pgadmin_image}"; then
    echo "::error title=Error::Could not pull ${pgadmin_image}"
    exit 1
fi
echo "::endgroup::"

# The image applies PGADMIN_SERVER_JSON_FILE only when it initializes an empty
# data directory, together with the account
servers_secret=""
if [ -n "${pgadmin_server_host:-}" ]; then
    pgadmin_server_port="${pgadmin_server_port:-5432}"
    pgadmin_server_db="${pgadmin_server_db:-postgres}"
    pgadmin_server_user="${pgadmin_server_user:-postgres}"
    for value in "${pgadmin_server_host}" "${pgadmin_server_db}" "${pgadmin_server_user}"; do
        if ! [[ "${value}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
            echo "::error title=Error::Invalid server host, database or user '${value}': use letters, digits, '_', '.' and '-'"
            exit 1
        fi
    done
    if ! [[ "${pgadmin_server_port}" =~ ^[0-9]+$ ]]; then
        echo "::error title=Error::Invalid server port '${pgadmin_server_port}'"
        exit 1
    fi
    cat > servers.json <<EOF
{
  "Servers": {
    "1": {
      "Name": "${pgadmin_server_user}@${pgadmin_server_host}:${pgadmin_server_port}",
      "Group": "Servers",
      "Host": "${pgadmin_server_host}",
      "Port": ${pgadmin_server_port},
      "MaintenanceDB": "${pgadmin_server_db}",
      "Username": "${pgadmin_server_user}",
      "SSLMode": "prefer"
    }
  }
}
EOF
    servers_secret="servers"
fi

# The port is chosen here instead of by pw endpoints run, so the account can be
# checked before the endpoint registers: once it is registered, the workflow's
# health probe sees the service answer and completes the run
find_free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null && return
    local port
    for _ in $(seq 1 50); do
        port=$(( 20000 + RANDOM % 40000 ))
        if ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
            echo "${port}"
            return
        fi
    done
    return 1
}
pgadmin_port=$(find_free_port)
if [ -z "${pgadmin_port}" ]; then
    echo "::error title=Error::Could not find a free port on $(hostname)"
    exit 1
fi

echo "::group::Starting pgAdmin 4"
# The container runs as the workflow user with the image's root group: the
# image is built for arbitrary uids in group 0 (OpenShift), so it can read the
# mode-600 password file and the data directory's files belong to you. pgAdmin
# has its own login, but nothing outside the node needs the port, so it is
# published on the loopback only, where the endpoint reaches it.
cat > docker-compose.yml <<EOF
services:
  pgadmin4:
    image: ${pgadmin_image}
    user: "$(id -u):0"
    environment:
      PGADMIN_DEFAULT_EMAIL: "${pgadmin_email}"
      PGADMIN_DEFAULT_PASSWORD_FILE: /run/secrets/pgadmin_password
      PGADMIN_SERVER_JSON_FILE: /run/secrets/servers
      PGADMIN_LISTEN_PORT: "5050"
      PGADMIN_DISABLE_POSTFIX: "true"
    secrets:
      - pgadmin_password
      ${servers_secret:+- ${servers_secret}}
    volumes:
      - ${pgadmin_data_dir}:/var/lib/pgadmin
    ports:
      - "127.0.0.1:${pgadmin_port}:5050"
secrets:
  pgadmin_password:
    file: ${PW_PARENT_JOB_DIR}/pgadmin-password
  ${servers_secret:+${servers_secret}:}
    ${servers_secret:+file: ./servers.json}
EOF

if ! ${docker_cmd} compose -p "${project_name}" up -d; then
    echo "::error title=Error::pgAdmin 4 did not start"
    exit 1
fi

# The first launch of a data directory creates the account before gunicorn
# listens (about 35 s on gcpsmall); a container that exited is reported with
# its log, where the image explains a rejected email or password
url="http://127.0.0.1:${pgadmin_port}"
for i in $(seq 1 90); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "${url}/misc/ping")" = "200" ]; then
        break
    fi
    if [ "$(${docker_cmd} compose -p "${project_name}" ps --status running -q | wc -l)" -eq 0 ]; then
        ${docker_cmd} compose -p "${project_name}" logs --tail 30 --no-log-prefix
        echo "::error title=Error::pgAdmin 4 exited while starting (see its log above)"
        exit 1
    fi
    sleep 2
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' "${url}/misc/ping")" != "200" ]; then
    ${docker_cmd} compose -p "${project_name}" logs --tail 30 --no-log-prefix
    echo "::error title=Error::pgAdmin 4 did not answer within 3 minutes"
    exit 1
fi
echo "::endgroup::"

echo "::group::Checking the login"
# The image creates the account only when it initializes an empty data
# directory, so a reused one keeps the email and password of the run that
# created it; a changed password only shows up as a failed login. The login
# page carries its CSRF token as the JSON value "csrfToken"; a successful login
# redirects to /browser/, a failed one back to /login.
cookies="cookies-${PW_JOB_ID}.txt"
rm -f "${cookies}"
csrf_token=$(curl -s -c "${cookies}" "${url}/login" | grep -o '"csrfToken": *"[^"]*"' | sed 's/.*: *"//; s/"$//')
login_status=$(curl -s -b "${cookies}" -c "${cookies}" -o /dev/null -w '%{http_code}' -X POST "${url}/authenticate/login" \
    --data-urlencode "email=${pgadmin_email}" \
    --data-urlencode "password@${PW_PARENT_JOB_DIR}/pgadmin-password" \
    --data-urlencode "csrf_token=${csrf_token}")
browser_status=$(curl -s -b "${cookies}" -o /dev/null -w '%{http_code}' "${url}/browser/")
rm -f "${cookies}"
if [ "${browser_status}" != "200" ]; then
    echo "login: HTTP ${login_status}, /browser/: HTTP ${browser_status}"
    echo "::error title=Error::Cannot log in to pgAdmin 4 as ${pgadmin_email} with the password given. ${pgadmin_data_dir} keeps the account of the run that created it: use that email and password, or choose another Data Directory."
    exit 1
fi
echo "::notice::Logged in as ${pgadmin_email}"
echo "::endgroup::"

echo "::group::Registering the endpoint"
# The foreground `compose logs -f` keeps the endpoint alive for the container's life
pw endpoints run ${pw_endpoints_args} --port "${pgadmin_port}" --description "pgAdmin 4 on $(hostname)" -- ${docker_cmd} compose -p "${project_name}" logs -f --no-log-prefix

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
