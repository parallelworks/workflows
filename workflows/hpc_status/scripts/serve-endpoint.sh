#!/usr/bin/env bash
#
# Publish the dashboard as an ACTIVATE endpoint session from a clone of this repository.
#
# It does what a workflow run does, with the same two scripts: app/controller.sh prepares
# the environment and deletes the previous dashboard with this name, app/start-template.sh
# chooses the configuration, credential and address and serves it under pw endpoints run,
# which holds it open until you press Ctrl-C.
#
# Environment:
#   ENDPOINT_NAME       name for the session (default: hpc-status)
#   ENDPOINT_SUBDOMAIN  public hostname label (default: status-<user>)
#   PLATFORM            auto, generic, hpcmp or noaa (default: auto, from the platform host)
#   PINNED_PORT         local port, or 0/unset to let the CLI choose
#   DEFAULT_THEME       dark or light (default: the configuration's)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Both scripts find the app at ${PW_PARENT_JOB_DIR}/workflows/hpc_status/app, as in a run
export PW_PARENT_JOB_DIR="$(cd "${ROOT}/../.." && pwd)"
export PW_USER="${PW_USER:-${USER:-$(id -un)}}"
export service_parent_install_dir="${service_parent_install_dir:-${HOME}/pw/software}"
export pw_endpoints_args="--name ${ENDPOINT_NAME:-hpc-status}"
export service_subdomain="${ENDPOINT_SUBDOMAIN:-}"
export service_platform="${PLATFORM:-auto}"
export service_local_port="${PINNED_PORT:-0}"
export service_theme="${DEFAULT_THEME:-}"
export service_detach=false

bash "${ROOT}/app/controller.sh" || exit 1

# The start script writes its launcher into the current directory
state_dir="${HPC_STATUS_DATA_DIR:-${HOME}/.hpc_status}/endpoint"
mkdir -p "${state_dir}" && cd "${state_dir}" || exit 1

# Sourced, as the workflow runs it; Ctrl-C must end here rather than reach the fallback
# to a platform-assigned address
trap 'exit 130' INT TERM
. "${ROOT}/app/start-template.sh"
