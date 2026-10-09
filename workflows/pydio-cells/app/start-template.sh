################################################################################
# Interactive Session Service Starter - Pydio Cells
#
# Purpose: Start Pydio Cells and its MySQL database with Docker Compose behind
#          a pw endpoint, installing Cells on the first start of a Run Directory
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - pydio_cells_image / pydio_mysql_image: Docker images
#   - pydio_rundir: holds mysql_data/ and cells_data/
#   - pydio_data_dir: the directory of the Data Directory workspace
#   - pydio_admin_password: the admin user's password, set on the first start
################################################################################

set -x

# Docker creates a missing bind-mount point as root, and the nested
# cells_data/data/user_files would make cells_data/data root's: Cells, running
# as the workflow user, then cannot create its datasources there
mkdir -p "${pydio_rundir}/mysql_data" "${pydio_rundir}/cells_data/data/user_files" "${pydio_data_dir}"

# Both containers run as the workflow user. A Run Directory from a run as root
# (the activate-pydio-cells workflow) is not writable by them
not_owned=$(find "${pydio_rundir}" -maxdepth 3 ! -user "$(id -u)" -print -quit)
if [ -n "${not_owned}" ]; then
    echo "::error title=Error::${not_owned} belongs to another user. Choose another Run Directory, or run: sudo chown -R $(id -un) ${pydio_rundir}"
    exit 1
fi

# MySQL answers on its container address to anyone on the host, so the
# database password is random. It only matters when mysql_data is initialized
if [ ! -s "${pydio_rundir}/.mysql.env" ]; then
    (
        umask 077
        {
            echo "MYSQL_DATABASE=cells"
            echo "MYSQL_USER=pydio"
            echo "MYSQL_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
            echo "MYSQL_RANDOM_ROOT_PASSWORD=yes"
        } > "${pydio_rundir}/.mysql.env"
    )
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

echo "::group::Image Pulls"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the containers can actually start
for image in "${pydio_mysql_image}" "${pydio_cells_image}"; do
    if ! ${docker_cmd} pull "${image}"; then
        echo "::error title=Error::Could not pull ${image}"
        exit 1
    fi
done
echo "::endgroup::"

export project_name="pydio_cells_${PW_RUN_SLUG}"
export docker_cmd
export container_uid="$(id -u)"
export container_gid="$(id -g)"

# The containers belong to the docker daemon, not the endpoint's process tree,
# so teardown needs cancel.sh (run by the cleanup trap) to bring them down
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --remove-orphans
rm -f ${PWD}/install-conf.yml
EOF
chmod +x cancel.sh

echo "::group::Starting Pydio Cells"

# pw endpoints run exports PORT and PW_ENDPOINT_URL to the wrapped command; the
# launcher writes the compose file at runtime because they are unknown before
# launch. Cells builds every URL of its web client relative to the root, which
# a subdomain endpoint serves; PW_ENDPOINT_URL only goes into the links Cells
# hands out (shares, emails). The foreground `compose logs -f cells` keeps the
# endpoint alive for the life of the Cells container.
cat > launch-pydio-cells-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
cat > docker-compose.yml <<COMPOSEEOF
services:
  mysql:
    image: ${pydio_mysql_image}
    user: "${container_uid}:${container_gid}"
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    env_file: ${pydio_rundir}/.mysql.env
    volumes:
      - ${pydio_rundir}/mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 60

  cells:
    image: ${pydio_cells_image}
    user: "${container_uid}:${container_gid}"
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      HOME: /var/cells
      CELLS_NO_TLS: "1"
      CELLS_SITE_BIND: "0.0.0.0:8080"
      CELLS_SITE_EXTERNAL: "${PW_ENDPOINT_URL%/}"
      CELLS_MINIO_ALLOW_CROSSMOUNT: "true"
    volumes:
      - ${pydio_rundir}/cells_data:/var/cells
      - ${pydio_data_dir}:/var/cells/data/user_files
    ports:
      - "127.0.0.1:${PORT}:8080"
COMPOSEEOF

dc() {
    ${docker_cmd} compose -p "${project_name}" "$@"
}

cells_installed() {
    dc run --rm --no-deps -T --entrypoint cells cells admin config check >/dev/null 2>&1
}

if ! dc up -d --wait mysql; then
    echo "::error title=Error::MySQL did not become healthy"
    exit 1
fi

if ! cells_installed; then
    echo "::notice::Installing Pydio Cells in ${pydio_rundir}"
    set +x
    q="'"
    admin_password_yaml=${pydio_admin_password//$q/$q$q}
    db_password=$(sed -n 's/^MYSQL_PASSWORD=//p' "${pydio_rundir}/.mysql.env")
    (
        umask 077
        cat > install-conf.yml <<INSTEOF
frontendlogin: admin
frontendpassword: '${admin_password_yaml}'
dbconnectiontype: tcp
dbtcphostname: mysql
dbtcpport: "3306"
dbtcpname: cells
dbtcpuser: pydio
dbtcppassword: '${db_password}'
INSTEOF
    )
    set -x
    # While Cells is not installed the image's entrypoint runs `cells configure`
    # instead of `cells start`, and it exits once the install is done. A restart
    # policy would do the same but loops forever on a failed install
    dc run --rm -T -v "${PWD}/install-conf.yml:/pydio/config/install.yml:ro" \
        -e CELLS_INSTALL_YAML=/pydio/config/install.yml cells
    rm -f install-conf.yml
    if ! cells_installed; then
        echo "::error title=Error::Pydio Cells installation failed"
        exit 1
    fi
fi

if ! dc up -d; then
    echo "::error title=Error::Could not start Pydio Cells"
    exit 1
fi
dc ps

for i in $(seq 1 120); do
    curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${PORT}/a/frontend/bootconf" && break
    sleep 2
done

# The Data Directory is mounted inside Cells' storage, but only a datasource
# and a workspace make it browsable. They are created once per Run Directory,
# so a workspace the admin later removes stays removed
create_data_workspace() {
    local api="http://127.0.0.1:${PORT}/a" password token auth code i
    local marker="${pydio_rundir}/cells_data/.data-workspace-created"
    [ -f "${marker}" ] && return
    password=${pydio_admin_password//\\/\\\\}
    password=${password//\"/\\\"}
    token=$(printf '{"AuthInfo":{"login":"admin","password":"%s","type":"credentials"}}' "${password}" \
        | curl -s -X POST "${api}/frontend/session" -H 'Content-Type: application/json' --data-binary @- \
        | sed -n 's/.*"JWT":[ ]*"\([^"]*\)".*/\1/p')
    if [ -z "${token}" ]; then
        echo "::warning::Could not sign in as admin with the form's password; the Data Directory workspace was not created"
        return
    fi
    auth="Authorization: Bearer ${token}"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "${auth}" "${api}/config/datasource/userfiles")
    if [ "${code}" = 404 ]; then
        curl -sf -o /dev/null -X POST -H "${auth}" -H 'Content-Type: application/json' \
            "${api}/config/datasource/userfiles" \
            -d '{"Name":"userfiles","StorageType":"LOCAL","StorageConfiguration":{"folder":"/var/cells/data/user_files","normalize":"false"},"FlatStorage":false,"EncryptionMode":"CLEAR","ObjectsBucket":"user_files"}' \
            || { echo "::warning::Could not create the userfiles datasource"; return; }
        # The datasource's services start asynchronously
        for i in $(seq 1 60); do
            curl -sf -o /dev/null -X POST -H "${auth}" -H 'Content-Type: application/json' \
                "${api}/tree/admin/list" -d '{"Node":{"Path":"userfiles"}}' && break
            sleep 2
        done
        curl -sf -o /dev/null -X PUT -H "${auth}" -H 'Content-Type: application/json' \
            "${api}/workspace/data-directory" \
            -d '{"Label":"Data Directory","Description":"The Data Directory on the service host","Slug":"data-directory","Scope":"ADMIN","Attributes":"{\"DEFAULT_RIGHTS\":\"rw\"}","RootNodes":{"DATASOURCE:userfiles":{"Uuid":"DATASOURCE:userfiles","Path":"userfiles"}}}' \
            || { echo "::warning::Could not create the Data Directory workspace"; return; }
        echo "::notice::Created the Data Directory workspace"
    elif [ "${code}" != 200 ]; then
        echo "::warning::Could not check the userfiles datasource (HTTP ${code})"
        return
    fi
    touch "${marker}"
}
set +x
create_data_workspace
set -x

exec ${docker_cmd} compose -p "${project_name}" logs -f cells
LAUNCHEOF
chmod +x launch-pydio-cells-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-pydio-cells-${PW_JOB_ID}.sh

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
