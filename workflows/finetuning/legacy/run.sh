#!/bin/bash
# ==============================================================================
# Medical LLM Fine-tuning Runner
# ==============================================================================
# Unified entry point for fine-tuning - works both locally and in PW workflows.
# Accepts configuration via environment variables (for workflows) or CLI args.
#
# Usage:
#   ./scripts/run.sh [--config PRESET] [OPTIONS]
#
# Options:
#   --config PRESET      Configuration preset (llama3-8b-medical, etc.)
#   --dataset-source     huggingface, local, or bucket (default: huggingface)
#   --dataset-name       HuggingFace dataset name
#   --local-dataset      Path to local dataset
#   --output-dir         Output directory (default: ./output)
#   --sif-path           Path to Singularity SIF file
#   --build-container    Force rebuild container
#   --max-samples        Limit samples for testing (default: 0 = all)
#   --epochs             Number of epochs (default: from preset or 3.0)
#   --help, -h           Show help message
#
# Examples:
#   # Quick test with 100 samples
#   ./scripts/run.sh --config llama3-8b-medical-quick --max-samples 100
#
#   # Full training with local dataset
#   ./scripts/run.sh --dataset-source local --local-dataset ./data.jsonl
#
#   # Use existing container
#   ./scripts/run_local.sh --sif-path ~/pw/singularity/finetune.sif
# ==============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_ROOT="$(dirname "${SCRIPT_DIR}")"

# Default values (environment variables take precedence, then CLI args)
CONFIG="${CONFIG:-}"
# MODEL_ID can come from MODEL_ID or BASE_MODEL_ID env var
: "${MODEL_ID:=${BASE_MODEL_ID:-}}"
DATASET_SOURCE="${DATASET_SOURCE:-huggingface}"
DATASET_NAME="${DATASET_NAME:-Shekswess/medical_llama3_instruct_dataset_short}"
LOCAL_DATASET_PATH="${LOCAL_DATASET_PATH:-}"
DATASET_FORMAT="${DATASET_FORMAT:-json}"
DATASET_SPLIT="${DATASET_SPLIT:-train}"
DATASET_CACHE_DIR="${DATASET_CACHE_DIR:-${HF_DATASETS_CACHE:-${HOME}/pw/datasets}}"
PROMPT_FIELD="${PROMPT_FIELD:-prompt}"
OUTPUT_DIR="${OUTPUT_DIR:-${WORKFLOW_ROOT}/output}"
SIF_PATH="${SIF_PATH:-${HOME}/pw/singularity/finetune.sif}"
DEF_FILE="${DEF_FILE:-${WORKFLOW_ROOT}/singularity/finetune.def}"
BUILD_CONTAINER="${BUILD_CONTAINER:-false}"
MAX_SAMPLES="${MAX_SAMPLES:-0}"
NUM_EPOCHS="${NUM_EPOCHS:-}"
MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-}"
LEARNING_RATE="${LEARNING_RATE:-}"
MICRO_BATCH_SIZE="${MICRO_BATCH_SIZE:-}"
GRADIENT_ACCUMULATION="${GRADIENT_ACCUMULATION:-}"
LORA_R="${LORA_R:-}"
LORA_ALPHA="${LORA_ALPHA:-}"
LORA_DROPOUT="${LORA_DROPOUT:-}"
QUANTIZATION="${QUANTIZATION:-4bit}"
BF16="${BF16:-false}"
GRADIENT_CHECKPOINTING="${GRADIENT_CHECKPOINTING:-false}"
PACKING="${PACKING:-false}"
MERGE_FULL_WEIGHTS="${MERGE_FULL_WEIGHTS:-true}"
MERGED_SAVE_FORMAT="${MERGED_SAVE_FORMAT:-safetensors}"
HF_TOKEN="${HF_TOKEN:-}"
# TENSORBOARD can come from TENSORBOARD_ENABLED or TENSORBOARD env var
TENSORBOARD="${TENSORBOARD_ENABLED:-${TENSORBOARD:-false}}"
[[ "${TENSORBOARD}" == "true" ]] && TENSORBOARD=true
TENSORBOARD_PORT="${TENSORBOARD_PORT:-6006}"
TENSORBOARD_PATH_PREFIX="${TENSORBOARD_PATH_PREFIX:-}"
TENSORBOARD_BIND_ALL="${TENSORBOARD_BIND_ALL:-false}"
[[ "${TENSORBOARD_BIND_ALL}" == "true" ]] && TENSORBOARD_BIND_ALL=true

# ==============================================================================
# Functions
# ==============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_usage() {
    cat << EOF
Usage: $0 [--config PRESET] [OPTIONS]

Execute the medical LLM fine-tuning workflow.

Options:
  --config PRESET      Configuration preset:
                        - llama3-8b-medical (default)
                        - llama3-8b-medical-quick
                        - mistral-7b-medical
                        - gemma-7b-medical
  --dataset-source     Dataset source: huggingface, local, or bucket (default: huggingface)
  --dataset-name       HuggingFace dataset name
  --local-dataset      Path to local dataset file
  --dataset-format     Format for local dataset (json, csv, parquet, etc.)
  --output-dir         Output directory (default: ./output)
  --sif-path           Path to Singularity SIF file
  --build-container    Force rebuild container
  --max-samples N      Limit samples for testing (default: 0 = all)
  --epochs N           Number of epochs (overrides preset)
  --max-seq-length N   Maximum sequence length (default: 2048, quick preset: 512)
  --model-id MODEL     HuggingFace model ID
  --hf-token TOKEN     HuggingFace access token
  --tensorboard        Enable TensorBoard for training visualization
  --tensorboard-port   TensorBoard server port (default: 6006)
  --tensorboard-prefix Path prefix for reverse proxy (e.g., /tensorboard)
  --tensorboard-bind-all  Bind TensorBoard to 0.0.0.0 for remote access
  --help, -h           Show this help

Examples:
  # Quick test with preset (100 samples)
  $0 --config llama3-8b-medical-quick --max-samples 100

  # Full training with HuggingFace dataset
  $0 --config llama3-8b-medical --dataset-name "org/dataset"

  # Use local dataset
  $0 --dataset-source local --local-dataset ./data.jsonl

  # Use specific model with 1 epoch
  $0 --model-id "mistralai/Mistral-7B-v0.1" --epochs 1

  # Training with TensorBoard visualization
  $0 --config llama3-8b-medical-quick --tensorboard

Configuration Presets:
  llama3-8b-medical       - Llama 3 8B, full dataset, 3 epochs
  llama3-8b-medical-quick - Llama 3 8B, 500 samples, 1 epoch
  mistral-7b-medical      - Mistral 7B, full dataset, 3 epochs
  gemma-7b-medical        - Gemma 7B, full dataset, 3 epochs
EOF
}

# ==============================================================================
# Configuration Presets
# ==============================================================================

apply_preset() {
    local preset="$1"
    # Presets only apply if env vars aren't already set
    case "${preset}" in
        llama3-8b-medical)
            DATASET_NAME="${DATASET_NAME:-Shekswess/medical_llama3_instruct_dataset}"
            NUM_EPOCHS="${NUM_EPOCHS:-3.0}"
            MAX_SAMPLES="${MAX_SAMPLES:-0}"
            MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-2048}"
            ;;
        llama3-8b-medical-quick)
            DATASET_NAME="${DATASET_NAME:-Shekswess/medical_llama3_instruct_dataset_short}"
            NUM_EPOCHS="${NUM_EPOCHS:-1.0}"
            MAX_SAMPLES="${MAX_SAMPLES:-50}"
            MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-512}"
            BF16="${BF16:-true}"
            ;;
        mistral-7b-medical)
            DATASET_NAME="${DATASET_NAME:-Shekswess/medical_mistral_instruct_dataset}"
            NUM_EPOCHS="${NUM_EPOCHS:-3.0}"
            MAX_SAMPLES="${MAX_SAMPLES:-0}"
            MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-2048}"
            ;;
        gemma-7b-medical)
            DATASET_NAME="${DATASET_NAME:-Shekswess/medical_gemma_instruct_dataset}"
            NUM_EPOCHS="${NUM_EPOCHS:-3.0}"
            MAX_SAMPLES="${MAX_SAMPLES:-0}"
            MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-2048}"
            ;;
        *)
            log_warning "Unknown preset: ${preset}"
            ;;
    esac
}

# ==============================================================================
# Environment Setup
# ==============================================================================

check_requirements() {
    log_info "Checking requirements..."

    # Check for singularity/apptainer
    if command -v singularity &> /dev/null; then
        SINGULARITY_CMD="singularity"
        log_success "Found singularity"
    elif command -v apptainer &> /dev/null; then
        SINGULARITY_CMD="apptainer"
        log_success "Found apptainer"
    else
        log_error "Neither singularity nor apptainer found"
        log_info "Install Singularity: https://sylabs.io/guides/3.7/user-guide/installation.html"
        exit 1
    fi

    # Check for NVIDIA GPU (optional but recommended)
    if command -v nvidia-smi &> /dev/null; then
        log_success "NVIDIA GPU detected"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | while read line; do
            log_info "  GPU: ${line}"
        done
    else
        log_warning "No NVIDIA GPU detected - training will be very slow or may fail"
    fi

    # Check CUDA
    if command -v nvcc &> /dev/null; then
        log_success "CUDA compiler found"
    else
        log_warning "nvcc not found - CUDA may not be properly installed"
    fi
}

setup_output_dir() {
    log_info "Setting up output directory: ${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}/.cache/huggingface"
    mkdir -p "${OUTPUT_DIR}/logs"
    log_success "Output directory ready"
}

# ==============================================================================
# Container Management
# ==============================================================================

ensure_container() {
    log_info "Checking Singularity container..."

    if [[ "${BUILD_CONTAINER}" == "true" ]]; then
        log_info "Building container from ${DEF_FILE}..."
        mkdir -p "$(dirname "${SIF_PATH}")"

        if ${SINGULARITY_CMD} build "${SIF_PATH}" "${DEF_FILE}"; then
            log_success "Container built successfully"
            return 0
        else
            log_error "Container build failed"
            log_info "Try: sudo ${SINGULARITY_CMD} build ${SIF_PATH} ${DEF_FILE}"
            exit 1
        fi
    fi

    if [[ -e "${SIF_PATH}" ]]; then
        log_success "Using container: ${SIF_PATH}"
        return 0
    fi

    log_error "Container not found: ${SIF_PATH}"
    log_info "Build it with: ./scripts/build_container.sh"
    log_info "Or use --build-container flag"
    exit 1
}

# ==============================================================================
# TensorBoard (runs inside container with training)
# ==============================================================================

show_tensorboard_info() {
    if [[ "${TENSORBOARD}" != true ]]; then
        return 0
    fi

    local tb_url
    if [[ "${TENSORBOARD_BIND_ALL}" == true ]]; then
        tb_url="http://0.0.0.0:${TENSORBOARD_PORT}"
    else
        tb_url="http://localhost:${TENSORBOARD_PORT}"
    fi

    if [[ -n "${TENSORBOARD_PATH_PREFIX}" ]]; then
        tb_url="${tb_url}${TENSORBOARD_PATH_PREFIX}"
    fi

    log_info "TensorBoard will start inside the container"
    log_info "  URL: ${tb_url}"
    log_info "  Log directory: ${OUTPUT_DIR}/logs"
}

# ==============================================================================
# Training Execution
# ==============================================================================

run_training() {
    log_info "Starting fine-tuning..."
    log_info "Output directory: ${OUTPUT_DIR}"
    log_info "Dataset source: ${DATASET_SOURCE}"
    log_info "Max samples: ${MAX_SAMPLES}"

    # Build command arguments
    local cmd_args=()
    cmd_args+=("--base-model-id" "${MODEL_ID:-meta-llama/Llama-3.1-8B-Instruct}")
    cmd_args+=("--output-dir" "${OUTPUT_DIR}")
    cmd_args+=("--num-epochs" "${NUM_EPOCHS:-3.0}")
    cmd_args+=("--max-samples" "${MAX_SAMPLES}")
    cmd_args+=("--quantization" "4bit")
    cmd_args+=("--merge-full-weights")
    cmd_args+=("--bf16")

    # Add max sequence length if specified
    if [[ -n "${MAX_SEQ_LENGTH:-}" ]]; then
        cmd_args+=("--max-seq-length" "${MAX_SEQ_LENGTH}")
    fi

    # Add TensorBoard flag if enabled
    if [[ "${TENSORBOARD}" == true ]]; then
        cmd_args+=("--tensorboard")
    fi

    # Dataset arguments
    cmd_args+=("--dataset-source" "${DATASET_SOURCE}")

    if [[ "${DATASET_SOURCE}" == "huggingface" ]]; then
        cmd_args+=("--dataset-name" "${DATASET_NAME}")
    elif [[ "${DATASET_SOURCE}" == "local" ]]; then
        if [[ -z "${LOCAL_DATASET_PATH}" ]]; then
            log_error "Local dataset path required for local source"
            exit 1
        fi
        cmd_args+=("--local-dataset-path" "${LOCAL_DATASET_PATH}")
        cmd_args+=("--dataset-format" "${DATASET_FORMAT}")
    fi

    # Add HF token if provided
    if [[ -n "${HF_TOKEN:-}" ]]; then
        cmd_args+=("--hf-token" "${HF_TOKEN}")
    fi

    # Display configuration
    log_info "Training configuration:"
    log_info "  Model: ${MODEL_ID:-meta-llama/Llama-3.1-8B-Instruct}"
    log_info "  Epochs: ${NUM_EPOCHS:-3.0}"
    log_info "  Max samples: ${MAX_SAMPLES}"

    # Prepare environment
    local training_env="${OUTPUT_DIR}/training.env"
    cat > "${training_env}" << EOF
# Training environment generated by run_local.sh
export OUTPUT_DIR="${OUTPUT_DIR}"
export HF_HOME="${OUTPUT_DIR}/.cache/huggingface"
export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
EOF

    # Execute training in container
    log_info "Executing training in Singularity container..."

    local singularity_opts=()
    singularity_opts+=("--nv")
    singularity_opts+=("--writable-tmpfs")
    singularity_opts+=("--bind" "${WORKFLOW_ROOT}:/workspace")
    singularity_opts+=("--bind" "${OUTPUT_DIR}:/output")
    singularity_opts+=("--env" "HF_HOME=/workspace/.cache/huggingface")

    # Pass HF token to container if set
    if [[ -n "${HF_TOKEN:-}" ]]; then
        singularity_opts+=("--env" "HF_TOKEN=${HF_TOKEN}")
    fi

    # Pass TensorBoard configuration to container
    if [[ "${TENSORBOARD}" == true ]]; then
        singularity_opts+=("--env" "TENSORBOARD_ENABLED=true")
        singularity_opts+=("--env" "TENSORBOARD_PORT=${TENSORBOARD_PORT}")
        if [[ -n "${TENSORBOARD_PATH_PREFIX}" ]]; then
            singularity_opts+=("--env" "TENSORBOARD_PATH_PREFIX=${TENSORBOARD_PATH_PREFIX}")
        fi
        if [[ "${TENSORBOARD_BIND_ALL}" == true ]]; then
            singularity_opts+=("--env" "TENSORBOARD_BIND_ALL=true")
        fi
    fi

    # Bind dataset cache directory and pass HF_DATASETS_CACHE
    mkdir -p "${DATASET_CACHE_DIR}"
    singularity_opts+=("--bind" "${DATASET_CACHE_DIR}:/workspace/datasets")
    singularity_opts+=("--env" "HF_DATASETS_CACHE=/workspace/datasets")

    # Bind-mount local model directory into the container if MODEL_ID is a local path
    local container_model_id="${MODEL_ID:-meta-llama/Llama-3.1-8B-Instruct}"
    if [[ -d "${container_model_id}" ]]; then
        local model_basename
        model_basename="$(basename "${container_model_id}")"
        singularity_opts+=("--bind" "${container_model_id}:/models/${model_basename}")
        container_model_id="/models/${model_basename}"
        log_info "Bind-mounting local model: ${MODEL_ID} -> ${container_model_id}"
    fi

    # Pass training configuration as environment variables for run_finetune.sh
    singularity_opts+=("--env" "BASE_MODEL_ID=${container_model_id}")
    singularity_opts+=("--env" "DATASET_SOURCE=${DATASET_SOURCE}")
    singularity_opts+=("--env" "OUTPUT_DIR=/output")
    singularity_opts+=("--env" "DATASET_SPLIT=${DATASET_SPLIT:-train}")
    singularity_opts+=("--env" "PROMPT_FIELD=${PROMPT_FIELD:-prompt}")
    singularity_opts+=("--env" "NUM_EPOCHS=${NUM_EPOCHS:-3.0}")
    singularity_opts+=("--env" "MAX_SAMPLES=${MAX_SAMPLES}")
    singularity_opts+=("--env" "QUANTIZATION=${QUANTIZATION:-4bit}")
    singularity_opts+=("--env" "MERGE_FULL_WEIGHTS=${MERGE_FULL_WEIGHTS:-true}")
    singularity_opts+=("--env" "MERGED_SAVE_FORMAT=${MERGED_SAVE_FORMAT:-safetensors}")
    singularity_opts+=("--env" "BF16=${BF16:-true}")
    singularity_opts+=("--env" "GRADIENT_CHECKPOINTING=${GRADIENT_CHECKPOINTING:-false}")
    singularity_opts+=("--env" "PACKING=${PACKING:-false}")

    # Pass optional hyperparameters if set
    [[ -n "${MAX_SEQ_LENGTH:-}" ]] && singularity_opts+=("--env" "MAX_SEQ_LENGTH=${MAX_SEQ_LENGTH}")
    [[ -n "${LEARNING_RATE:-}" ]] && singularity_opts+=("--env" "LEARNING_RATE=${LEARNING_RATE}")
    [[ -n "${MICRO_BATCH_SIZE:-}" ]] && singularity_opts+=("--env" "MICRO_BATCH_SIZE=${MICRO_BATCH_SIZE}")
    [[ -n "${GRADIENT_ACCUMULATION:-}" ]] && singularity_opts+=("--env" "GRADIENT_ACCUMULATION=${GRADIENT_ACCUMULATION}")
    [[ -n "${LORA_R:-}" ]] && singularity_opts+=("--env" "LORA_R=${LORA_R}")
    [[ -n "${LORA_ALPHA:-}" ]] && singularity_opts+=("--env" "LORA_ALPHA=${LORA_ALPHA}")
    [[ -n "${LORA_DROPOUT:-}" ]] && singularity_opts+=("--env" "LORA_DROPOUT=${LORA_DROPOUT}")

    if [[ "${DATASET_SOURCE}" == "huggingface" ]]; then
        singularity_opts+=("--env" "DATASET_NAME=${DATASET_NAME}")
    elif [[ "${DATASET_SOURCE}" == "local" ]]; then
        singularity_opts+=("--env" "LOCAL_DATASET_PATH=/workspace/${LOCAL_DATASET_PATH#${WORKFLOW_ROOT}/}")
        singularity_opts+=("--env" "DATASET_FORMAT=${DATASET_FORMAT}")
    elif [[ "${DATASET_SOURCE}" == "bucket" ]]; then
        singularity_opts+=("--env" "DATASET_DIR=/workspace/dataset")
    fi

    ${SINGULARITY_CMD} exec "${singularity_opts[@]}" \
        "${SIF_PATH}" \
        bash /workspace/scripts/run_finetune.sh \
        2>&1 | tee "${OUTPUT_DIR}/logs/finetune.log"

    local exit_code=${PIPESTATUS[0]}

    if [[ ${exit_code} -eq 0 ]]; then
        log_success "Training completed successfully!"
        # Promote merged weights to OUTPUT_DIR root so it looks like a standard
        # HuggingFace model directory (config.json + safetensors at top level),
        # which is what vLLM and activate-rag-vllm expect.
        if [[ -d "${OUTPUT_DIR}/merged" ]]; then
            log_info "Promoting merged weights to ${OUTPUT_DIR}..."
            mv "${OUTPUT_DIR}/merged/"* "${OUTPUT_DIR}/"
            rmdir "${OUTPUT_DIR}/merged"
            log_success "Model directory ready for vLLM: ${OUTPUT_DIR}"
        fi
    else
        log_error "Training failed with exit code ${exit_code}"
        log_info "Check logs: ${OUTPUT_DIR}/logs/finetune.log"
        exit ${exit_code}
    fi
}

show_results() {
    log_info "Training results:"
    echo ""

    if [[ -d "${OUTPUT_DIR}/adapters" ]]; then
        log_success "Adapter weights:"
        ls -la "${OUTPUT_DIR}/adapters"
    fi

    if [[ -f "${OUTPUT_DIR}/config.json" ]]; then
        log_success "Merged weights (vLLM ready) at ${OUTPUT_DIR}:"
        ls -la "${OUTPUT_DIR}"/*.safetensors "${OUTPUT_DIR}"/*.json 2>/dev/null || true
    fi

    echo ""
    log_info "Output directory: ${OUTPUT_DIR}"
    log_info "Logs: ${OUTPUT_DIR}/logs/finetune.log"
    echo ""
    log_info "To serve with activate-rag-vllm:"
    log_info "  Model Source → Local Path (pre-staged weights)"
    log_info "  Model Path   → ${OUTPUT_DIR}"
}

# ==============================================================================
# Parse Arguments
# ==============================================================================

# Note: MODEL_ID is already set from env vars above, don't reset it

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG="$2"
            apply_preset "${CONFIG}"
            shift 2
            ;;
        --dataset-source)
            DATASET_SOURCE="$2"
            shift 2
            ;;
        --dataset-name)
            DATASET_NAME="$2"
            shift 2
            ;;
        --local-dataset)
            LOCAL_DATASET_PATH="$2"
            DATASET_SOURCE="local"
            shift 2
            ;;
        --dataset-format)
            DATASET_FORMAT="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --sif-path)
            SIF_PATH="$2"
            shift 2
            ;;
        --build-container)
            BUILD_CONTAINER=true
            shift
            ;;
        --max-samples)
            MAX_SAMPLES="$2"
            shift 2
            ;;
        --epochs)
            NUM_EPOCHS="$2"
            shift 2
            ;;
        --model-id)
            MODEL_ID="$2"
            shift 2
            ;;
        --hf-token)
            HF_TOKEN="$2"
            shift 2
            ;;
        --max-seq-length)
            MAX_SEQ_LENGTH="$2"
            shift 2
            ;;
        --tensorboard)
            TENSORBOARD=true
            shift
            ;;
        --tensorboard-port)
            TENSORBOARD_PORT="$2"
            shift 2
            ;;
        --tensorboard-prefix)
            TENSORBOARD_PATH_PREFIX="$2"
            shift 2
            ;;
        --tensorboard-bind-all)
            TENSORBOARD_BIND_ALL=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Apply default preset if none specified and no env vars set
if [[ -z "${CONFIG}" ]] && [[ -z "${MODEL_ID:-}" ]] && [[ -z "${BASE_MODEL_ID:-}" ]]; then
    apply_preset "llama3-8b-medical-quick"
    log_info "Using default preset: llama3-8b-medical-quick"
elif [[ -n "${CONFIG}" ]]; then
    log_info "Using preset: ${CONFIG}"
else
    log_info "Using environment variable configuration"
fi

# ==============================================================================
# Main Execution
# ==============================================================================

main() {
    echo "========================================"
    echo "Medical LLM Fine-tuning (Local Run)"
    echo "========================================"
    echo ""

    check_requirements
    echo ""

    setup_output_dir
    echo ""

    ensure_container
    echo ""

    # Show TensorBoard info if enabled (it runs inside container)
    show_tensorboard_info
    echo ""

    run_training
    echo ""

    show_results
}

main
