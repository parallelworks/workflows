#!/usr/bin/env bash
################################################################################
# Interactive Session Controller - HPC Status Monitor
#
# Purpose: Prepare the dashboard host: the pw CLI check, uv and the dashboard's
#          virtualenv, then stop the previous dashboard with this endpoint name
# Runs on: Controller (login) node or the user workspace, with internet access
# Called by: Workflow preprocessing, before the start script is submitted
#
# Required Environment Variables (from inputs.sh):
#   - pw_endpoints_args: Arguments for pw endpoints run (--name <endpoint name>)
#   - service_parent_install_dir: Parent directory of the installation
#   - PW_PARENT_JOB_DIR: Run directory (holds the checked-out app/)
################################################################################
set -o pipefail

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

install_dir="${service_parent_install_dir}/hpc_status"
venv_dir="${install_dir}/venv"
uv_dir="${service_parent_install_dir}/.uv"
uv_bin="${uv_dir}/uv"
app_dir="${PW_PARENT_JOB_DIR}/workflows/hpc_status/app"
min_python="3.10"
target_python="3.12"

# Keep the uv cache next to the install (HOME quotas are small on some HPC systems)
export UV_CACHE_DIR="${install_dir}/.uv-cache"
# Some HPC networks terminate TLS at an inspection proxy with a private CA that uv's
# bundled trust store does not know; the OS store does
export UV_SYSTEM_CERTS=true

echo "Hostname: $(hostname)"
echo "Install dir: ${install_dir}"

# The dashboard publishes itself and collects all of its telemetry through pw
if ! command -v pw >/dev/null 2>&1; then
    echo "::error title=Error::The pw CLI is not on PATH on $(hostname). The dashboard needs it to publish its endpoint and to reach the clusters; install it there or run the dashboard on the user workspace"
    exit 1
fi

if [ ! -f "${app_dir}/src/server/main.py" ] || [ ! -f "${app_dir}/requirements.txt" ]; then
    echo "::error title=Error::The dashboard sources are missing from ${app_dir}"
    exit 1
fi

# Importing the server is the real check: it pulls in every module and dependency the
# dashboard loads at start-up, so a venv from an older checkout is rebuilt when it lacks one
verify_venv() {
    [ -x "${venv_dir}/bin/python" ] || return 1
    (cd "${app_dir}" && "${venv_dir}/bin/python" - <<PY
import sys
if sys.version_info < tuple(int(x) for x in "${min_python}".split(".")):
    sys.exit(f"python {sys.version.split()[0]} is older than ${min_python}")
import bs4, certifi, requests, urllib3, yaml
import src.server.main
print(f"python {sys.version.split()[0]}, requests {requests.__version__}, urllib3 {urllib3.__version__}, pyyaml {yaml.__version__}")
PY
    )
}

endpoint_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
endpoint_listed() {
    pw endpoints list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qxF "${endpoint_name}"
}

# Starting again restarts, and two endpoints cannot share a name: delete the previous
# dashboard under this name wherever it runs, and its pw endpoints run takes its process
# tree down. Only once the environment is ready, so a failed install leaves it serving,
# and before this script returns: the run waits for the endpoint by name, and would take
# the previous dashboard answering for the new one
stop_previous() {
    [ -n "${endpoint_name}" ] && endpoint_listed || return 0
    echo "::notice::Replacing the previous dashboard: deleting endpoint ${endpoint_name}"
    pw endpoints delete "${endpoint_name}"
    for _ in $(seq 1 30); do
        endpoint_listed || return 0
        sleep 2
    done
    echo "::error title=Error::Endpoint ${endpoint_name} is still listed after deleting it; delete it with 'pw endpoints delete ${endpoint_name}' and launch again"
    exit 1
}

if verify_venv 2>/dev/null; then
    echo "Dashboard environment ready at ${venv_dir}"
    stop_previous
    exit 0
fi

python_cmd=""
for cmd in python3 python; do
    command -v ${cmd} >/dev/null 2>&1 && { python_cmd=${cmd}; break; }
done
if [ -z "${python_cmd}" ]; then
    echo "::error title=Error::Python not found in PATH"
    exit 1
fi
echo "System Python: ${python_cmd} ($(${python_cmd} --version 2>&1))"

python_too_old() {
    ${python_cmd} -c "import sys; sys.exit(0 if sys.version_info < tuple(int(x) for x in '${min_python}'.split('.')) else 1)"
}

# uv is shared by every workflow that uses it on this host; the install is atomic
# (extract to a temp dir, then rename) so concurrent jobs cannot see a partial binary
install_uv() {
    if [ -x "${uv_bin}" ]; then
        echo "uv: ${uv_bin} (cached, $(${uv_bin} --version 2>&1))"
        return 0
    fi
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|aarch64) ;;
        *) echo "Unsupported architecture for uv: ${arch}"; return 1 ;;
    esac
    mkdir -p "${uv_dir}" || return 1
    local url="https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-unknown-linux-gnu.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d "${uv_dir}/.install.XXXXXX") || return 1
    echo "Installing uv to ${uv_dir}..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${url}" | tar -xz -C "${tmp_dir}" --strip-components=1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "${url}" | tar -xz -C "${tmp_dir}" --strip-components=1
    else
        echo "Neither curl nor wget is available"
        rm -rf "${tmp_dir}"
        return 1
    fi
    if [ ! -x "${tmp_dir}/uv" ]; then
        echo "uv download failed"
        rm -rf "${tmp_dir}"
        return 1
    fi
    mv -f "${tmp_dir}/uv" "${uv_bin}"
    rm -rf "${tmp_dir}"
    echo "uv installed: $(${uv_bin} --version 2>&1)"
}

# A venv left by an interrupted install cannot be healed by a second pip install
rm -rf "${venv_dir}"
mkdir -p "${install_dir}"

if install_uv; then
    uv_python="${python_cmd}"
    if python_too_old; then
        echo "System Python is older than ${min_python}; installing Python ${target_python} with uv"
        "${uv_bin}" python install "${target_python}" || exit 1
        uv_python="${target_python}"
    fi
    "${uv_bin}" venv "${venv_dir}" --python "${uv_python}" || exit 1
    UV_HTTP_TIMEOUT=120 "${uv_bin}" pip install --python "${venv_dir}/bin/python" -r "${app_dir}/requirements.txt" || exit 1
else
    if python_too_old; then
        echo "::error title=Error::uv is unavailable and the system Python ($(${python_cmd} --version 2>&1)) is older than ${min_python}"
        exit 1
    fi
    echo "Installing with pip..."
    ${python_cmd} -m venv "${venv_dir}" || exit 1
    "${venv_dir}/bin/python" -m pip install --quiet --upgrade pip
    "${venv_dir}/bin/python" -m pip install --quiet -r "${app_dir}/requirements.txt" || exit 1
fi

if ! verify_venv; then
    echo "::error title=Error::The dashboard environment at ${venv_dir} does not import"
    exit 1
fi
echo "Dashboard environment ready at ${venv_dir}"
stop_previous
