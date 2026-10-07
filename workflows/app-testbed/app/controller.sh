#!/usr/bin/env bash
################################################################################
# App Testbed controller: prepare the server host
#
# Purpose: Check the prerequisites and create the server's working directory
# Runs on: The server host's login node, before the server is started
# Called by: Workflow preprocessing
#
# Required Environment Variables (from inputs.sh):
#   - server_workdir: Server working directory (~ is expanded; default ~/app-testbed)
################################################################################
set -o pipefail
command -v pw >/dev/null 2>&1 || export PATH="${PATH}:${HOME}/pw"

# The server, the dispatcher's JSON parsing and the health probes need these; the
# worker sites are checked by the bootstrap when it reaches them
for cmd in python3 curl setsid pw; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "::error title=Error::${cmd} not found on $(hostname)"
        exit 1
    fi
done
echo "Python: $(python3 --version 2>&1); pw: $(pw --version 2>&1 | head -1)"

WORKDIR=$(eval echo "${server_workdir:-~/app-testbed}")
mkdir -p "${WORKDIR}"
echo "workspace ready: ${WORKDIR}"
