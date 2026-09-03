#!/bin/bash
# ==============================================================================
# Singularity Container Build Script
# ==============================================================================
# Builds the Singularity container for the medical fine-tuning workflow.
# The container will be built to the default location expected by the workflow.
#
# Usage:
#   ./scripts/build_container.sh [--sudo] [--output PATH]
#
# Options:
#   --sudo      Use sudo for building (required on some systems)
#   --output    Custom output path (default: ~/pw/singularity/finetune.sif)
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

# Default values
USE_SUDO=""
OUTPUT_DIR="${HOME}/pw/singularity"
OUTPUT_FILE="${OUTPUT_DIR}/finetune.sif"
DEF_FILE="${WORKFLOW_ROOT}/singularity/finetune.def"

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
Usage: $0 [OPTIONS]

Build the Singularity container for the medical fine-tuning workflow.

Options:
  --sudo      Use sudo for building (required on some systems)
  --output    Custom output path (default: ~/pw/singularity/finetune.sif)
  --help, -h  Show this help message

Examples:
  $0                    # Build to default location
  $0 --sudo             # Build with sudo
  $0 --output /tmp/container.sif  # Build to custom location

The container will be built to the default location expected by the workflow:
  ${OUTPUT_FILE}
EOF
}

# ==============================================================================
# Parse Arguments
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --sudo)
            USE_SUDO="sudo"
            shift
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
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

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

log_info "Checking Singularity/Apptainer installation..."

if command -v singularity &> /dev/null; then
    SINGULARITY_CMD="singularity"
    log_success "Found singularity"
elif command -v apptainer &> /dev/null; then
    SINGULARITY_CMD="apptainer"
    log_success "Found apptainer"
else
    log_error "Neither singularity nor apptainer found. Please install Singularity or Apptainer."
    log_info "See: https://sylabs.io/guides/3.7/user-guide/installation.html"
    exit 1
fi

# Get version
VERSION=$(${SINGULARITY_CMD} --version | head -1)
log_info "Using: ${VERSION}"

# Check definition file
log_info "Checking container definition..."
if [[ ! -f "${DEF_FILE}" ]]; then
    log_error "Container definition not found: ${DEF_FILE}"
    exit 1
fi

log_success "Found definition file: ${DEF_FILE}"

# Create output directory
log_info "Creating output directory..."
mkdir -p "${OUTPUT_DIR}"
log_success "Output directory: ${OUTPUT_DIR}"

# Check if container already exists
if [[ -f "${OUTPUT_FILE}" ]]; then
    log_warning "Container already exists at: ${OUTPUT_FILE}"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Build cancelled."
        exit 0
    fi
    rm -f "${OUTPUT_FILE}"
    log_info "Removed existing container."
fi

# ==============================================================================
# Build Container
# ==============================================================================

log_info "Starting container build..."
log_info "Definition: ${DEF_FILE}"
log_info "Output: ${OUTPUT_FILE}"
log_info "This may take 10-30 minutes depending on your network speed..."

BUILD_CMD="${USE_SUDO} ${SINGULARITY_CMD} build \"${OUTPUT_FILE}\" \"${DEF_FILE}\""

if eval ${BUILD_CMD}; then
    log_success "Container built successfully!"
    log_info "Container location: ${OUTPUT_FILE}"

    # Show container info
    log_info "Container information:"
    ${SINGULARITY_CMD} info "${OUTPUT_FILE}" 2>/dev/null || true

    # Show file size
    if [[ -f "${OUTPUT_FILE}" ]]; then
        SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)
        log_success "Container size: ${SIZE}"
    fi

    log_info ""
    log_info "The workflow will automatically use this container when running."
    log_info "If you move this container, update the 'Singularity Image Path' parameter."

else
    log_error "Container build failed!"
    log_info "If you're getting permission errors, try: $0 --sudo"
    exit 1
fi
