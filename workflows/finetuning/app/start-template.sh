#!/usr/bin/env bash
# start-template.sh — LoRA/QLoRA training behind a pw endpoint.
#
# TensorBoard is reachable at the endpoint's {port} only
# while training runs. Once training.py exits, train.py has already written
# a persistent offline report (report/metrics.json, PNG plots, report.html)
# under OUTPUT_DIR; this script then tears down TensorBoard and
# exits, so the run completes and the endpoint retires itself -- no dangling
# endpoint to remember to delete.

set -x

echo "::group::Finetuning Service Starting"

container_mode=${container_mode:-sif_path}
finetune_registry=${finetune_registry:-ghcr.io/parallelworks/finetune:latest}
registry_slug=$(printf '%s' "${finetune_registry}" | tr -c 'a-zA-Z0-9._-' '_')

service_parent_install_dir=${service_parent_install_dir/#\~/$HOME}
if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/${registry_slug}/finetune.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

container_sif=${service_parent_install_dir}/containers/${registry_slug}/finetune.sif
sandbox_dir=${service_parent_install_dir}/containers/${registry_slug}/finetune-sandbox

# Must mirror controller.sh's build-mode path exactly: that mode keys the
# cached image on the pin set, so an image built from requirements-tf5.txt is
# a distinct artifact. Recomputing it differently here would look for a file
# the controller never wrote.
if [ "${container_mode}" = "build" ]; then
    req_slug=$(printf '%s' "${container_requirements_file:-requirements.txt}" | tr -c 'a-zA-Z0-9._-' '_')
    container_sif=${service_parent_install_dir}/containers/${registry_slug}/finetune-${req_slug}.sif
    sandbox_dir=${service_parent_install_dir}/containers/${registry_slug}/finetune-${req_slug}-sandbox
fi

if [ "${container_mode}" = "sif_path" ]; then
    container_sif=${container_sif_path/#\~/$HOME}
fi

# Load singularity/apptainer if not already in PATH
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
else
    echo "::notice::singularity already available in PATH"
fi

if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif} (container_mode=${container_mode})"
    exit 1
fi

unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"

# app/ (checked out under PW_PARENT_JOB_DIR) and OUTPUT_DIR are not
# necessarily under $PWD (script_submitter runs this script from a
# subdirectory of the checkout, e.g. subworkflows/session_runner/step_0/) --
# bind both explicitly rather than relying on $PWD or Singularity's default
# $HOME auto-bind, same reasoning as streamlit's app_dir bind.
app_dir=${PW_PARENT_JOB_DIR}/workflows/finetuning/app
output_dir_resolved=${output_dir/#\~/$HOME}
mkdir -p "${output_dir_resolved}"

# base_model_id is a real local directory by this point for BOTH sources:
# controller.sh resolves model_source=huggingface to the flat directory the
# (already-completed, session_runner waited on it) prepare_model job
# downloaded into; model_source=local is already a directory the user
# pointed at. Fail fast with a clear error here rather than letting train.py
# fail deep inside the container with a less obvious traceback.
model_dir_resolved=${base_model_id/#\~/$HOME}
if [ ! -s "${model_dir_resolved}/config.json" ]; then
    echo "::error title=Error::model directory ${model_dir_resolved} is missing or incomplete (model_source=${model_source:-huggingface})"
    exit 1
fi

if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    echo "::notice::SIF image is runnable on this node"
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; using sandbox directory"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then
        echo "Building finetune sandbox..."
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi

# Written before anything is backgrounded: a mid-training manual cancel must
# be able to kill training + TensorBoard, both of which escape the
# single `pw endpoints run -- ./launch-service.sh` process tree as detached
# background siblings (see launch-service.sh below).
cat > cancel.sh << 'CANCELEOF'
#!/usr/bin/env bash
[ -f "$PWD/train.pid" ] && kill "$(cat "$PWD/train.pid")" 2>/dev/null
[ -f "$PWD/tb.pid" ] && kill "$(cat "$PWD/tb.pid")" 2>/dev/null
exit 0
CANCELEOF
chmod +x cancel.sh

cat > launch-service.sh << LAUNCHEOF
#!/usr/bin/env bash
set -x
PORT="\${1}"

# --host 127.0.0.1, NOT --bind_all: --bind_all listens on 0.0.0.0 with no
# authentication, which hands the whole logdir (loss curves, eval metrics,
# hyperparameters) to anyone who can reach this node, bypassing the
# endpoint's auth entirely. pw endpoints run tunnels from this same node over
# loopback, so the endpoint still reaches it.
# Subdomain endpoints serve at the root (PW_ENDPOINT_PATH=/), where
# TensorBoard's relative asset URLs just work. Path-based endpoints
# (--no-subdomain) forward the full path, so give TensorBoard that prefix.
tb_path_prefix="\${PW_ENDPOINT_PATH%/}"
singularity exec --writable-tmpfs \\
    --bind "${output_dir_resolved}:${output_dir_resolved}" \\
    --bind "${PWD}/container_tmp:/tmp" \\
    "${container_ref}" \\
    tensorboard --logdir "${output_dir_resolved}" --port "\${PORT}" --host 127.0.0.1 \\
    \${tb_path_prefix:+--path_prefix "\${tb_path_prefix}"} \\
    > "${PWD}/tb.log" 2>&1 &
echo \$! > "${PWD}/tb.pid"

# Training runs in the FOREGROUND -- this is what the launcher blocks on.
# When it exits, TensorBoard is torn down and so is the endpoint.
# train-entrypoint.sh/train.py read UPPERCASE env vars (legacy convention,
# unchanged); inputs.sh (sourced ahead of this script, see yamls/general.yaml)
# exports lowercase snake_case vars (streamlit's convention) -- bridge here.
export MODEL_PROFILE="${model_profile}"
export BASE_MODEL_ID="${model_dir_resolved}"
export DATASET_SOURCE="local"
export LOCAL_DATASET_PATH="${local_dataset_path}"
export DATASET_FORMAT="${dataset_format}"
export PROMPT_FIELD="${prompt_field}"
export OUTPUT_DIR="${output_dir_resolved}"
export NUM_EPOCHS="${num_epochs}"
export LEARNING_RATE="${learning_rate}"
export MICRO_BATCH_SIZE="${micro_batch_size}"
export GRADIENT_ACCUMULATION="${gradient_accumulation}"
export MAX_SEQ_LENGTH="${max_seq_length}"
export LORA_R="${lora_r}"
export LORA_ALPHA="${lora_alpha}"
export LORA_DROPOUT="${lora_dropout}"
export QUANTIZATION="${quantization:-}"
export LORA_TARGET_MODULES="${lora_targets_override:-}"
export EVAL_SPLIT="${eval_split_fraction}"
export EVAL_STEPS="${eval_steps}"
export MERGE_FULL_WEIGHTS="${merge_full_weights}"
export TENSORBOARD_ENABLED="${tensorboard_enabled}"
# Read from the 0600 sidecar at launch time with xtrace off, rather than
# interpolated here: this heredoc becomes launch-service.sh, a plaintext file
# that persists in the job dir, and `set -x` above would otherwise trace the
# token into the run log the platform collects.
set +x
export HF_TOKEN="\$(cat "${hf_token_file:-/dev/null}" 2>/dev/null || true)"
set -x
export OPTIM="${optim:-}"
export GRADIENT_CHECKPOINTING="${gradient_checkpointing:-false}"
export BF16="${bf16:-false}"
export RESPONSE_TEMPLATE="${response_template:-}"
export STRATEGY="${strategy:-single}"
export NUM_GPUS="${num_gpus:-1}"
export FSDP_CONFIG="${app_dir}/fsdp_config.yaml"

set +e
singularity exec --nv --writable-tmpfs \\
    --bind "${app_dir}:${app_dir}" \\
    --bind "${output_dir_resolved}:${output_dir_resolved}" \\
    --bind "${model_dir_resolved}:${model_dir_resolved}" \\
    --bind "${PWD}/container_tmp:/tmp" \\
    "${container_ref}" \\
    bash "${app_dir}/train-entrypoint.sh" \\
    > "${PWD}/train.log" 2>&1 &
train_pid=\$!
echo \${train_pid} > "${PWD}/train.pid"
wait \${train_pid}
train_rc=\$?
set -e

kill "\$(cat "${PWD}/tb.pid")" 2>/dev/null || true

exit \${train_rc}
LAUNCHEOF
chmod 700 launch-service.sh

echo "::endgroup::"
echo "::group::Starting Finetuning Service"

pw endpoints run ${pw_endpoints_args} -- ./launch-service.sh {port}
rc=$?

if [ ${rc} -ne 0 ]; then
    # Distinguish a genuine launch failure from a mid-training manual cancel
    # (the streamlit-established pattern -- pw endpoints run also returns
    # non-zero when the workflow cancels this job after a successful launch).
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed (training script exited ${rc})"
    exit 1
fi
echo "::notice::Training completed normally; report written under ${output_dir_resolved}/report"
echo "::endgroup::"
