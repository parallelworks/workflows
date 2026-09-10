################################################################################
# Interactive Session Service Starter - OpenVSCode (code-server)
#
# Purpose: Start code-server web service on allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug, ...)
#   - service_parent_install_dir: Installation directory
#   - service_download_url: Download URL for code-server
#   - service_password: Access password (optional, auth=none if not set)
#   - service_directory: Working directory to open (default: ~/)
#   - service_subdomain: Subdomain label of the IDE URL (optional, default
#     vscode-<resource_namespace>-<resource_name>-<PW_USER>; ignored with --no-subdomain)
#   - resource_namespace, resource_name: Used to build the default subdomain
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# code-server-4.92.2-linux-amd64.tar.gz
service_tgz_basename=$(echo ${service_download_url} | rev | cut -d'/' -f1 | rev)
# code-server-4.92.2-linux-amd64
service_tgz_stem=$(echo ${service_tgz_basename} | sed "s|.tar.gz||g")

service_tgz_path=${service_parent_install_dir}/${service_tgz_basename}
service_install_dir=${service_parent_install_dir}/${service_tgz_stem}
service_exec=${service_install_dir}/bin/code-server


# SET DEFAULTS:
if [ -z ${service_directory} ]; then
    service_directory=~/
fi

if [ -z ${service_password} ]; then
    password_flag="--auth=none"
else
    export PASSWORD=${service_password}
    password_flag="--auth=password"
fi

# code-server keeps VS Code's browser-side state (GitHub/Copilot sign-in, disabled
# extensions, trusted folders) in the browser, keyed by page origin, so a new
# random subdomain per run throws that state away. Pin the subdomain instead;
# path-based endpoints (--no-subdomain) already have a stable origin.
if ! printf '%s' "${pw_endpoints_args}" | grep -q -- '--no-subdomain'; then
    if [ -z "${service_subdomain}" ] || [ "${service_subdomain}" = "undefined" ]; then
        service_subdomain="vscode-${resource_namespace}-${resource_name}-${PW_USER}"
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


# DISABLE EXTENSION TELEMETRY
export VSCODE_TELEMETRY_LEVEL=off
export KILOCODE_POSTHOG_API_KEY=“”
export POSTHOG_DISABLED=1
export POSTHOG_TELEMETRY_ENABLED=false
export ANONYMIZED_TELEMETRY=false
export OTEL_SDK_DISABLED=true
export TELEMETRY_DISABLED=1
export DISABLE_TELEMETRY=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export POWERSHELL_TELEMETRY_OPTOUT=1
export NEXT_TELEMETRY_DISABLED=1
export GOTELEMETRY=off

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting code-server: pw endpoints run ${pw_endpoints_args} -- ${service_exec} --bind-addr=0.0.0.0:{port} ${password_flag} ${service_directory}"

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- ${service_exec} \
    --bind-addr=0.0.0.0:{port} \
    ${password_flag} \
    ${service_directory}

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