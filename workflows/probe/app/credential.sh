#!/bin/bash
# Which credential serves the dashboards after this run completes, when the run's own
# PW_API_KEY stops working: the key given as input (PROBE_API_KEY, carried by the
# workflow's env block) when there is one, else the host's own pw sign-in, which the
# user workspace and the clusters the ACTIVATE agent connects have. Run from the job
# directory before anything is submitted; appends PROBE_AUTH (key | host) to probe.env
# and fails the run when neither credential works. No set -x: the key would show.
set -eo pipefail
export PATH=$HOME/pw:$PATH
case "${PROBE_API_KEY}" in ''|undefined) PROBE_API_KEY="" ;; esac
if [ -n "${PROBE_API_KEY}" ]; then
    if ! PW_API_KEY="${PROBE_API_KEY}" pw auth whoami >/dev/null 2>&1; then
        echo "::error::The API key given does not authenticate on $(hostname)"; exit 1
    fi
    auth=key
    echo "::notice::The dashboards authenticate with the API key given, which outlives this run"
elif env -u PW_API_KEY pw auth whoami >/dev/null 2>&1; then
    auth=host
    echo "::notice::The dashboards authenticate with the pw sign-in of $(hostname), which outlives this run"
else
    echo "::error::No credential outlives this run on $(hostname): the host has no pw sign-in of its own (run pw auth there) and no API key was given"; exit 1
fi
echo "PROBE_AUTH=${auth}" >> probe.env
