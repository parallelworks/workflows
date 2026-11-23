# controller.sh: login-node setup for the llm-server workflow (yamls/*.yaml).
# Runs with inputs.sh prepended and appends what it resolves to ./inputs.sh
# for start-template.sh, so the service script never re-derives it.
#
# vllm and sglang run from SIF images pulled once from ghcr.io as ORAS
# artifacts; llamacpp runs a prebuilt llama-server binary. Everything is
# installed on the controller, which has the internet access a compute node
# may lack.

set -o pipefail
set -x

fail() { echo "::error title=$1::$2"; exit 1; }

# The run waits for its endpoint by name, so one already listed under it (an
# earlier launch with the same Endpoint name, still serving or left stopped)
# would be taken for the new server. Deleting it stops its server. Called last:
# a failed install leaves the previous server running.
free_endpoint_name() {
    endpoint_listed() {
        pw endpoints list 2>/dev/null | awk -F'\t' '{print $1}' | grep -qxF "${endpoint_name}"
    }
    [ -n "${endpoint_name}" ] && endpoint_listed || return 0
    echo "::notice title=Endpoint::Replacing the endpoint already listed as ${endpoint_name}"
    pw endpoints delete "${endpoint_name}"
    local _
    for _ in $(seq 1 30); do
        endpoint_listed || return 0
        sleep 2
    done
    fail "Endpoint" "${endpoint_name} is still listed after deleting it; run 'pw endpoints delete ${endpoint_name}' and launch again"
}

if [ -z "${service_parent_install_dir}" ] || [ "${service_parent_install_dir}" = "undefined" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
service_parent_install_dir="${service_parent_install_dir/#\~/$HOME}"

# On NOAA and HSP the install directory is a store shared between accounts
# (the cluster's shared software directory, $PROJECTS_HOME/hsp), usually owned
# by whoever staged it first. Whatever is already there is reused read-only by
# every account; what still has to be downloaded goes there when this account
# can write it and into a private directory otherwise. Each artifact decides
# on its own, so one unwritable subdirectory never forces a re-download of
# everything.
shared_root="${service_parent_install_dir}"
private_root="${HOME}/pw/software"

# Leaves what this run uses from the shared store group-writable, with setgid
# directories, so any project member can add to or refresh it later. Best
# effort: paths another account created are not ours to change.
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

{
    echo "export service_parent_install_dir=\"${service_parent_install_dir}\""
} >> ./inputs.sh

# ---------------------------------------------------------------------------
# llama.cpp: install llama-server and stage the GGUF files
# ---------------------------------------------------------------------------
if [ "${engine}" = "llamacpp" ]; then
    if ! type module > /dev/null 2>&1; then
        for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \
                    /usr/share/Modules/init/bash /usr/share/lmod/lmod/init/bash; do
            [ -r "${init}" ] && . "${init}" 2> /dev/null && break
        done
    fi
    writable_dir() { [ -n "$1" ] && mkdir -p "$1" 2> /dev/null && [ -w "$1" ]; }

    # Shared store first, then the work filesystem, then home. A ready copy
    # anywhere is reused read-only; a new download goes to the first writable one.
    roots=()
    for root in "${shared_root}" "${WORKDIR:+${WORKDIR}/pw/software}" "${private_root}"; do
        [ -n "${root}" ] && roots+=("${root}")
    done

    tag="$(basename "${llamacpp_release_url}")"
    tag="${tag%.tar.gz}"; tag="${tag%.tgz}"
    install_dir=""
    for root in "${roots[@]}"; do
        if [ -f "${root}/llamacpp/${tag}/.ready" ]; then
            install_dir="$(cat "${root}/llamacpp/${tag}/.ready")"
            [ -x "${install_dir}/llama-server" ] && break
            install_dir=""
        fi
    done

    if [ -n "${install_dir}" ]; then
        echo "::notice title=llama.cpp::Reusing ${install_dir}"
    else
        target=""
        for root in "${roots[@]}"; do
            writable_dir "${root}/llamacpp/${tag}" && target="${root}/llamacpp/${tag}" && break
        done
        [ -n "${target}" ] || fail "Install Directory" "No writable directory for llama.cpp"
        echo "::notice title=llama.cpp::Installing ${tag} into ${target}"
        curl -fsSL -o "${target}/llama.tar.gz" "${llamacpp_release_url}" \
            || fail "Download" "Could not download ${llamacpp_release_url}"
        tar -xzf "${target}/llama.tar.gz" -C "${target}" && rm -f "${target:?}/llama.tar.gz"
        bin="$(find "${target}" -name llama-server -type f | head -1)"
        [ -n "${bin}" ] || fail "llama.cpp" "No llama-server in ${llamacpp_release_url}"
        install_dir="$(cd "$(dirname "${bin}")" && pwd)"
        cuda_lib="${install_dir}/libggml-cuda.so"

        # Prebuilt CUDA tarballs often leave out the CUDA runtime. The CUDA
        # backend is a plugin llama-server loads at run time, so a missing
        # runtime does not fail the launch: it silently serves on CPU. NVIDIA
        # publishes the runtime and cuBLAS as wheels on PyPI; place their
        # libraries beside the binary.
        major="$(ldd "${cuda_lib}" 2> /dev/null | grep -oE 'libcudart\.so\.[0-9]+ => not found' | sed -E 's/libcudart\.so\.([0-9]+).*/\1/')"
        if [ -n "${major}" ]; then
            echo "::notice title=CUDA runtime::Fetching the CUDA ${major} runtime and cuBLAS from PyPI"
            wheels="$(mktemp -d)"
            python3 -m pip download -q --no-deps --only-binary=:all: \
                --platform manylinux_2_28_x86_64 --platform manylinux_2_27_x86_64 --platform manylinux2014_x86_64 \
                --python-version 3.12 -d "${wheels}" \
                "nvidia-cuda-runtime-cu${major}<$((major + 1))" "nvidia-cublas-cu${major}<$((major + 1))" \
                || fail "CUDA runtime" "pip could not download the CUDA ${major} runtime wheels"
            for w in "${wheels}"/*.whl; do
                python3 - "${w}" "${install_dir}" "${major}" <<'PY'
import sys, zipfile
wheel, dest, major = sys.argv[1:]
want = {f"libcudart.so.{major}", f"libcublas.so.{major}", f"libcublasLt.so.{major}"}
z = zipfile.ZipFile(wheel)
for name in z.namelist():
    base = name.rsplit("/", 1)[-1]
    if base in want:
        open(f"{dest}/{base}", "wb").write(z.read(name))
PY
            done
            rm -rf "${wheels:?}"
        fi

        # The build may need a newer libstdc++ than the system provides (RHEL 9
        # ships GLIBCXX_3.4.29). A gcc module usually carries one; copy it
        # beside the binary so the job needs no module at run time.
        need="$(LD_LIBRARY_PATH="${install_dir}" ldd "${cuda_lib}" 2>&1 | grep -oE 'GLIBCXX_[0-9.]+[0-9]. not found' | grep -oE 'GLIBCXX_[0-9.]+[0-9]' | sort -V | tail -1)"
        if [ -n "${need}" ] && type module > /dev/null 2>&1; then
            for m in $(module -t avail gcc 2>&1 | grep -E '^gcc/' | sort -V -r); do
                module load "${m}" > /dev/null 2>&1 || continue
                lib="$(readlink -f "$(gcc -print-file-name=libstdc++.so.6)")"
                module unload "${m}" > /dev/null 2>&1
                if [ -f "${lib}" ] && grep -qa "${need}" "${lib}"; then
                    cp "${lib}" "${install_dir}/libstdc++.so.6"
                    echo "::notice title=libstdc++::Using ${need} from ${m}"
                    break
                fi
            done
        fi

        missing="$(LD_LIBRARY_PATH="${install_dir}" ldd "${cuda_lib}" 2>&1 | grep 'not found')"
        [ -z "${missing}" ] || fail "llama.cpp" "Unresolved libraries for the CUDA backend: ${missing}"
        chmod -R g+rX,o+rX "${target}" 2> /dev/null
        echo "${install_dir}" > "${target}/.ready"
    fi
    "${install_dir}/llama-server" --version 2>&1 | tail -2

    # Stage the GGUF files. A store that already holds every file is used as
    # is, even read-only; otherwise they are downloaded to the first writable one.
    repo_name="$(basename "${llamacpp_hf_repo}")"
    files=("${llamacpp_gguf_file}")
    [ "${llamacpp_vision}" = "true" ] && files+=("${llamacpp_mmproj_file}")
    [ "${llamacpp_speculative}" = "true" ] && files+=("${llamacpp_draft_file}")
    has_all() {
        local f
        for f in "${files[@]}"; do
            [ -s "$1/${repo_name}/${f}" ] && [ ! -e "$1/${repo_name}/${f}.part" ] || return 1
        done
    }
    stores=()
    if [ -n "${llamacpp_models_dir}" ]; then
        stores=("${llamacpp_models_dir/#\~/$HOME}")
    else
        for root in "${roots[@]}"; do stores+=("${root}/llamacpp/models"); done
    fi
    model_root=""
    for root in "${stores[@]}"; do has_all "${root}" && model_root="${root}" && break; done
    if [ -n "${model_root}" ]; then
        echo "::notice title=Models::Serving staged files from ${model_root}/${repo_name}"
    else
        for root in "${stores[@]}"; do writable_dir "${root}/${repo_name}" && model_root="${root}" && break; done
        [ -n "${model_root}" ] || fail "Models" "No writable model directory"
        dir="${model_root}/${repo_name}"
        todo=()
        for f in "${files[@]}"; do
            [ -s "${dir}/${f}" ] && [ ! -e "${dir}/${f}.part" ] || todo+=("${f}")
        done
        for f in "${todo[@]}"; do touch "${dir}/${f}.part"; done
        echo "::notice title=Models::Downloading ${todo[*]} from ${llamacpp_hf_repo} into ${dir}"
        # hf moves data in parallel chunks (about 25x a single curl stream in
        # testing). Install it once beside the models; keep its cache off home.
        export HF_HOME="${model_root}/.hf-home"
        hf_lib="${model_root}/.hf-cli"
        # The token goes through the environment and curl's stdin with the
        # trace off, so it reaches neither the step log nor a command line
        { set +x; } 2>/dev/null
        curl_auth=""
        if [ -n "${hf_token}" ]; then
            export HF_TOKEN="${hf_token}"
            curl_auth="header = \"Authorization: Bearer ${hf_token}\""
        fi
        set -x
        if [ -d "${hf_lib}/huggingface_hub" ] || python3 -m pip install -q --target "${hf_lib}" 'huggingface_hub[hf_xet]'; then
            PYTHONPATH="${hf_lib}" python3 -m huggingface_hub.cli.hf \
                download "${llamacpp_hf_repo}" "${todo[@]}" --local-dir "${dir}" \
                || fail "Models" "hf download failed"
        else
            echo "::warning title=Models::huggingface_hub could not be installed; falling back to curl"
            for f in "${todo[@]}"; do
                { set +x; } 2>/dev/null
                printf '%s\n' "${curl_auth}" | curl -fL -C - --config - \
                    -o "${dir}/${f}" "https://huggingface.co/${llamacpp_hf_repo}/resolve/main/${f}"
                rc=$?
                set -x
                [ "${rc}" -eq 0 ] || fail "Models" "Download of ${f} failed"
            done
        fi
        for f in "${todo[@]}"; do
            [ -s "${dir}/${f}" ] || fail "Models" "Download of ${f} failed"
            rm -f "${dir:?}/${f:?}.part"
            chmod g+r,o+r "${dir}/${f}" 2> /dev/null
        done
    fi
    dir="${model_root}/${repo_name}"
    {
        echo "export llamacpp_exec=\"${install_dir}/llama-server\""
        echo "export llamacpp_lib_dir=\"${install_dir}\""
        echo "export llamacpp_model_path=\"${dir}/${llamacpp_gguf_file}\""
        if [ "${llamacpp_vision}" = "true" ]; then
            echo "export llamacpp_mmproj_path=\"${dir}/${llamacpp_mmproj_file}\""
        fi
        if [ "${llamacpp_speculative}" = "true" ]; then
            echo "export llamacpp_draft_path=\"${dir}/${llamacpp_draft_file}\""
        fi
    } >> ./inputs.sh
    free_endpoint_name
    exit 0
fi

# ---------------------------------------------------------------------------
# vllm and sglang: Apptainer, the SIF image, and the caches they reuse
# ---------------------------------------------------------------------------
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
[ -n "${singularity_bin}" ] || fail "Error" "singularity/apptainer not found and could not be installed"
"${singularity_bin}" --version

oras_bin=""
for d in "${shared_root}" "${private_root}"; do
    if [ -x "${d}/tools/oras/oras" ]; then
        oras_bin="${d}/tools/oras/oras"
        break
    fi
done
if [ -z "${oras_bin}" ]; then
    pick_writable_dir tools/oras \
        || fail "Error" "neither ${shared_root} nor ${private_root} is writable; nowhere to install oras"
    echo "::group::oras Install"
    VER=1.2.0
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) fail "Error" "unsupported architecture $(uname -m)" ;;
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

# A container URI <registry>/<name>:<tag> maps to <name>.sif under
# containers/, so images staged by hand (or by rag-vllm, which uses the same
# layout) are found and reused; delete the file to force a re-pull after
# changing the tag
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
    [ -n "${pulled}" ] || fail "Error" "oras pull failed for ${uri} after ${attempt} attempts"
    pulled_sif=$(find "${pull_dir}" -name '*.sif' -type f | head -1)
    [ -s "${pulled_sif}" ] || fail "Error" "no SIF file found in ${uri}"
    mv "${pulled_sif}" "${target}"
    rm -rf "${pull_dir}"
    chmod a+r "${target}"
    echo "::endgroup::"
}

case "${engine}" in
    vllm) container_uri="${vllm_container_uri}" ;;
    sglang) container_uri="${sglang_container_uri}" ;;
esac
[ -n "${container_uri}" ] || fail "Error" "no container image given for ${engine}"
resolve_sif "${container_uri}" \
    || fail "Error" "neither ${shared_root} nor ${private_root} is writable; nowhere to store ${container_uri}"
container_sif="${sif}"
pull_sif "${container_uri}" "${container_sif}"
share "${container_sif}"

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

# SGLang compiles kernels at launch and records CUDA graphs with them: on an
# H100 NVL serving Inkling 2 Mini a cold start took 531 s and a start with
# these caches kept took 112 s. They are keyed by GPU architecture and
# kernel source, so one directory serves every node and every account.
kernel_cache_dir=""
if [ "${engine}" = "sglang" ]; then
    if pick_writable_dir cache/sglang; then
        kernel_cache_dir="${dir}"
        share "${kernel_cache_dir}"
    else
        echo "::warning::no writable directory for the SGLang kernel cache; every start compiles from scratch"
    fi
fi

# Same rule as prepare-model.sh, which downloads into it
if [ -z "${model_cache_dir}" ] || [ "${model_cache_dir}" = "undefined" ]; then
    model_cache_dir="${service_parent_install_dir}/models"
fi

{
    echo "export model_cache_dir=\"${model_cache_dir}\""
    echo "export container_sif=\"${container_sif}\""
    echo "export sandbox_dir=\"${container_sif%.sif}-sandbox\""
    echo "export tiktoken_dir=\"${tiktoken_dir}\""
    echo "export kernel_cache_dir=\"${kernel_cache_dir}\""
} >> ./inputs.sh
free_endpoint_name
