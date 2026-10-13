# Sourced by install-openfoam.sh and install-dakota.sh: both environments live in
# one Miniforge prefix under the standard install dir.
SOFTWARE_DIR="${service_parent_install_dir:-${HOME}/pw/software}"
CONDA_PREFIX_DIR="${SOFTWARE_DIR}/dakota-openfoam/miniforge"

f_install_miniforge() {
    if [ -x "${CONDA_PREFIX_DIR}/bin/conda" ]; then
        return 0
    fi
    local url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
    local installer
    installer=$(mktemp /tmp/miniforge-XXXXXX.sh)
    echo "::notice::Downloading ${url}"
    if ! wget --timeout=60 --tries=3 -nv -O "${installer}" "${url}"; then
        rm -f "${installer}"
        echo "::error::Could not download the Miniforge installer"
        return 1
    fi
    rm -rf "${CONDA_PREFIX_DIR}"
    mkdir -p "$(dirname "${CONDA_PREFIX_DIR}")"
    if ! bash "${installer}" -b -p "${CONDA_PREFIX_DIR}"; then
        rm -f "${installer}"
        rm -rf "${CONDA_PREFIX_DIR}"
        echo "::error::The Miniforge installer failed"
        return 1
    fi
    rm -f "${installer}"
}
