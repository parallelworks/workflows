# Sourced by the install-<tool>.sh scripts of the workflows that install their
# software from conda-forge without sudo: one Miniforge prefix per workflow under
# the standard install dir, one env per tool inside it.
#
#   miniforge_prefix <workflow>           prints <service_parent_install_dir>/<workflow>/miniforge
#   miniforge_lock <prefix>               serializes every installer of that prefix
#   miniforge_bootstrap <prefix>          idempotent Miniforge install (MINIFORGE_URL pins the installer)
#   miniforge_env_file <prefix> <env> <file>   writes the file a run sources to activate <env>

miniforge_prefix() {
    printf '%s/%s/miniforge' "${service_parent_install_dir:-${HOME}/pw/software}" "$1"
}

# An optimization loop starts several evaluator subworkflows at once, and on a
# cold cluster each runs its installer: the first one installs while the others
# wait here, then find the env ready. The lock is held until the caller exits.
miniforge_lock() {
    mkdir -p "$(dirname "$1")" || return 1
    exec 9> "$1.lock" && flock 9
}

# A conda that runs is the test, not a binary the file system merely holds: a
# Miniforge installer cut short (a walltime, an attempt budget) can leave the
# binary behind. The marker stands while this bootstrap installs, so only a
# prefix it left half-made is removed and redone; a prefix nobody marked whose
# conda does not run was made by someone else and is left alone
miniforge_bootstrap() {
    local prefix="$1"
    local installing="${prefix}.installing"
    if "${prefix}/bin/conda" --version > /dev/null 2>&1; then
        rm -f "${installing}"
        return 0
    fi
    if [ -e "${prefix}/bin/conda" ] && [ ! -f "${installing}" ]; then
        echo "::error::${prefix} exists but its conda does not run, and it was not left by this bootstrap: fix or remove it by hand"
        return 1
    fi
    local url="${MINIFORGE_URL:-https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh}"
    local installer
    installer=$(mktemp /tmp/miniforge-XXXXXX.sh)
    echo "::notice::Downloading ${url}"
    if ! wget --timeout=60 --tries=3 -nv -O "${installer}" "${url}"; then
        rm -f "${installer}"
        echo "::error::Could not download the Miniforge installer"
        return 1
    fi
    rm -rf "${prefix}"
    mkdir -p "$(dirname "${prefix}")" && touch "${installing}"
    if ! bash "${installer}" -b -p "${prefix}"; then
        rm -f "${installer}"
        rm -rf "${prefix}"
        echo "::error::The Miniforge installer failed"
        return 1
    fi
    rm -f "${installer}" "${installing}"
}

miniforge_env_file() {
    local prefix="$1" env="$2" file="$3"
    cat > "${file}" << EOT
# ${env} environment: the conda-forge env under ${prefix}
source "${prefix}/etc/profile.d/conda.sh"
conda activate ${env}
EOT
}
