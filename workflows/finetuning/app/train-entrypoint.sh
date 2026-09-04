#!/usr/bin/env bash
# Runs INSIDE the container (invoked by app/start-template.sh via
# `singularity exec --nv`). Translates env vars into train.py CLI flags and
# runs training to completion in the foreground.
#
# Deliberately does NOT manage TensorBoard (unlike the legacy run_finetune.sh
# this replaces) -- that lifecycle now belongs to start-template.sh, which
# needs TensorBoard to be reachable only while this script runs, and to be
# able to tear it down independently once this script exits.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

: "${BASE_MODEL_ID:?BASE_MODEL_ID must be provided}"
: "${DATASET_SOURCE:=huggingface}"
: "${OUTPUT_DIR:=outputs}"
: "${STRATEGY:=single}"
: "${NUM_GPUS:=1}"

# STRATEGY/NUM_GPUS come from resolve_strategy's job outputs (yamls/general.yaml).
# single stays plain python3 (unchanged); ddp/fsdp launch one process per GPU
# via accelerate -- train.py itself branches its device placement on
# --strategy (device_map="auto" is wrong for both distributed cases, see
# resolve_device_map() there).
case "${STRATEGY}" in
    single)
        LAUNCH_PREFIX=(python3)
        ;;
    ddp)
        LAUNCH_PREFIX=(accelerate launch --multi_gpu --num_processes "${NUM_GPUS}")
        ;;
    fsdp)
        : "${FSDP_CONFIG:?FSDP_CONFIG must be provided when STRATEGY=fsdp}"
        LAUNCH_PREFIX=(accelerate launch --num_processes "${NUM_GPUS}" --config_file "${FSDP_CONFIG}")
        ;;
    *)
        echo "::error title=Error::unknown STRATEGY=${STRATEGY}" >&2
        exit 1
        ;;
esac

CMD=(
    "${LAUNCH_PREFIX[@]}" "${SCRIPT_DIR}/train.py"
    --strategy "${STRATEGY}"
    --model-profile "${MODEL_PROFILE:-custom}"
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
)

if [[ -n "${LORA_TARGET_MODULES:-}" ]]; then
    CMD+=(--lora-target-modules "${LORA_TARGET_MODULES}")
fi
if [[ -n "${TARGET_PARAMETERS_LAYERS:-}" ]]; then
    CMD+=(--target-parameters-layers "${TARGET_PARAMETERS_LAYERS}")
fi
if [[ -n "${QUANTIZATION:-}" ]]; then
    CMD+=(--quantization "${QUANTIZATION}")
fi
if [[ -n "${OPTIM:-}" ]]; then
    CMD+=(--optim "${OPTIM}")
fi

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

if [[ -n "${MAX_SAMPLES:-}" ]]; then CMD+=(--max-samples "${MAX_SAMPLES}"); fi
if [[ -n "${SEED:-}" ]]; then CMD+=(--seed "${SEED}"); fi
if [[ "${BF16:-false}" == "true" ]]; then CMD+=(--bf16); fi
if [[ "${PACKING:-false}" == "true" ]]; then CMD+=(--packing); fi
if [[ "${GRADIENT_CHECKPOINTING:-false}" == "true" ]]; then CMD+=(--gradient-checkpointing); fi
if [[ "${TRUST_REMOTE_CODE:-false}" == "true" ]]; then CMD+=(--trust-remote-code); fi
if [[ "${MERGE_FULL_WEIGHTS:-false}" == "true" ]]; then
    CMD+=(--merge-full-weights --merged-save-format "${MERGED_SAVE_FORMAT:-safetensors}")
fi
if [[ -n "${HUB_MODEL_ID:-}" ]]; then CMD+=(--hub-model-id "${HUB_MODEL_ID}"); fi
if [[ "${PUSH_TO_HUB:-false}" == "true" ]]; then CMD+=(--push-to-hub); fi
if [[ -n "${HF_TOKEN:-}" ]]; then export HF_TOKEN; CMD+=(--hf-token "${HF_TOKEN}"); fi
if [[ "${TENSORBOARD_ENABLED:-false}" == "true" ]]; then CMD+=(--tensorboard); fi
if [[ -n "${EVAL_SPLIT:-}" ]]; then CMD+=(--eval-split-fraction "${EVAL_SPLIT}"); fi
if [[ -n "${EVAL_STEPS:-}" ]]; then CMD+=(--eval-steps "${EVAL_STEPS}"); fi

export TRANSFORMERS_NO_ADVISORY_WARNINGS=1
export TRANSFORMERS_VERBOSITY=error
export TOKENIZERS_PARALLELISM=false

echo "::notice::Running: ${CMD[*]}"
exec "${CMD[@]}"
