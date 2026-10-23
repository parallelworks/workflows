#!/bin/bash
# create-start-script.sh service|batch
# Assembles the script the submitter runs, inputs.sh first: for a service, the cleanup
# trap every endpoint workflow carries and start-template.sh; for a batch job,
# build-template.sh, which records its own exit status. Publishes the script's path,
# the SKIP_CLEANUP path and, through app/scheduler-directives.sh, the core and GPU
# requests. Runs in the job directory on the login node.
set -eo pipefail
mode="$1"
app=workflows/omniverse/app
rm -f HOSTNAME SESSION_PORT job.ended job.started
case "${mode}" in
    service)
        script="start-service-${PW_JOB_ID}.sh"
        {
            cat inputs.sh
            cat <<'TRAP'

cleanup() {
    trap - EXIT INT TERM HUP QUIT USR1 USR2 PIPE
    echo "::notice::Cleaning up..."
    if [ -f cancel.sh ]; then
        mv cancel.sh cancel.sh.submitted
        echo "echo Cleanup script was already executed" > cancel.sh
        bash cancel.sh.submitted
    fi
    kill -- -$$
}

trap cleanup EXIT INT TERM HUP QUIT USR1 USR2 PIPE

echo "::notice::Starting service"
TRAP
            cat "${app}/start-template.sh"
        } > "${script}"
        echo "SKIP_CLEANUP_PATH=${PWD}/SKIP_CLEANUP" | tee -a "${OUTPUTS}"
        ;;
    batch)
        # not run.sh: the submitter writes its assembled job script under that name here
        script="build-${PW_JOB_ID}.sh"
        rm -f build.exit
        cat inputs.sh "${app}/build-template.sh" > "${script}"
        echo "EXIT_FILE=${PWD}/build.exit" | tee -a "${OUTPUTS}"
        ;;
    *)
        echo "::error title=Error::create-start-script.sh takes 'service' or 'batch'"
        exit 1
        ;;
esac
echo "SCRIPT_PATH=${PWD}/${script}" | tee -a "${OUTPUTS}"

bash "${app}/scheduler-directives.sh"
