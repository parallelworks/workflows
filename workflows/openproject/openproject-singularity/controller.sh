set -o pipefail

################################################################################
# Interactive Session Controller - OpenProject (Singularity)
#
# Purpose: Pull the OpenProject SIF (idempotent) and check the form's values
#          before the job is submitted
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: where containers/openproject.sif lives
#   - service_rundir: holds pgdata/, assets/ and the generated secrets
#   - oidc_client_id / oidc_client_secret: both set, or neither
################################################################################

source tools/oras/libs.sh

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/openproject.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p "${service_parent_install_dir}/containers"
chmod a+rX "${service_parent_install_dir}/containers"
container_sif=${service_parent_install_dir}/containers/openproject.sif

if ! [ -f "${container_sif}" ]; then
    echo "::group::OpenProject SIF Download"
    oras_pull_file ghcr.io/parallelworks/openproject:17.0 openproject.sif "${container_sif}"
    if [ ! -s "${container_sif}" ]; then
        echo "::error title=Error::Failed to download ${container_sif}"
        exit 1
    fi
    chmod a+r "${container_sif}"
    echo "::endgroup::"
fi

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/openproject
fi
rundir=$(realpath -m "${service_rundir}")
mkdir -p "${rundir}"
if ! [ -w "${rundir}" ]; then
    echo "::error title=Error::The run directory ${rundir} is not writable by $(id -un)"
    exit 1
fi
# The Docker runtime's PostgreSQL writes pgdata as the container's postgres user
not_owned=$(find "${rundir}" -maxdepth 1 ! -user "$(id -u)" -print -quit)
if [ -n "${not_owned}" ]; then
    echo "::error title=Error::${not_owned} belongs to another user: a run directory of the Docker runtime cannot be reused by the Singularity one. Choose another run directory"
    exit 1
fi

if [ -n "${oidc_client_id}" ]; then
    if [ -z "${oidc_client_secret}" ]; then
        echo "::error title=Error::Sign in with ACTIVATE needs the client secret of application ${oidc_client_id}"
        exit 1
    fi
    if ! [ -s "${service_enterprise_token_file}" ] && ! ls "${rundir}"/.enterprise-token-* >/dev/null 2>&1; then
        echo "::error title=Error::Sign in with ACTIVATE needs an OpenProject Enterprise token: ${rundir} holds none yet and the form's token is empty"
        exit 1
    fi
fi
if [ -z "${oidc_client_id}" ] && [ -n "${oidc_client_secret}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client ID that goes with the client secret"
    exit 1
fi

echo "::notice title=Info::Controller setup complete."
