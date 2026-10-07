################################################################################
# Interactive Session Service Starter - MLflow
#
# Purpose: Serve an MLflow tracking server (UI + REST API) through a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Installation directory
#   - service_conda_install: Whether conda was installed by the controller
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_load_env: Command to load mlflow (when conda_install=false)
#   - service_backend_store_uri: experiments, runs, metrics and parameters store
#       (default: sqlite:///${HOME}/mlflow/mlflow.db)
#   - service_artifacts_destination: where the server stores the artifacts it proxies
#       (default: ${HOME}/mlflow/artifacts)
#   - service_port: port to listen on (optional; a free one is taken otherwise)
#   - service_additional_flags: extra mlflow server flags (optional)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [[ "${service_conda_install}" == "true" ]] && [ -z "${service_load_env}" ]; then
    service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi
eval "${service_load_env}"

if ! command -v mlflow > /dev/null 2>&1; then
    echo "::error title=Error::mlflow command not found"
    exit 1
fi

backend_store_uri=${service_backend_store_uri:-sqlite:///${HOME}/mlflow/mlflow.db}
artifacts_destination=${service_artifacts_destination:-${HOME}/mlflow/artifacts}

# Prints the filesystem path behind a local store; fails for any other scheme
# (postgresql://, s3://, ...), which mlflow handles itself
f_local_path() {
    case "$1" in
        sqlite:///*) printf '%s' "${1#sqlite:///}" ;;
        file://*) printf '%s' "${1#file://}" ;;
        *:*) return 1 ;;
        *) printf '%s' "$1" ;;
    esac
}

# sqlite needs the database's directory to exist; a bare path is mlflow's file
# store, a directory of its own
if store_path=$(f_local_path "${backend_store_uri}"); then
    case "${backend_store_uri}" in
        sqlite:*) mkdir -p "$(dirname "${store_path}")" ;;
        *) mkdir -p "${store_path}" ;;
    esac
fi
if artifacts_path=$(f_local_path "${artifacts_destination}"); then
    mkdir -p "${artifacts_path}"
fi

endpoint_port_args=""
if [ -n "${service_port}" ]; then
    endpoint_port_args="--port ${service_port}"
fi

# pw endpoints run exports PORT and PW_ENDPOINT_HOST to the wrapped command, so the
# launcher composes what only exists at runtime. The server binds every interface
# because jobs on the cluster log to it directly while the endpoint serves it
# outside; the in-cluster address goes to the job directory for them. MLflow 3
# answers 403 to any Host header outside its allow-list (localhost and private IPs
# by default: the endpoint host and the node's own name are not) and to the UI's
# POSTs when their Origin is not allow-listed, so both lists name the endpoint and
# every name of this node.
tracking_uri_file=${PW_PARENT_JOB_DIR:-${PWD}}/tracking_uri
cat > launch-mlflow-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
node_fqdn=\$(hostname -f 2>/dev/null || hostname)
allowed_hosts="localhost,localhost:*,127.0.0.1,127.0.0.1:*"
cors_origins=""
for h in \${node_fqdn} \$(hostname -s 2>/dev/null) \$(hostname -I 2>/dev/null); do
    allowed_hosts="\${allowed_hosts},\${h},\${h}:*"
    cors_origins="\${cors_origins},http://\${h}:*"
done
if [ -n "\${PW_ENDPOINT_HOST}" ]; then
    allowed_hosts="\${allowed_hosts},\${PW_ENDPOINT_HOST}"
    cors_origins="https://\${PW_ENDPOINT_HOST}\${cors_origins}"
else
    echo "::warning::pw endpoints run did not export the endpoint host; accepting every Host header and Origin"
    allowed_hosts="*"
    cors_origins="*"
fi
tracking_uri="http://\${node_fqdn}:\${PORT}"
echo "\${tracking_uri}" > "${tracking_uri_file}"
echo "::notice title=Tracking URI::In-cluster MLflow tracking URI \${tracking_uri} (also in ${tracking_uri_file})"
exec mlflow server --host 0.0.0.0 --port "\${PORT}" \\
    --backend-store-uri "${backend_store_uri}" \\
    --artifacts-destination "${artifacts_destination}" \\
    --serve-artifacts \\
    --allowed-hosts "\${allowed_hosts}" \\
    --cors-allowed-origins "\${cors_origins#,}" ${service_additional_flags}
EOF
chmod +x launch-mlflow-${PW_JOB_ID}.sh

echo "::group::Start Service"
echo "::notice::Starting $(mlflow --version 2>/dev/null) at $(command -v mlflow): pw endpoints run ${endpoint_port_args} ${pw_endpoints_args} -- ./launch-mlflow-${PW_JOB_ID}.sh"
echo "::notice::Backend store ${backend_store_uri}; artifacts destination ${artifacts_destination}"

set -x
pw endpoints run ${endpoint_port_args} ${pw_endpoints_args} -- ./launch-mlflow-${PW_JOB_ID}.sh

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
