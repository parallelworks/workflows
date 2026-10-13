################################################################################
# Interactive Session Service Starter - HPC Status Monitor
#
# Purpose: Serve the fleet dashboard behind a pw endpoint at a stable address
# Runs on: Controller (login) node or the user workspace
# Called by: Workflow after controller setup, through script_submitter
#
# Required Environment Variables (from inputs.sh):
#   - pw_endpoints_args: Arguments for pw endpoints run (--name <endpoint name>);
#     endpoints named <endpoint name> or <endpoint name>-* are this dashboard's
#   - service_parent_install_dir: Parent directory of the installation
#   - service_platform: auto, generic, hpcmp or noaa - the configuration to load
#   - service_subdomain: Public hostname label (optional, default status-<PW_USER>)
#   - service_local_port: Port to bind instead of the one pw endpoints run picks (optional)
#   - service_detach: false when the dashboard stops with its run (optional, default true)
#   - service_theme, service_enable_cluster_pages, service_enable_cluster_monitor,
#     service_cluster_monitor_interval, service_sweep_concurrency: dashboard settings
#   - service_pw_context: Identity every pw call is pinned to (optional)
#   - PW_PARENT_JOB_DIR: Run directory (holds the checked-out app/)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

app_dir="${PW_PARENT_JOB_DIR}/workflows/hpc_status/app"
python="${service_parent_install_dir}/hpc_status/venv/bin/python"

if [ ! -x "${python}" ]; then
    echo "::error title=Error::Dashboard environment not found at ${python}"
    exit 1
fi
if [ ! -f "${app_dir}/src/server/main.py" ]; then
    echo "::error title=Error::The dashboard sources are missing from ${app_dir}"
    exit 1
fi

served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
if [ -z "${served_name}" ]; then
    echo "::error title=Error::pw_endpoints_args must name the endpoint: ${pw_endpoints_args}"
    exit 1
fi

# Only pin a port when asked: the one pw endpoints run picks is free, and 8080 is
# Grafana on an ACTIVATE workspace
if [[ "${service_local_port}" =~ ^[1-9][0-9]*$ ]]; then
    pw_endpoints_args="${pw_endpoints_args} --port ${service_local_port}"
fi

# A ${{ }} expression cannot look at the host it runs on, so auto is resolved here: a
# listing registered on a DoD or NOAA platform comes up with that platform's fleet
case "${service_platform:-auto}" in
    hpcmp) config_file="configs/config.hpcmp.yaml" ;;
    noaa) config_file="configs/config.noaa.yaml" ;;
    generic) config_file="configs/config.yaml" ;;
    *)
        case "${PW_PLATFORM_HOST:-}" in
            *hpc.mil*|*hpcmp*) config_file="configs/config.hpcmp.yaml" ;;
            *noaa*|*rdhpcs*) config_file="configs/config.noaa.yaml" ;;
            *) config_file="configs/config.yaml" ;;
        esac
        ;;
esac
echo "::notice::Platform ${PW_PLATFORM_HOST:-unknown}, configuration ${config_file}"

if [ -n "${service_pw_context}" ] && [ "${service_pw_context}" != "undefined" ]; then
    export PW_CONTEXT="${service_pw_context}"
fi

if ! pw auth whoami >/dev/null 2>&1; then
    echo "::error title=Error::The pw CLI on $(hostname) is not authenticated; the dashboard can neither publish nor collect"
    exit 1
fi

# The run's own PW_API_KEY is revoked when the run completes, but the dashboard keeps
# calling pw for as long as it serves: on that key it would go on listing the fleet
# while every probe failed. Hand the dashboard (and the tunnel) a credential that
# outlives the run. The user workspace carries its own key in the platform's profile
# script; take only that variable from it, and only if it works. Saved credentials
# (pw auth on this host) outlive everything and win when they authenticate here -
# PW_PLATFORM_HOST from inputs.sh keeps them from answering for another platform.
# No set -x in this block: it would print the keys.
durable=""
pw_env_file="${PW_ENV_FILE:-/etc/profile.d/parallelworks-env.sh}"
if [ -r "${pw_env_file}" ]; then
    workspace_key="$(
        set +u
        . "${pw_env_file}" >/dev/null 2>&1
        printf '%s' "${PW_API_KEY:-}"
    )"
    if [ -n "${workspace_key}" ] && [ "${workspace_key}" != "${PW_API_KEY:-}" ] \
        && PW_API_KEY="${workspace_key}" pw auth whoami >/dev/null 2>&1; then
        export PW_API_KEY="${workspace_key}"
        durable="the workspace key from ${pw_env_file}"
    fi
    unset workspace_key
fi
# Without a key in the environment (scripts/serve-endpoint.sh by hand) the check above
# already passed on saved credentials
if [ -z "${PW_API_KEY:-}" ] || env -u PW_API_KEY pw auth whoami >/dev/null 2>&1; then
    unset PW_API_KEY
    durable="the saved pw credentials on $(hostname)"
fi
if [ -n "${durable}" ]; then
    echo "::notice::The dashboard authenticates with ${durable}, which outlives this run"
elif [ "${service_detach}" = "false" ]; then
    echo "::notice::The dashboard authenticates with this run's key, which lasts as long as the run stays open"
else
    echo "::warning title=Credentials::Only this run's key authenticates pw on $(hostname), and it is revoked when the run completes: the dashboard will keep serving but stop collecting. Run 'pw auth' on this host, or run the dashboard on the user workspace"
fi

# One dashboard per user at one address, the same every run: without a subdomain the
# platform assigns a random one per session and the dashboard moves between runs
if [ -z "${service_subdomain}" ] || [ "${service_subdomain}" = "undefined" ]; then
    service_subdomain="status-${PW_USER:-${USER:-$(id -un)}}"
fi
# Hostname labels are lowercase alphanumerics and hyphens: Matthew.Shaxted -> matthew-shaxted
service_subdomain=$(printf '%s' "${service_subdomain}" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-63 | sed 's/-*$//')

# Starting again restarts. The controller already deleted the endpoint with this name;
# the address can still be held by this dashboard under a name with a suffix - one
# launched as <name>-<run slug> before the name was fixed, or left listed but serving
# nothing by a recycled workspace - and two endpoints cannot share a subdomain. Delete
# those wherever they run: their pw endpoints run notices the session is gone and takes
# its process tree down. Anything else at the address is not ours to delete; the launch
# then falls back to a platform-assigned address below.
listed_names() {
    pw endpoints list 2>/dev/null | awk -F'\t' '{print $1}'
}
replaced=""
for previous in $(pw endpoints list 2>/dev/null | awk -F'\t' -v host="https://${service_subdomain}." 'index($3, host) == 1 {print $1}'); do
    case "${previous}" in
        "${served_name}"|"${served_name}"-*)
            echo "::notice::Replacing the previous dashboard at https://${service_subdomain}.*: deleting endpoint ${previous}"
            pw endpoints delete "${previous}"
            replaced="${replaced} ${previous}"
            ;;
        *)
            echo "::notice::https://${service_subdomain}.* is served by endpoint ${previous}, which is not this dashboard; leaving it alone"
            ;;
    esac
done
for _ in $(seq 1 30); do
    remaining=""
    for previous in ${replaced}; do
        listed_names | grep -qxF "${previous}" && remaining="${remaining} ${previous}"
    done
    replaced="${remaining}"
    [ -z "${replaced}" ] && break
    sleep 2
done

server_args=(--config "${config_file}")
case "${service_theme}" in
    dark|light) server_args+=(--default-theme "${service_theme}") ;;
esac
if [ "${service_enable_cluster_pages}" = "false" ]; then
    server_args+=(--disable-cluster-pages)
else
    server_args+=(--enable-cluster-pages)
fi
if [ "${service_enable_cluster_monitor}" = "false" ]; then
    server_args+=(--disable-cluster-monitor)
else
    server_args+=(--enable-cluster-monitor)
fi
if [[ "${service_cluster_monitor_interval}" =~ ^[0-9]+$ ]]; then
    server_args+=(--cluster-monitor-interval "${service_cluster_monitor_interval}")
fi
if [[ "${service_sweep_concurrency}" =~ ^[1-9][0-9]*$ ]]; then
    server_args+=(--max-concurrent-ssh "${service_sweep_concurrency}")
fi

# pw endpoints run assigns the port (PORT) and the base path it serves under
# (PW_ENDPOINT_PATH, "/" on a subdomain endpoint). The dashboard binds loopback only:
# the tunnel connects locally, and the dashboard has no login of its own to protect
# the allocation and queue data it serves from other users of a shared login node.
cat <<EOF > launch-dashboard.sh
#!/bin/bash
cd "${app_dir}"
exec "${python}" -m src.server.main --host 127.0.0.1 --port "\${PORT}" --url-prefix "\${PW_ENDPOINT_PATH:-/}"$(printf ' %q' "${server_args[@]}")
EOF
chmod +x launch-dashboard.sh

echo "::group::Start Service"
echo "::notice::Starting the dashboard: pw endpoints run ${pw_endpoints_args} --subdomain ${service_subdomain} -- ./launch-dashboard.sh"
cat launch-dashboard.sh

endpoint_listed() {
    listed_names | grep -qxF "${served_name}"
}

started=${SECONDS}
pw endpoints run ${pw_endpoints_args} --subdomain "${service_subdomain}" -- ./launch-dashboard.sh
status=$?

# A platform without session subdomains, or a label another user holds, fails at once;
# anything that ran for a while failed for its own reasons and is not retried
if [ ${status} -ne 0 ] && [ $(( SECONDS - started )) -le 20 ] && ! endpoint_listed; then
    echo "::warning title=Subdomain::Could not serve at https://${service_subdomain}.*; falling back to a platform-assigned address. 'pw subdomains reserve ${service_subdomain}' claims the name, or set Public Subdomain to another one"
    pw endpoints run ${pw_endpoints_args} -- ./launch-dashboard.sh
    status=$?
fi

if [ ${status} -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Only a
    # launch that never registered its endpoint is a real failure.
    if endpoint_listed; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
