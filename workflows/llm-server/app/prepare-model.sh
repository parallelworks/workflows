#!/bin/bash
# prepare-model.sh: the Download Model step of every variant (yamls/*.yaml).
# Stages a Hugging Face checkpoint for vLLM or SGLang on the login node, which
# has the internet access a compute node may lack. Reads its inputs from the
# environment:
#   MODEL_ID     Hugging Face model id, <owner>/<name>
#   CACHE_DIR    model cache directory; empty means <INSTALL_DIR>/models
#   INSTALL_DIR  parent install directory; empty means ${HOME}/pw/software
#   HF_TOKEN     optional, for gated models
# controller.sh resolves an empty CACHE_DIR by the same rule, and
# start-template.sh looks in the same two caches.

set -o pipefail
# The token stays out of the trace
hf_token="${HF_TOKEN}"
unset HF_TOKEN
set -x

if [ -z "${MODEL_ID}" ] || [ "${MODEL_ID}" = "undefined" ]; then
    echo "::error title=Error::no Hugging Face model id given"
    exit 1
fi
if [ -z "${INSTALL_DIR}" ] || [ "${INSTALL_DIR}" = "undefined" ]; then
    INSTALL_DIR=${HOME}/pw/software
fi
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
if [ -z "${CACHE_DIR}" ] || [ "${CACHE_DIR}" = "undefined" ]; then
    CACHE_DIR="${INSTALL_DIR}/models"
fi
CACHE_DIR="${CACHE_DIR/#\~/$HOME}"
NAME="${MODEL_ID##*/}"
# A shared cache (<shared software directory>/models on NOAA, $PROJECTS_HOME/hsp/models
# on HSP) is usually owned by whoever staged it first: a model already there
# is served read-only by every account, and one that still has to be
# downloaded goes there only when this account can write it, otherwise into a
# private cache.
PRIVATE_CACHE_DIR="${HOME}/pw/software/models"

validate_model() {
    [ -s "$1/config.json" ] || return 1
    local f
    f=$(find "$1" -maxdepth 1 \( -name '*.safetensors' -o -name '*.bin' \) -size +1M 2>/dev/null | head -1)
    [ -n "$f" ]
}
usable_dir() { # writable if it exists, creatable if it does not
    if [ -d "$1" ]; then [ -w "$1" ]; else mkdir -p "$1" 2>/dev/null; fi
}
# Leaves what this run uses from a shared cache group-writable so any project
# member can refresh it; best effort, and nothing to do for a private path
share() {
    case "$1" in "${HOME}"/*) return 0 ;; esac
    chmod -R g+rwX,o+rX "$1" 2>/dev/null
    find "$1" -type d -exec chmod g+s {} + 2>/dev/null
    chmod g+rwx,o+rx "${1%/*}" 2>/dev/null
    chmod g+s "${1%/*}" 2>/dev/null
    return 0
}

for d in "${CACHE_DIR}" "${PRIVATE_CACHE_DIR}"; do
    if validate_model "${d}/${NAME}"; then
        share "${d}/${NAME}"
        echo "Model already cached at ${d}/${NAME}"
        exit 0
    fi
done
if ! usable_dir "${CACHE_DIR}/${NAME}"; then
    echo "::warning::${CACHE_DIR} is not writable; downloading ${MODEL_ID} into ${PRIVATE_CACHE_DIR}"
    CACHE_DIR="${PRIVATE_CACHE_DIR}"
    if ! usable_dir "${CACHE_DIR}/${NAME}"; then
        echo "::error title=Error::cannot create ${CACHE_DIR}/${NAME}"
        exit 1
    fi
fi
TARGET_DIR="${CACHE_DIR}/${NAME}"
# Keep HF working caches off the small $HOME filesystem where possible
export HF_HOME="${CACHE_DIR}/cache"
usable_dir "${HF_HOME}" || export HF_HOME="${PRIVATE_CACHE_DIR}/cache"

HF_BIN=""
for d in "${INSTALL_DIR}/.hfcli" "${HOME}/pw/software/.hfcli"; do
    for b in "${d}/bin/hf" "${d}/bin/huggingface-cli"; do
        if [ -x "${b}" ]; then
            HF_BIN="${b}"
            break 2
        fi
    done
done
if [ -z "${HF_BIN}" ]; then
    VENV="${INSTALL_DIR}/.hfcli"
    usable_dir "${VENV}" || VENV="${HOME}/pw/software/.hfcli"
    if ! python3 -m venv "${VENV}"; then
        echo "::error title=Error::python3 -m venv failed; install python3/python3-venv on the cluster"
        exit 1
    fi
    "${VENV}/bin/pip" install --quiet --upgrade 'huggingface_hub[hf_transfer]'
    share "${VENV}"
    HF_BIN="${VENV}/bin/hf"
    [ -x "${HF_BIN}" ] || HF_BIN="${VENV}/bin/huggingface-cli"
fi

{ set +x; } 2>/dev/null
if [ -n "${hf_token}" ] && [ "${hf_token}" != "undefined" ]; then
    export HF_TOKEN="${hf_token}"
fi
set -x
# hf download is incremental: it resumes a partial download in place
# and only fetches files that are missing or changed
export HF_HUB_ENABLE_HF_TRANSFER=1
for attempt in 1 2 3; do
    if "${HF_BIN}" download "${MODEL_ID}" --local-dir "${TARGET_DIR}" \
        --exclude "original/*" --exclude "metal/*" --exclude "*.bin" \
        --exclude "*.gguf" --exclude "*.onnx" --exclude "consolidated*.pth"; then
        break
    fi
    if [ "${attempt}" = 3 ]; then
        # A partial download stays, to be resumed; a directory nothing reached does not
        rmdir "${TARGET_DIR}" 2>/dev/null
        echo "::error title=Error::model download failed after 3 attempts"
        exit 1
    fi
    # hf_transfer can be flaky on some networks; retry without it
    unset HF_HUB_ENABLE_HF_TRANSFER
    sleep $((attempt * 5))
done

# Some models only ship bin weights
if ! ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1; then
    "${HF_BIN}" download "${MODEL_ID}" --local-dir "${TARGET_DIR}" --include "*.bin"
fi

if ! validate_model "${TARGET_DIR}"; then
    echo "::error title=Error::downloaded model at ${TARGET_DIR} is incomplete"
    exit 1
fi
share "${TARGET_DIR}"
share "${HF_HOME}"
echo "Model ready at ${TARGET_DIR}"
