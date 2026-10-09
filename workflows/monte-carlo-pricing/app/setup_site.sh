#!/bin/bash
# setup_site.sh — Pick the python the simulator runs with on a remote site
#
# Prints the interpreter's path on stdout; progress goes to stderr. The first that
# imports numpy wins: the system python3, then a virtualenv under
# ~/pw/software/monte-carlo-pricing/site-venv, built here on first use. Without numpy
# the simulator still runs on its pure Python fallback, only much slower.

install_dir="${HOME}/pw/software/monte-carlo-pricing"
venv_dir="${install_dir}/site-venv"

python_cmd=""
for cmd in python3 python; do
    command -v ${cmd} >/dev/null 2>&1 && { python_cmd=$(command -v ${cmd}); break; }
done
if [ -z "${python_cmd}" ]; then
    echo "[ERROR] Python not found on $(hostname)" >&2
    exit 1
fi
echo "System Python: ${python_cmd} ($(${python_cmd} --version 2>&1))" >&2

has_numpy() {
    [ -x "$1" ] && "$1" -c "import numpy" >/dev/null 2>&1
}

if has_numpy "${python_cmd}"; then
    echo "numpy: system Python" >&2
    echo "${python_cmd}"
    exit 0
fi
if has_numpy "${venv_dir}/bin/python"; then
    echo "numpy: ${venv_dir}" >&2
    echo "${venv_dir}/bin/python"
    exit 0
fi

echo "Installing numpy into ${venv_dir}..." >&2
mkdir -p "${install_dir}"
rm -rf "${venv_dir}"
# Built beside the final path and renamed into place, so a concurrent run on this site
# never sees a half-installed virtualenv; if another run got there first, use its copy
tmp_dir=$(mktemp -d "${install_dir}/.site-venv.XXXXXX")
if "${python_cmd}" -m venv "${tmp_dir}" >&2 && \
    { "${tmp_dir}/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip >&2 || true; } && \
    "${tmp_dir}/bin/python" -m pip install --quiet --disable-pip-version-check numpy >&2 && \
    has_numpy "${tmp_dir}/bin/python"; then
    mv -T "${tmp_dir}" "${venv_dir}" 2>/dev/null || rm -rf "${tmp_dir}"
    if has_numpy "${venv_dir}/bin/python"; then
        echo "numpy: ${venv_dir}" >&2
        echo "${venv_dir}/bin/python"
        exit 0
    fi
fi
rm -rf "${tmp_dir}"

echo "[WARN] numpy could not be installed on $(hostname); the simulator falls back to pure Python" >&2
echo "${python_cmd}"
