#!/usr/bin/env bash
################################################################################
# Interactive Session Controller - Burst Render dashboard
#
# Purpose: Prepare the dashboard host: Python, uv and the dashboard's virtualenv
# Runs on: Controller (login) node, with internet access
# Called by: Workflow preprocessing, before the start script is submitted
#
# Required Environment Variables (from inputs.sh):
#   - service_parent_install_dir: Parent directory of the installation
#   - PW_PARENT_JOB_DIR: Run directory (holds the checked-out app/)
################################################################################
set -o pipefail

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

install_dir="${service_parent_install_dir}/burst-render-demo"
venv_dir="${install_dir}/venv"
uv_dir="${service_parent_install_dir}/.uv"
uv_bin="${uv_dir}/uv"
app_dir="${PW_PARENT_JOB_DIR}/workflows/burst-render-demo/app"
packages="fastapi uvicorn python-multipart websockets"
min_python="3.8"
target_python="3.12"

# Keep the uv cache next to the install (HOME quotas are small on some HPC systems)
export UV_CACHE_DIR="${install_dir}/.uv-cache"
# Some HPC networks terminate TLS at an inspection proxy with a private CA that uv's
# bundled trust store does not know; the OS store does
export UV_NATIVE_TLS=true

echo "Hostname: $(hostname)"
echo "Install dir: ${install_dir}"

# Importing the app is the real check: FastAPI raises at import time when
# python-multipart, which its Form/File routes need, is missing
verify_venv() {
    [ -x "${venv_dir}/bin/python" ] || return 1
    PYTHONPATH="${app_dir}" "${venv_dir}/bin/python" - <<'PY'
import fastapi, uvicorn, websockets
import dashboard
print(f"fastapi {fastapi.__version__}, uvicorn {uvicorn.__version__}, websockets {websockets.__version__}")
PY
}

if [ ! -f "${app_dir}/dashboard.py" ]; then
    echo "::error title=Error::dashboard.py not found at ${app_dir}"
    exit 1
fi

if verify_venv 2>/dev/null; then
    echo "Dashboard environment ready at ${venv_dir}"
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
    UV_HTTP_TIMEOUT=120 "${uv_bin}" pip install --python "${venv_dir}/bin/python" ${packages} || exit 1
else
    if python_too_old; then
        echo "::error title=Error::uv is unavailable and the system Python ($(${python_cmd} --version 2>&1)) is older than ${min_python}"
        exit 1
    fi
    echo "Installing with pip..."
    ${python_cmd} -m venv "${venv_dir}" || exit 1
    "${venv_dir}/bin/python" -m pip install --quiet --upgrade pip
    "${venv_dir}/bin/python" -m pip install --quiet ${packages} || exit 1
fi

if ! verify_venv; then
    echo "::error title=Error::The dashboard environment at ${venv_dir} does not import"
    exit 1
fi
echo "Dashboard environment ready at ${venv_dir}"
