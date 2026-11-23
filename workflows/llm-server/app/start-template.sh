# start-template.sh: start template for the llm-server workflow (yamls/*.yaml).
# Runs on the execution node with inputs.sh prepended (see the Create Service
# Script step). Launches the selected engine on a local port, waits for it to
# answer, and registers that port as an OpenAI-compatible pw endpoint.

set -x

endpoint_port=$(pw agent open-port)
svc_log="${PWD}/${engine}-${PW_JOB_ID}.out"
launcher="${PWD}/launch-${engine}-${PW_JOB_ID}.sh"
app_dir=${PW_PARENT_JOB_DIR}/workflows/llm-server/app

echo "::group::Preparing ${engine}"

if [ "${engine}" = "llamacpp" ]; then
    export LD_LIBRARY_PATH="${llamacpp_lib_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    if [ -n "${llamacpp_gpu_ids}" ]; then
        export CUDA_DEVICE_ORDER=PCI_BUS_ID
        export CUDA_VISIBLE_DEVICES="${llamacpp_gpu_ids}"
    fi
    devices="$("${llamacpp_exec}" --list-devices 2>&1)"
    echo "${devices}"
    if ! echo "${devices}" | grep -q 'CUDA0'; then
        echo "::error title=No GPU::llama-server sees no CUDA device on $(hostname). On a cluster, submit to the scheduler with a GPU request."
        exit 1
    fi

    served_model_name="$(basename "${llamacpp_model_path}" .gguf)"
    args=(--model "${llamacpp_model_path}" --alias "${served_model_name}"
          --ctx-size "${llamacpp_ctx_size:-0}" --host 127.0.0.1 --port "${endpoint_port}")
    [ -n "${llamacpp_mmproj_path}" ] && args+=(--mmproj "${llamacpp_mmproj_path}")
    if [ -n "${llamacpp_draft_path}" ]; then
        args+=(--model-draft "${llamacpp_draft_path}" --spec-type draft-dspark --spec-draft-n-max 3 --n-gpu-layers-draft 99)
    fi
    cat > "${launcher}" <<LAUNCHEOF
#!/bin/bash
exec ${llamacpp_exec} $(printf '%q ' "${args[@]}") ${llamacpp_extra_args}
LAUNCHEOF
    # llama-server answers /health with 503 while the model loads
    gate_url="localhost:${endpoint_port}/health"
else
    if ! command -v singularity >/dev/null 2>&1 && ! command -v apptainer >/dev/null 2>&1; then
        module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true
    fi
    singularity_bin=$(command -v singularity || command -v apptainer)
    if [ -z "${singularity_bin}" ]; then
        echo "::error title=Error::singularity/apptainer not found on the execution node"
        exit 1
    fi
    if [ ! -f "${container_sif}" ]; then
        echo "::error title=Error::Missing container image ${container_sif}"
        exit 1
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        if ! nvidia-smi -L; then
            echo "::error title=Error::no GPU visible on $(hostname); request GPUs with a scheduler directive such as '#SBATCH --gres=gpu:1'"
            exit 1
        fi
    else
        echo "::warning::nvidia-smi not found on $(hostname)"
    fi

    # prepare_model downloads into the cache from the form when it can write
    # it and into ${HOME}/pw/software/models otherwise (a shared cache is
    # usually owned by whoever staged it first); look in both
    private_models_dir="${HOME}/pw/software/models"
    find_model_dir() { # sets ${model_dir} to the first cache holding the model
        local name=$1 d
        for d in "${model_cache_dir/#\~/$HOME}" "${private_models_dir}"; do
            model_dir="${d}/${name}"
            [ -s "${model_dir}/config.json" ] && return 0
        done
        echo "::error title=Error::model ${name} not found in ${model_cache_dir/#\~/$HOME} or ${private_models_dir}"
        exit 1
    }
    if [ "${model_source}" = "local" ]; then
        model_dir="${model_local_path/#\~/$HOME}"
        served_model_name=$(basename "${model_dir}")
    elif [ "${model_source}" = "cached_model" ]; then
        find_model_dir "${cached_model_id##*/}"
        served_model_name="${cached_model_id}"
    else
        find_model_dir "${hf_model_id##*/}"
        served_model_name="${hf_model_id}"
    fi
    if [ ! -s "${model_dir}/config.json" ]; then
        echo "::error title=Error::model directory ${model_dir} is missing or incomplete"
        exit 1
    fi

    # Prefer running a SIF directly; some nodes cannot mount it (no squashfs
    # kernel/FUSE support), in which case unpack it once into a sandbox directory
    resolve_ref() {
        local sif=$1 sandbox=$2
        if "${singularity_bin}" exec "${sif}" /bin/true > /dev/null 2>&1; then
            echo "${sif}"
            return 0
        fi
        echo "::notice::Cannot mount ${sif} on this node; using a sandbox directory" >&2
        export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
        export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
        mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"
        if [ ! -d "${sandbox}/usr" ]; then
            # A shared containers directory is usually owned by whoever staged
            # the image, so the sandbox may have to be unpacked somewhere private
            if ! mkdir -p "${sandbox}" 2>/dev/null || [ ! -w "${sandbox}" ]; then
                sandbox="${HOME}/pw/software/containers/${sandbox##*/}"
                echo "::notice::Image directory is not writable; unpacking into ${sandbox}" >&2
                mkdir -p "${sandbox}"
            fi
            if [ ! -d "${sandbox}/usr" ]; then
                "${singularity_bin}" build --fakeroot --force --sandbox "${sandbox}" "${sif}" >&2 || return 1
            fi
        fi
        echo "${sandbox}"
    }
    container_ref=$(resolve_ref "${container_sif}" "${sandbox_dir}")
    if [ -z "${container_ref}" ]; then
        echo "::error title=Error::cannot run or unpack ${container_sif}"
        exit 1
    fi

    # Per-job /tmp: the host /tmp is often small and shared, and the job dir
    # path is too long for ZMQ IPC sockets, so tmp paths must be the short
    # in-container /tmp backed by this bind.
    # CC/CXX are pinned to the container's compilers: singularity passes the
    # host environment through, and sites export compilers the container
    # lacks (CC=icc on Jean, CC=CC, the Cray wrapper, on Makau), which breaks
    # Triton's driver stub and SGLang's kernel builds. The tiktoken directory
    # may be a read-only shared one, so harmony's cache goes to /tmp.
    mkdir -p "${PWD}/container_tmp"
    common=(--nv --writable-tmpfs
            --bind "${model_dir}:${model_dir}"
            --bind "${app_dir}:${app_dir}"
            --bind "${PWD}/container_tmp:/tmp"
            --bind "${tiktoken_dir}:${tiktoken_dir}"
            --env PYTHONNOUSERSITE=1 --env TRANSFORMERS_OFFLINE=1 --env HF_HUB_OFFLINE=1
            --env TIKTOKEN_ENCODINGS_BASE="${tiktoken_dir}"
            --env TIKTOKEN_RS_CACHE_DIR=/tmp/tiktoken_rs_cache
            --env TMPDIR=/tmp --env CC=gcc --env CXX=g++ --env CUDA_DEVICE_ORDER=PCI_BUS_ID)

    if [ "${engine}" = "sglang" ]; then
        # Compiled kernels persist in the shared cache (see controller.sh);
        # without one they go to the per-job /tmp and every start pays the
        # full compile
        kc="${kernel_cache_dir:-/tmp/sglang_cache}"
        if [ -n "${kernel_cache_dir}" ]; then
            common+=(--bind "${kernel_cache_dir}:${kernel_cache_dir}")
        fi
        common+=(--env SGLANG_CACHE_DIR="${kc}" --env SGLANG_JIT_CACHE_DIR="${kc}/jit"
                 --env TRITON_CACHE_DIR="${kc}/triton" --env XDG_CACHE_HOME="${kc}/xdg"
                 --env FLASHINFER_WORKSPACE_BASE="${kc}" --env CUDA_CACHE_PATH="${kc}/cuda")
        cmd=(python3 -m sglang.launch_server --model-path "${model_dir}"
             --served-model-name "${served_model_name}" --host 127.0.0.1 --port "${endpoint_port}")
        engine_args="${sglang_args}"
    else
        # vLLM's chat endpoint errors when the tokenizer ships no chat
        # template (base checkpoints such as OLMo). An explicit override wins;
        # otherwise fall back to the bundled template only if the model has
        # none, so a checkpoint's own template is never overridden.
        if [ -n "${chat_template_override}" ] && [ "${chat_template_override}" != "undefined" ]; then
            chat_template_path=${chat_template_override/#\~/$HOME}
            common+=(--bind "$(dirname "${chat_template_path}"):$(dirname "${chat_template_path}")")
            chat_template_arg="--chat-template ${chat_template_path}"
        elif ! grep -q '"chat_template"' "${model_dir}/tokenizer_config.json" 2>/dev/null \
             && [ ! -s "${model_dir}/chat_template.jinja" ]; then
            echo "::notice::${model_dir} has no chat_template; falling back to ${app_dir}/default_chat_template.jinja"
            chat_template_arg="--chat-template ${app_dir}/default_chat_template.jinja"
        fi
        common+=(--env CUDA_CACHE_PATH=/tmp/cuda_cache --env TORCH_EXTENSIONS_DIR=/tmp/torch_extensions
                 --env FLASHINFER_JIT_DIR=/tmp/flashinfer_jit --env TRITON_CACHE_DIR=/tmp/triton_cache)
        if [ -n "${vllm_attention_backend}" ] && [ "${vllm_attention_backend}" != "undefined" ]; then
            common+=(--env VLLM_ATTENTION_BACKEND="${vllm_attention_backend}")
        fi
        cmd=(python3 -m vllm.entrypoints.openai.api_server --model "${model_dir}"
             --served-model-name "${served_model_name}" --host 127.0.0.1 --port "${endpoint_port}")
        engine_args="${vllm_args} ${chat_template_arg}"
    fi

    # umask 002 keeps what SGLang adds to the shared kernel cache writable for
    # the rest of the project group. engine_args stays unquoted so it splits
    # into separate arguments.
    cat > "${launcher}" <<LAUNCHEOF
#!/bin/bash
umask 002
exec "${singularity_bin}" exec $(printf '%q ' "${common[@]}") \\
    "${container_ref}" \\
    $(printf '%q ' "${cmd[@]}") ${engine_args}
LAUNCHEOF
    # vLLM and SGLang answer /health with 200 only once the model is loaded
    gate_url="localhost:${endpoint_port}/health"
fi
chmod +x "${launcher}"
cat "${launcher}"
echo "::endgroup::"

echo "::group::Starting ${engine}"
"${launcher}" > "${svc_log}" 2>&1 &
svc_pid=$!

# Both the generic cleanup trap and script_submitter's cleanup run cancel.sh:
# the server must die on endpoint delete and on cancel-before-ready
cat > cancel.sh <<CANCELEOF
#!/bin/bash
kill ${svc_pid} 2>/dev/null || true
CANCELEOF
chmod +x cancel.sh

# Register the endpoint only once the service is answering: the platform
# chat reports the session as unreachable while the model is still loading
echo "Waiting for the service at ${gate_url} (log: ${svc_log})"

# Stream the service log while it starts, so model-loading progress shows up
# in the workflow logs; stopped once the service answers so the runtime log
# is not duplicated for the lifetime of the endpoint
tail -n +1 -F "${svc_log}" 2>/dev/null &
tail_pid=$!
stop_log_stream() {
    kill ${tail_pid} 2>/dev/null
    wait ${tail_pid} 2>/dev/null
}

elapsed=0
until curl -sf -o /dev/null --max-time 5 "${gate_url}"; do
    if ! kill -0 ${svc_pid} 2>/dev/null; then
        stop_log_stream
        echo "::error title=Error::service exited during startup; last log lines:"
        tail -50 "${svc_log}"
        exit 1
    fi
    if [ ${elapsed} -ge 3600 ]; then
        stop_log_stream
        echo "::error title=Error::service did not start within 60 minutes; last log lines:"
        tail -50 "${svc_log}"
        exit 1
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    if [ $((elapsed % 60)) -eq 0 ]; then
        echo "$(date) service still starting (${elapsed}s elapsed)"
    fi
done
stop_log_stream
echo "Service is answering at ${gate_url}; runtime log continues at ${svc_log}; registering endpoint"

# --link ties the port's server process to the endpoint: deleting the
# endpoint stops it even if the surrounding script is gone
pw endpoints http --link ${pw_endpoints_args} -o text ${endpoint_port}

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
