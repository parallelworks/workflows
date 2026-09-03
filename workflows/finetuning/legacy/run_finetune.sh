#!/usr/bin/env bash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
LOG_DIR="${REPO_ROOT}/logs"

# TensorBoard configuration
TENSORBOARD_ENABLED="${TENSORBOARD_ENABLED:-false}"
TENSORBOARD_PORT="${TENSORBOARD_PORT:-6006}"
TENSORBOARD_PATH_PREFIX="${TENSORBOARD_PATH_PREFIX:-}"
TENSORBOARD_BIND_ALL="${TENSORBOARD_BIND_ALL:-false}"
TENSORBOARD_PID=""

# OUTPUT_DIR is set by the calling script/environment
# TensorBoard logs go to ${OUTPUT_DIR}/tensorboard (same as pw_finetune.py)
TB_LOG_DIR="${OUTPUT_DIR:-/output}/tensorboard"
mkdir -p "${LOG_DIR}" "${TB_LOG_DIR}"

start_tensorboard() {
    echo "Starting TensorBoard on port ${TENSORBOARD_PORT}..."
    local tb_args=(
        --logdir "${TB_LOG_DIR}"
        --port "${TENSORBOARD_PORT}"
    )
    
    if [[ "${TENSORBOARD_BIND_ALL}" == "true" ]]; then
        tb_args+=(--bind_all)
    fi
    
    if [[ -n "${TENSORBOARD_PATH_PREFIX}" ]]; then
        tb_args+=(--path_prefix "${TENSORBOARD_PATH_PREFIX}")
    fi
    
    tensorboard "${tb_args[@]}" &
    TENSORBOARD_PID=$!
    echo "TensorBoard started with PID ${TENSORBOARD_PID}"
    
    # Give TensorBoard time to start
    sleep 2
    
    if [[ "${TENSORBOARD_BIND_ALL}" == "true" ]]; then
        echo "TensorBoard available at: http://0.0.0.0:${TENSORBOARD_PORT}${TENSORBOARD_PATH_PREFIX:-/}"
    else
        echo "TensorBoard available at: http://localhost:${TENSORBOARD_PORT}${TENSORBOARD_PATH_PREFIX:-/}"
    fi
}

stop_tensorboard() {
    if [[ -n "${TENSORBOARD_PID}" ]]; then
        echo "Stopping TensorBoard (PID ${TENSORBOARD_PID})..."
        kill "${TENSORBOARD_PID}" 2>/dev/null || true
        wait "${TENSORBOARD_PID}" 2>/dev/null || true
    fi
}

cleanup() {
    echo "Cleaning up..."
    stop_tensorboard
}

trap cleanup EXIT INT TERM

: "${BASE_MODEL_ID:?BASE_MODEL_ID must be provided}"
: "${DATASET_SOURCE:=huggingface}"
: "${OUTPUT_DIR:=outputs}"

CMD=(
    python "${SCRIPT_DIR}/pw_finetune.py"
    --base-model-id "${BASE_MODEL_ID}"
    --dataset-source "${DATASET_SOURCE}"
    --output-dir "${OUTPUT_DIR}"
    --dataset-split "${DATASET_SPLIT:-train}"
    --prompt-field "${PROMPT_FIELD:-prompt}"
    --num-epochs "${NUM_EPOCHS:-3.0}"
    --learning-rate "${LEARNING_RATE:-2e-4}"
    --weight-decay "${WEIGHT_DECAY:-0.0}"
    --warmup-steps "${WARMUP_STEPS:-50}"
    --micro-batch-size "${MICRO_BATCH_SIZE:-1}"
    --gradient-accumulation "${GRADIENT_ACCUMULATION:-16}"
    --max-seq-length "${MAX_SEQ_LENGTH:-2048}"
    --logging-steps "${LOGGING_STEPS:-10}"
    --save-steps "${SAVE_STEPS:-200}"
    --save-total-limit "${SAVE_TOTAL_LIMIT:-3}"
    --lora-r "${LORA_R:-64}"
    --lora-alpha "${LORA_ALPHA:-16}"
    --lora-dropout "${LORA_DROPOUT:-0.05}"
    --lora-target-modules "${LORA_TARGET_MODULES:-q_proj,k_proj,v_proj,o_proj,up_proj,down_proj,gate_proj}"
    --quantization "${QUANTIZATION:-4bit}"
)

# Dataset-specific parameters
if [[ "${DATASET_SOURCE}" == "huggingface" ]]; then
    : "${DATASET_NAME:?DATASET_NAME must be provided for huggingface source}"
    CMD+=(--dataset-name "${DATASET_NAME}")
    if [[ -n "${DATASET_CONFIG_NAME:-}" ]]; then
        CMD+=(--dataset-config "${DATASET_CONFIG_NAME}")
    fi
elif [[ "${DATASET_SOURCE}" == "local" ]]; then
    : "${LOCAL_DATASET_PATH:?LOCAL_DATASET_PATH must be provided for local source}"
    CMD+=(--local-dataset-path "${LOCAL_DATASET_PATH}")
    CMD+=(--dataset-format "${DATASET_FORMAT:-json}")
elif [[ "${DATASET_SOURCE}" == "bucket" ]]; then
    : "${DATASET_DIR:?DATASET_DIR must be provided for bucket source}"
    CMD+=(--dataset-dir "${DATASET_DIR}")
fi

if [[ -n "${MAX_SAMPLES:-}" ]]; then
    CMD+=(--max-samples "${MAX_SAMPLES}")
fi
if [[ -n "${SEED:-}" ]]; then
    CMD+=(--seed "${SEED}")
fi
if [[ "${BF16:-false}" == "true" ]]; then
    CMD+=(--bf16)
fi
if [[ "${PACKING:-false}" == "true" ]]; then
    CMD+=(--packing)
fi
if [[ "${GRADIENT_CHECKPOINTING:-false}" == "true" ]]; then
    CMD+=(--gradient-checkpointing)
fi
if [[ "${TRUST_REMOTE_CODE:-false}" == "true" ]]; then
    CMD+=(--trust-remote-code)
fi
if [[ "${MERGE_FULL_WEIGHTS:-false}" == "true" ]]; then
    CMD+=(--merge-full-weights)
    CMD+=(--merged-save-format "${MERGED_SAVE_FORMAT:-safetensors}")
fi
if [[ -n "${HUB_MODEL_ID:-}" ]]; then
    CMD+=(--hub-model-id "${HUB_MODEL_ID}")
fi
if [[ "${PUSH_TO_HUB:-false}" == "true" ]]; then
    CMD+=(--push-to-hub)
fi
if [[ -n "${HF_TOKEN:-}" ]]; then
    export HF_TOKEN
    CMD+=(--hf-token "${HF_TOKEN}")
fi

# Add TensorBoard logging if enabled
if [[ "${TENSORBOARD_ENABLED}" == "true" ]]; then
    CMD+=(--tensorboard)
fi

export TRANSFORMERS_NO_ADVISORY_WARNINGS=1
export TRANSFORMERS_VERBOSITY=error
export TOKENIZERS_PARALLELISM=false

# Start TensorBoard if enabled (skip if already running externally)
if [[ "${TENSORBOARD_ENABLED}" == "true" ]]; then
    if nc -z localhost "${TENSORBOARD_PORT}" 2>/dev/null; then
        echo "TensorBoard already running on port ${TENSORBOARD_PORT} (managed externally)"
    else
        start_tensorboard
    fi
fi

LOG_FILE="${LOG_DIR}/finetune.log"
"${CMD[@]}" 2>&1 | tee "${LOG_FILE}"
