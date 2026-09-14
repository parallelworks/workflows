# controller.sh — login-node setup for the endpoint workflows (yamls/*.yaml).
# Runs with inputs.sh prepended and appends the resolved paths back to ./inputs.sh
# for start-template.sh.

set -o pipefail
set -x

if ! command -v singularity >/dev/null 2>&1 && ! command -v apptainer >/dev/null 2>&1; then
    module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true
fi
if ! command -v singularity >/dev/null 2>&1 && ! command -v apptainer >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y epel-release || true
        sudo dnf install -y apptainer
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y epel-release || true
        sudo yum install -y apptainer
    elif command -v apt-get >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y apptainer
    fi
fi
singularity_bin=$(command -v singularity || command -v apptainer)
if [ -z "${singularity_bin}" ]; then
    echo "::error title=Error::singularity/apptainer not found and could not be installed"
    exit 1
fi
"${singularity_bin}" --version

if [ -z "${service_parent_install_dir}" ] || [ "${service_parent_install_dir}" = "undefined" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
service_parent_install_dir="${service_parent_install_dir/#\~/$HOME}"

# On NOAA and HSP the install directory is a store shared between accounts
# (/contrib/pw, $PROJECTS_HOME/hsp), usually owned by whoever staged it first.
# Whatever is already there is reused read-only by every account; what still
# has to be downloaded goes there when this account can write it and into a
# private directory otherwise. Each artifact decides on its own, so one
# unwritable subdirectory never forces a re-download of everything.
shared_root="${service_parent_install_dir}"
private_root="${HOME}/pw/software"

# Leaves what this run uses from the shared store group-writable, with setgid
# directories, so any project member can add to or refresh it later; running
# it on already-staged artifacts lets their owner's next run open up a tree
# created before this rule existed. Best effort: paths another account
# created are not ours to change.
share() {
    local p=$1
    case "${p}" in "${HOME}"/*) return 0 ;; "${shared_root}"/*) ;; *) return 0 ;; esac
    chmod -R g+rwX,o+rX "${p}" 2>/dev/null
    find "${p}" -type d -exec chmod g+s {} + 2>/dev/null
    while [ "${p}" != "${shared_root}" ] && [ "${p}" != "/" ]; do
        p=$(dirname "${p}")
        chmod g+rwx,o+rx "${p}" 2>/dev/null
        chmod g+s "${p}" 2>/dev/null
    done
    return 0
}

# Sets ${dir} to where a new artifact goes: the shared subdirectory when this
# account can write it (created if missing), the private one otherwise
pick_writable_dir() {
    local rel=$1 d
    for d in "${shared_root}/${rel}" "${private_root}/${rel}"; do
        if [ -d "${d}" ]; then
            [ -w "${d}" ] && { dir="${d}"; return 0; }
        elif mkdir -p "${d}" 2>/dev/null; then
            share "${d}"
            dir="${d}"
            return 0
        fi
        [ "${d}" != "${private_root}/${rel}" ] \
            && echo "::warning::${d} is not writable; using ${private_root}/${rel} instead"
    done
    return 1
}

oras_bin=""
for d in "${shared_root}" "${private_root}"; do
    if [ -x "${d}/tools/oras/oras" ]; then
        oras_bin="${d}/tools/oras/oras"
        break
    fi
done
if [ -z "${oras_bin}" ]; then
    if ! pick_writable_dir tools/oras; then
        echo "::error title=Error::neither ${shared_root} nor ${private_root} is writable; nowhere to install oras"
        exit 1
    fi
    echo "::group::oras Install"
    VER=1.2.0
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) echo "::error title=Error::unsupported architecture $(uname -m)"; exit 1 ;;
    esac
    curl -fsSL --connect-timeout 15 --max-time 300 -o oras.tar.gz \
        "https://github.com/oras-project/oras/releases/download/v${VER}/oras_${VER}_linux_${ARCH}.tar.gz"
    tar -xzf oras.tar.gz -C "${dir}" oras
    rm -f oras.tar.gz
    chmod -R a+rX "${dir}"
    oras_bin="${dir}/oras"
    echo "::endgroup::"
fi
share "${oras_bin%/*}"

# v4-compatible names (vllm.sif, rag.sif) so pre-staged containers under
# $PROJECTS_HOME/hsp/containers are found and reused; delete the file to
# force a re-pull after changing the container URI tag
sif_name_for() {
    local name="${1##*/}"
    echo "${name%%:*}.sif"
}
# Sets ${sif} for a container URI: the staged copy when one is readable,
# otherwise the path to pull it to
resolve_sif() {
    local name d
    name=$(sif_name_for "$1")
    for d in "${shared_root}" "${private_root}"; do
        if [ -r "${d}/containers/${name}" ]; then
            sif="${d}/containers/${name}"
            return 0
        fi
    done
    pick_writable_dir containers || return 1
    sif="${dir}/${name}"
}
pull_sif() {
    local uri=$1 target=$2 pull_dir pulled_sif
    [ -f "${target}" ] && return 0
    echo "::group::SIF Download ${uri}"
    pull_dir=$(mktemp -d -p "${target%/*}")
    # ghcr.io intermittently answers "toomanyrequests" to anonymous pulls;
    # a short retry rides out the rate limit instead of failing the workflow
    local attempt pulled=""
    for attempt in 1 2 3; do
        if "${oras_bin}" pull "${uri}" -o "${pull_dir}"; then
            pulled=yes
            break
        fi
        [ "${attempt}" -lt 3 ] && sleep $((attempt * 5))
    done
    if [ -z "${pulled}" ]; then
        echo "::error title=Error::oras pull failed for ${uri} after ${attempt} attempts"
        exit 1
    fi
    pulled_sif=$(find "${pull_dir}" -name '*.sif' -type f | head -1)
    if [ ! -s "${pulled_sif}" ]; then
        echo "::error title=Error::no SIF file found in ${uri}"
        exit 1
    fi
    mv "${pulled_sif}" "${target}"
    rm -rf "${pull_dir}"
    chmod a+r "${target}"
    echo "::endgroup::"
}

if ! resolve_sif "${container_uri}"; then
    echo "::error title=Error::neither ${shared_root} nor ${private_root} is writable; nowhere to store ${container_uri}"
    exit 1
fi
container_sif="${sif}"
pull_sif "${container_uri}" "${container_sif}"
share "${container_sif}"
if [ "${runtype}" = "all" ]; then
    if ! resolve_sif "${rag_container_uri}"; then
        echo "::error title=Error::neither ${shared_root} nor ${private_root} is writable; nowhere to store ${rag_container_uri}"
        exit 1
    fi
    rag_sif="${sif}"
    pull_sif "${rag_container_uri}" "${rag_sif}"
    share "${rag_sif}"
fi

# Tokenizer encodings for offline use (gpt-oss and tiktoken-based models)
tiktoken_encodings="o200k_base cl100k_base"
tiktoken_dir=""
for d in "${shared_root}" "${private_root}"; do
    complete=yes
    for enc in ${tiktoken_encodings}; do
        [ -s "${d}/cache/tiktoken_encodings/${enc}.tiktoken" ] || complete=""
    done
    if [ -n "${complete}" ]; then
        tiktoken_dir="${d}/cache/tiktoken_encodings"
        break
    fi
done
if [ -z "${tiktoken_dir}" ]; then
    if pick_writable_dir cache/tiktoken_encodings; then
        tiktoken_dir="${dir}"
        for enc in ${tiktoken_encodings}; do
            [ -s "${tiktoken_dir}/${enc}.tiktoken" ] && continue
            curl -fsSL --connect-timeout 15 --max-time 300 -o "${tiktoken_dir}/${enc}.tiktoken" \
                "https://openaipublic.blob.core.windows.net/encodings/${enc}.tiktoken" || {
                rm -f "${tiktoken_dir}/${enc}.tiktoken"
                echo "::warning::could not pre-download ${enc}.tiktoken"
            }
        done
    else
        tiktoken_dir="${private_root}/cache/tiktoken_encodings"
        echo "::warning::${tiktoken_dir} is not writable; tiktoken encodings will not be pre-downloaded"
    fi
fi
share "${tiktoken_dir}"

if [ -z "${model_cache_dir}" ] || [ "${model_cache_dir}" = "undefined" ]; then
    model_cache_dir=${HOME}/pw/models
fi

if [ "${runtype}" = "all" ]; then
    # The RAG stack (start_service.sh, rag_server.py, rag_proxy.py, indexer.py)
    # runs from a clone of this repository
    rag_rundir="${rag_rundir/#\~/$HOME}"
    mkdir -p "$(dirname "${rag_rundir}")"
    if [ -d "${rag_rundir}/.git" ]; then
        git -C "${rag_rundir}" fetch origin
        git -C "${rag_rundir}" checkout "${repository_branch}"
        git -C "${rag_rundir}" reset --hard "origin/${repository_branch}"
    else
        git clone -b "${repository_branch}" "${repository}" "${rag_rundir}"
    fi
    rag_appdir="${rag_rundir}/workflows/rag-vllm/app"
    rm -f "${rag_appdir}"/{jobid,SESSION_PORT,job.started,job.ended,run.out,HOSTNAME,cancel.sh}
    rm -rf "${rag_appdir}/logs"

    # start_service.sh binds ./cache:/root/.cache; seed the shared encodings
    mkdir -p "${rag_appdir}/cache/tiktoken_encodings"
    cp -n "${tiktoken_dir}"/*.tiktoken "${rag_appdir}/cache/tiktoken_encodings/" 2>/dev/null || true

    # The model and embedding-model paths are appended by start-template.sh:
    # prepare_model runs concurrently with this script and only it knows
    # which cache the download landed in
    {
        echo "export RUNMODE=singularity"
        echo "export RUNTYPE=all"
        echo "export SYSTEM_PROMPT=\"${rag_systemprompt}\""
        echo "export HF_TOKEN=${hf_token}"
        echo "export DOCS_DIR=${rag_docsdir:-./docs}"
        echo "export MAX_TOKENS=${rag_max_tokens}"
        echo "export TIKTOKEN_ENCODINGS_BASE=/root/.cache/tiktoken_encodings"
        echo "export TIKTOKEN_RS_CACHE_DIR=/root/.cache/tiktoken_encodings"
        echo "export VLLM_EXTRA_ARGS=\"${vllm_args}\""
        echo "export TRANSFORMERS_OFFLINE=1"
        if [ -n "${vllm_attention_backend}" ] && [ "${vllm_attention_backend}" != "undefined" ]; then
            echo "export VLLM_ATTENTION_BACKEND=${vllm_attention_backend}"
        fi
    } > "${rag_appdir}/.run.env"
fi

# Pass the resolved paths to the start script
{
    echo "export service_parent_install_dir=\"${service_parent_install_dir}\""
    echo "export model_cache_dir=\"${model_cache_dir}\""
    echo "export container_sif=\"${container_sif}\""
    echo "export sandbox_dir=\"${container_sif%.sif}-sandbox\""
    echo "export tiktoken_dir=\"${tiktoken_dir}\""
    if [ "${runtype}" = "all" ]; then
        echo "export rag_sif=\"${rag_sif}\""
        echo "export rag_sandbox_dir=\"${rag_sif%.sif}-sandbox\""
        echo "export rag_rundir=\"${rag_rundir}\""
        echo "export rag_appdir=\"${rag_appdir}\""
    fi
} >> ./inputs.sh
