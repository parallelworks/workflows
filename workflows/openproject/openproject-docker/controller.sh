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
#   - oidc_client_id / oidc_client_secret: both set, or neither (the user's
#     account variables OPENPROJECT_CLIENT_ID and OPENPROJECT_CLIENT_SECRET)
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
        echo "::error title=Error::Sign in with ACTIVATE needs the client secret of application ${oidc_client_id}: save it under Account -> Variables as the secret variable OPENPROJECT_CLIENT_SECRET and let this workflow read it"
        exit 1
    fi
    # OpenProject hides every single sign-on provider until an Enterprise
    # token is active, so a missing one is not a reason to refuse the start
    if ! [ -s "${service_enterprise_token_file}" ] && ! ls "${rundir}"/.enterprise-token-* >/dev/null 2>&1; then
        echo "::warning::Sign in with ACTIVATE is configured from your account variables, but ${rundir} holds no OpenProject Enterprise token and the form's token is empty: OpenProject hides the button until a token is imported (the form) or a trial is requested inside OpenProject"
    fi
fi
if [ -z "${oidc_client_id}" ] && [ -n "${oidc_client_secret}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client ID that goes with OPENPROJECT_CLIENT_SECRET: save it under Account -> Variables as OPENPROJECT_CLIENT_ID"
    exit 1
fi


echo "::notice title=Info::Controller setup complete."
