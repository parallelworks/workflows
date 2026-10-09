################################################################################
# Interactive Session Service Starter - PostgreSQL
#
# Purpose: Start PostgreSQL with Docker Compose, published on a host port, and
#          serve the pgweb SQL client for it behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - postgres_image, pgweb_image: Docker images
#   - postgres_user: superuser created with a new data directory
#   - postgres_db: optional, database to connect to (default: postgres_user)
#   - postgres_port: optional, host port the database listens on (default: 5432)
#   - postgres_data_dir: holds the database cluster in pgdata/
# Required files in PW_PARENT_JOB_DIR (written by preprocessing, mode 600):
#   - postgres-password: the superuser password
#   - pgpass: the same password in pgpass format, for pgweb
################################################################################

set -x

export postgres_port="${postgres_port:-5432}"
export postgres_db="${postgres_db:-${postgres_user}}"

for name in "${postgres_user}" "${postgres_db}"; do
    if ! [[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo "::error title=Error::Invalid user or database name '${name}': use letters, digits, '_', '.' and '-'"
        exit 1
    fi
done
if ! [ -s "${PW_PARENT_JOB_DIR}/postgres-password" ]; then
    echo "::error title=Error::A password is required"
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

export project_name="postgres_${PW_RUN_SLUG}"
export docker_cmd
# Both containers run as the workflow user: the database files belong to you,
# and the containers can read the mode-600 password files
export container_uid="$(id -u)"
export container_gid="$(id -g)"

# The compose stack is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to bring it down.
# --volumes only drops the image's anonymous volume: the data directory is a
# bind mount and stays.
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --volumes --remove-orphans
EOF
chmod +x cancel.sh

# Two servers on one data directory corrupt it, and PostgreSQL cannot tell: in
# a container every server is PID 1, so a second one takes the first one's
# postmaster.pid for a stale lock of its own. This script holds the lock for
# the life of the server.
exec {lock_fd}>>"${postgres_data_dir}/workflow.lock"
flock -n -E 75 "${lock_fd}"
lock_status=$?
if [ "${lock_status}" -eq 75 ]; then
    echo "::error title=Error::${postgres_data_dir} is in use by another PostgreSQL run ($(cat "${postgres_data_dir}/workflow.lock")). Stop that run's endpoint or choose another Data Directory."
    exit 1
elif [ "${lock_status}" -ne 0 ]; then
    echo "::warning::Could not lock ${postgres_data_dir}; nothing stops a second server from opening it"
fi
echo "run ${PW_RUN_SLUG} on $(hostname)" > "${postgres_data_dir}/workflow.lock"

if (exec 3<>"/dev/tcp/127.0.0.1/${postgres_port}") 2>/dev/null; then
    echo "::error title=Error::Port ${postgres_port} is already in use on $(hostname). Choose another Database Port."
    exit 1
fi

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the containers can actually start
if ! ${docker_cmd} pull "${postgres_image}" || ! ${docker_cmd} pull "${pgweb_image}"; then
    echo "::error title=Error::Could not pull ${postgres_image} or ${pgweb_image}"
    exit 1
fi
echo "::endgroup::"

echo "::group::Starting PostgreSQL"
# PGDATA is set explicitly: from version 18 the image's default lives under
# /var/lib/postgresql/<major>/docker, which would tie the data directory to
# one major version's layout
cat > docker-compose.yml <<EOF
services:
  postgres:
    image: ${postgres_image}
    user: "${container_uid}:${container_gid}"
    shm_size: 256m
    environment:
      PGDATA: /var/lib/postgresql/data/pgdata
      POSTGRES_USER: "${postgres_user}"
      POSTGRES_DB: "${postgres_db}"
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets:
      - postgres_password
    volumes:
      - ${postgres_data_dir}:/var/lib/postgresql/data
    ports:
      - "${postgres_port}:5432"
    healthcheck:
      test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "${postgres_user}", "-d", "postgres"]
      interval: 2s
      timeout: 5s
      retries: 5
      start_period: 10m
secrets:
  postgres_password:
    file: ${PW_PARENT_JOB_DIR}/postgres-password
EOF

if ! ${docker_cmd} compose -p "${project_name}" up -d --wait postgres; then
    ${docker_cmd} compose -p "${project_name}" logs --tail 50 postgres
    echo "::error title=Error::PostgreSQL did not start"
    exit 1
fi

# The image applies the user and password only when it initializes an empty
# data directory, so a reused one keeps those of the run that created it
if ! ${docker_cmd} compose -p "${project_name}" exec -T postgres sh -c \
    'PGPASSWORD="$(cat /run/secrets/postgres_password)" exec psql -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -v db="$POSTGRES_DB" -q' <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')\gexec
SQL
then
    echo "::error title=Error::Cannot log in to PostgreSQL as ${postgres_user} with the password given. ${postgres_data_dir} keeps the user and password of the run that created it: use those, or choose another Data Directory."
    exit 1
fi

postgres_host="$(hostname)"
cat > "${PW_PARENT_JOB_DIR}/postgres-connection.env" <<EOF
postgres_host=${postgres_host}
postgres_port=${postgres_port}
postgres_user=${postgres_user}
postgres_db=${postgres_db}
EOF
echo "::notice title=PostgreSQL::postgresql://${postgres_user}@${postgres_host}:${postgres_port}/${postgres_db}"
echo "::endgroup::"

echo "::group::Starting pgweb"

# pw endpoints run exports PORT to the wrapped command, so the launcher writes
# pgweb's compose file at runtime. pgweb has no login of its own, so it only
# listens on the loopback, where the endpoint reaches it. The foreground
# `compose logs -f` keeps the endpoint alive for the containers' life.
cat > launch-pgweb-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
cat > docker-compose.pgweb.yml <<COMPOSEEOF
services:
  pgweb:
    image: ${pgweb_image}
    user: "${container_uid}:${container_gid}"
    command:
      - --skip-open
      - --no-ssh
      - --host=postgres
      - --user=${postgres_user}
      - --db=${postgres_db}
      - --ssl=disable
      - --passfile=/run/secrets/pgpass
    secrets:
      - pgpass
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:${PORT}:8081"
secrets:
  pgpass:
    file: ${PW_PARENT_JOB_DIR}/pgpass
COMPOSEEOF

compose="${docker_cmd} compose -p ${project_name} -f docker-compose.yml -f docker-compose.pgweb.yml"
${compose} up -d --wait pgweb
${compose} ps
exec ${compose} logs -f
LAUNCHEOF
chmod +x launch-pgweb-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} --description "PostgreSQL ${postgres_host}:${postgres_port}" -- ./launch-pgweb-${PW_JOB_ID}.sh

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
