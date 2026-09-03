#!/bin/bash
# ==============================================================================
# Local Test Script for Medical LLM Fine-tuning Workflow
# ==============================================================================
# This script allows testing workflow components locally without the PW platform.
# It simulates the workflow steps and validates configuration, scripts, and
# container functionality.
#
# Usage:
#   ./scripts/test_local.sh [test_type]
#
# Test types:
#   all       - Run all tests (default)
#   yaml      - Validate YAML syntax
#   config    - Test configuration presets
#   scripts   - Test shell scripts
#   container - Test Singularity container
#   dryrun    - Dry run with fake training
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

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++)) || true
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++)) || true
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# ==============================================================================
# Test Functions
# ==============================================================================

test_yaml_syntax() {
    log_info "Testing YAML syntax..."

    local yaml_file="${WORKFLOW_ROOT}/workflow.yaml"
    if [[ ! -f "${yaml_file}" ]]; then
        log_error "workflow.yaml not found at ${yaml_file}"
        return 1
    fi

    # Check if python with yaml module is available
    if command -v python3 &> /dev/null; then
        if python3 -c "import yaml" 2>/dev/null; then
            if python3 -c "import yaml; yaml.safe_load(open('${yaml_file}'))" 2>/dev/null; then
                log_success "YAML syntax is valid"
            else
                log_error "YAML syntax validation failed"
                return 1
            fi
        else
            log_warning "PyYAML not installed, skipping Python validation"
            log_info "Install with: pip install pyyaml"
        fi
    else
        log_warning "Python3 not found, skipping YAML validation"
    fi

    # Basic syntax checks
    log_info "Checking for basic YAML syntax issues..."

    # Check for tabs (YAML doesn't allow tabs)
    if grep -q $'\t' "${yaml_file}"; then
        log_error "YAML contains tabs (use spaces)"
        return 1
    else
        log_success "No tabs found in YAML"
    fi

    # Check for required sections
    local required_sections=("on:" "permissions:" "jobs:")
    for section in "${required_sections[@]}"; do
        if grep -q "^${section}" "${yaml_file}"; then
            log_success "Found required section: ${section}"
        else
            log_error "Missing required section: ${section}"
        fi
    done

    # Check that 'name:' field is NOT present (not supported by PW)
    if grep -q "^name:" "${yaml_file}"; then
        log_error "Found unsupported 'name:' field (remove it)"
    else
        log_success "No unsupported 'name:' field found"
    fi
}

test_configuration_presets() {
    log_info "Testing configuration presets..."

    local yaml_file="${WORKFLOW_ROOT}/workflow.yaml"

    # Extract configuration names
    local configs
    configs=$(grep -A 1 "^configurations:" "${yaml_file}" | grep "^  [a-z]" | sed 's/://g' | sed 's/  //g')

    if [[ -z "${configs}" ]]; then
        log_error "No configuration presets found"
        return 1
    fi

    log_info "Found configuration presets:"
    echo "${configs}" | while read -r config; do
        log_info "  - ${config}"
    done

    # Check each configuration has required variables
    echo "${configs}" | while read -r config; do
        if grep -A 20 "^  ${config}:" "${yaml_file}" | grep -q "base_model_id:"; then
            log_success "${config}: has base_model_id"
        else
            log_error "${config}: missing base_model_id"
        fi
    done
}

test_scripts() {
    log_info "Testing workflow scripts..."

    # Check main training script
    local run_script="${SCRIPT_DIR}/run_finetune.sh"
    if [[ -f "${run_script}" ]]; then
        if [[ -x "${run_script}" ]]; then
            log_success "run_finetune.sh exists and is executable"
        else
            log_warning "run_finetune.sh exists but is not executable"
        fi

        # Check for shebang
        if head -1 "${run_script}" | grep -qE "^#!(/bin/bash|/usr/bin/env bash)"; then
            log_success "run_finetune.sh has correct shebang"
        else
            log_error "run_finetune.sh missing or invalid shebang"
        fi
    else
        log_error "run_finetune.sh not found"
    fi

    # Check Python script
    local py_script="${SCRIPT_DIR}/pw_finetune.py"
    if [[ -f "${py_script}" ]]; then
        log_success "pw_finetune.py exists"

        # Check Python syntax
        if python3 -m py_compile "${py_script}" 2>/dev/null; then
            log_success "pw_finetune.py has valid Python syntax"
        else
            log_error "pw_finetune.py has syntax errors"
        fi
    else
        log_error "pw_finetune.py not found"
    fi
}

test_container_def() {
    log_info "Testing Singularity container definition..."

    local def_file="${WORKFLOW_ROOT}/singularity/finetune.def"

    if [[ ! -f "${def_file}" ]]; then
        log_error "Container definition not found: ${def_file}"
        return 1
    fi

    log_success "Container definition found"

    # Check required sections
    local required_sections=("Bootstrap:" "From:" "%post" "%runscript")
    for section in "${required_sections[@]}"; do
        if grep -q "^${section}" "${def_file}"; then
            log_success "Found section: ${section}"
        else
            log_error "Missing section: ${section}"
        fi
    done

    # Check if requirements.txt is referenced
    if grep -q "requirements.txt" "${def_file}"; then
        log_success "Container definition references requirements.txt"
    else
        log_warning "Container definition doesn't reference requirements.txt"
    fi
}

test_build_script() {
    log_info "Testing build script..."

    local build_script="${SCRIPT_DIR}/build_container.sh"

    if [[ ! -f "${build_script}" ]]; then
        log_warning "build_container.sh not found (optional)"
        return 0
    fi

    log_success "build_container.sh exists"

    # Check if executable
    if [[ -x "${build_script}" ]]; then
        log_success "build_container.sh is executable"
    else
        log_warning "build_container.sh is not executable"
    fi

    # Check for shebang
    if head -1 "${build_script}" | grep -qE "^#!(/bin/bash|/usr/bin/env bash)"; then
        log_success "build_container.sh has correct shebang"
    else
        log_error "build_container.sh missing or invalid shebang"
    fi

    # Check bash syntax
    if bash -n "${build_script}" 2>/dev/null; then
        log_success "build_container.sh passes bash syntax check"
    else
        log_error "build_container.sh has bash syntax errors"
    fi
}

test_requirements() {
    log_info "Testing requirements.txt..."

    local req_file="${WORKFLOW_ROOT}/requirements.txt"

    if [[ ! -f "${req_file}" ]]; then
        log_error "requirements.txt not found"
        return 1
    fi

    # Check for essential packages
    local essential_packages=("torch" "transformers" "peft" "datasets" "bitsandbytes")
    for pkg in "${essential_packages[@]}"; do
        if grep -qi "${pkg}" "${req_file}"; then
            log_success "Found essential package: ${pkg}"
        else
            log_warning "Missing essential package: ${pkg}"
        fi
    done
}

test_dryrun() {
    log_info "Running dry run test..."

    # Create a temporary test environment
    local test_dir="/tmp/pw-test-$$"
    mkdir -p "${test_dir}"

    log_info "Test directory: ${test_dir}"

    # Simulate environment file creation
    cat > "${test_dir}/training.env" << 'EOF'
BASE_MODEL_ID=meta-llama/Llama-3.1-8B-Instruct
DATASET_SOURCE=huggingface
DATASET_NAME=Shekswess/medical_llama3_instruct_dataset_short
OUTPUT_DIR=/tmp/test-output
NUM_EPOCHS=1.0
LEARNING_RATE=0.0002
MICRO_BATCH_SIZE=1
GRADIENT_ACCUMULATION=4
MAX_SEQ_LENGTH=512
LORA_R=32
LORA_ALPHA=16
QUANTIZATION=4bit
MAX_SAMPLES=10
MERGE_FULL_WEIGHTS=false
EOF

    log_success "Created test environment file"

    # Source the environment file
    source "${test_dir}/training.env"

    # Verify variables are set
    local required_vars=("BASE_MODEL_ID" "DATASET_SOURCE" "OUTPUT_DIR")
    for var in "${required_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            log_success "Variable set: ${var}=${!var}"
        else
            log_error "Variable not set: ${var}"
        fi
    done

    # Check if run_finetune.sh can be validated
    local run_script="${SCRIPT_DIR}/run_finetune.sh"
    if [[ -f "${run_script}" ]]; then
        # Do a dry run by sourcing and checking for syntax errors
        if bash -n "${run_script}" 2>/dev/null; then
            log_success "run_finetune.sh passes bash syntax check"
        else
            log_error "run_finetune.sh has bash syntax errors"
        fi
    fi

    # Cleanup
    rm -rf "${test_dir}"
    log_info "Cleaned up test directory"
}

test_readme_links() {
    log_info "Testing README documentation links..."

    local readme="${WORKFLOW_ROOT}/README.md"
    local guide="${WORKFLOW_ROOT}/GUIDE.md"

    # Check if files exist
    if [[ -f "${readme}" ]]; then
        log_success "README.md exists"

        # Check for GUIDE.md reference
        if grep -q "GUIDE.md" "${readme}"; then
            if [[ -f "${guide}" ]]; then
                log_success "GUIDE.md referenced in README and exists"
            else
                log_error "README references GUIDE.md but it doesn't exist"
            fi
        fi
    else
        log_error "README.md not found"
    fi
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo -e "${GREEN}Passed:${NC} ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC} ${TESTS_FAILED}"
    echo "=========================================="

    if [[ ${TESTS_FAILED} -eq 0 ]]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

print_usage() {
    cat << EOF
Usage: $0 [test_type]

Test types:
  all       - Run all tests (default)
  yaml      - Validate YAML syntax
  config    - Test configuration presets
  scripts   - Test shell scripts
  container - Test Singularity container
  build     - Test build script
  dryrun    - Dry run with fake training
  readme    - Test README documentation

Examples:
  $0              # Run all tests
  $0 yaml         # Test YAML only
  $0 dryrun       # Run dry run test
EOF
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    local test_type="${1:-all}"

    case "${test_type}" in
        all)
            test_yaml_syntax
            test_configuration_presets
            test_scripts
            test_container_def
            test_build_script
            test_requirements
            test_readme_links
            test_dryrun
            print_summary
            ;;
        yaml)
            test_yaml_syntax
            print_summary
            ;;
        config)
            test_configuration_presets
            print_summary
            ;;
        scripts)
            test_scripts
            print_summary
            ;;
        container)
            test_container_def
            test_build_script
            print_summary
            ;;
        build)
            test_build_script
            print_summary
            ;;
        dryrun)
            test_dryrun
            print_summary
            ;;
        readme)
            test_readme_links
            print_summary
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "Unknown test type: ${test_type}"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
