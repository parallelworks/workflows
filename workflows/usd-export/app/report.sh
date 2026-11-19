#!/bin/bash
# After the submitter: fails the run when the export did not run to its end or failed,
# and otherwise reports what the stage holds. Environment: EXIT_FILE, STAGE_FILE.
set -o pipefail
if ! [ -f "${EXIT_FILE}" ]; then
    echo "::error title=Error::No exit status recorded in ${EXIT_FILE}; the export did not run to its end (killed, walltime, node failure)"
    exit 1
fi
status=$(cat "${EXIT_FILE}")
if [ "${status}" != "0" ]; then
    echo "::error title=Error::The export exited with status ${status}; the job's run.<id>.out has the exporter's log"
    exit 1
fi
designs=$(grep -c '"prim"' "$(dirname "${STAGE_FILE}")/designs.json" 2> /dev/null || true)
echo "::notice title=Stage::${STAGE_FILE} holds ${designs:-0} designs; open it in the omniverse workflow's desktop (Stage to follow)"
