set -o pipefail

################################################################################
# Interactive Session Controller - OpenProject
#
# Purpose: Check the form's values before the job is submitted. The image is
#          pulled in start-template.sh on the node where the job runs, because
#          image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_rundir: holds pgdata/, assets/ and the generated secrets
#   - oidc_client_id / oidc_client_secret: both set, or neither
################################################################################

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/openproject
fi
rundir=$(realpath -m "${service_rundir}")

mkdir -p "${rundir}"
if ! [ -w "${rundir}" ]; then
    echo "::error title=Error::The run directory ${rundir} is not writable by $(id -un)"
    exit 1
fi

if [ -n "${oidc_client_id}" ]; then
    if [ -z "${oidc_client_secret}" ]; then
        echo "::error title=Error::Sign in with ACTIVATE needs the client secret of application ${oidc_client_id}"
        exit 1
    fi
    if ! [ -s "${service_enterprise_token_file}" ] && ! ls "${rundir}"/.enterprise-token-* >/dev/null 2>&1; then
        echo "::warning title=Warning::Sign in with ACTIVATE needs an OpenProject Enterprise token: ${rundir} holds none yet and the form's token is empty, so the button stays hidden until one is active (Administration -> Enterprise edition)"
    fi
fi
if [ -z "${oidc_client_id}" ] && [ -n "${oidc_client_secret}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client ID that goes with the client secret"
    exit 1
fi


echo "::notice title=Info::Controller setup complete."
