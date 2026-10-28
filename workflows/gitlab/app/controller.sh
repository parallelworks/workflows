set -o pipefail

################################################################################
# Interactive Session Controller - GitLab
#
# Purpose: Check the form's values and install the CI runner tools on the
#          login node. The GitLab image is pulled in start-template.sh on the
#          node where the job runs, because image caches are not shared
#          between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_rundir: holds config/, data/, logs/ and runner/
#   - service_parent_install_dir: where gitlab-runner and jacamar are installed,
#     each under <tool>/<version>/ with a <tool>/current symlink the start
#     template follows
#   - service_root_password_file: optional; the root password the form carries
#   - runners_shell / runners_slurm: which CI runners to register
#   - oidc_client_id / oidc_client_secret_file: both set, or neither
################################################################################

GITLAB_RUNNER_VERSION=v19.5.1
JACAMAR_VERSION=0.31.0
# The ubi9 build is a static binary; the checksum is the registry's
JACAMAR_TARBALL="jacamar-ci-${JACAMAR_VERSION}.ubi9.amd64.tar.gz"
JACAMAR_SHA256=708a368859f69ae53ae48dd70c54ac25ab586a6341b3db9521dd07ad720c7952

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/gitlab
fi
rundir=$(realpath -m "${service_rundir}")
if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p "${rundir}"
if ! [ -w "${rundir}" ]; then
    echo "::error title=Error::The run directory ${rundir} is not writable by $(id -un)"
    exit 1
fi

if [ -s "${service_root_password_file}" ]; then
    if [ "$(wc -c < "${service_root_password_file}")" -lt 9 ]; then
        echo "::error title=Error::GitLab needs a root password of at least 8 characters"
        exit 1
    fi
fi

if [ -n "${oidc_client_id}" ] && ! [ -s "${oidc_client_secret_file}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client secret of application ${oidc_client_id}"
    exit 1
fi
if [ -z "${oidc_client_id}" ] && [ -s "${oidc_client_secret_file}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client ID that goes with the client secret"
    exit 1
fi

if [ "${runners_shell}" = "true" ] || [ "${runners_slurm}" = "true" ]; then
    runner_dir="${service_parent_install_dir}/gitlab-runner/${GITLAB_RUNNER_VERSION}"
    runner_bin="${runner_dir}/gitlab-runner"
    if ! [ -x "${runner_bin}" ] || ! "${runner_bin}" --version >/dev/null 2>&1; then
        echo "Installing gitlab-runner ${GITLAB_RUNNER_VERSION} into ${runner_dir}"
        mkdir -p "${runner_dir}"
        if ! curl -sSL --retry 3 -o "${runner_bin}.tmp" \
            "https://gitlab-runner-downloads.s3.amazonaws.com/${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-amd64"; then
            echo "::error title=Error::Could not download gitlab-runner ${GITLAB_RUNNER_VERSION}"
            exit 1
        fi
        chmod +x "${runner_bin}.tmp"
        mv "${runner_bin}.tmp" "${runner_bin}"
    fi
    "${runner_bin}" --version | head -n 1
    ln -sfn "${GITLAB_RUNNER_VERSION}" "${service_parent_install_dir}/gitlab-runner/current"
fi

if [ "${runners_slurm}" = "true" ]; then
    for tool in sbatch squeue scancel sacct; do
        if ! command -v ${tool} >/dev/null 2>&1; then
            echo "::error title=Error::The SLURM runner needs ${tool} on $(hostname); it is not on the PATH"
            exit 1
        fi
    done
    # Jacamar reads a job's final state from sacct, which answers only with
    # accounting storage configured
    accounting=$(scontrol show config 2>/dev/null | awk -F'= *' '/^AccountingStorageType/ { print $2 }')
    case "${accounting}" in
        ""|"(null)"|*none*)
            echo "::error title=Error::The SLURM runner needs SLURM accounting (sacct), which this cluster has off (AccountingStorageType=${accounting:-unset}): Jacamar CI reads every job's final state from it. Launch without the SLURM runner"
            exit 1
            ;;
    esac
    jacamar_dir="${service_parent_install_dir}/jacamar-ci/${JACAMAR_VERSION}"
    jacamar_bin="${jacamar_dir}/jacamar"
    if ! [ -x "${jacamar_bin}" ] || ! "${jacamar_bin}" --version >/dev/null 2>&1; then
        echo "Installing Jacamar CI ${JACAMAR_VERSION} into ${jacamar_dir}"
        mkdir -p "${jacamar_dir}"
        if ! curl -sSL --retry 3 -o "${jacamar_dir}/${JACAMAR_TARBALL}" \
            "https://gitlab.com/api/v4/projects/ecp-ci%2Fjacamar-ci/packages/generic/jacamar-ci/${JACAMAR_VERSION}/${JACAMAR_TARBALL}"; then
            echo "::error title=Error::Could not download Jacamar CI ${JACAMAR_VERSION}"
            exit 1
        fi
        if ! echo "${JACAMAR_SHA256}  ${jacamar_dir}/${JACAMAR_TARBALL}" | sha256sum -c --quiet; then
            echo "::error title=Error::${JACAMAR_TARBALL} does not match its checksum"
            rm -f "${jacamar_dir}/${JACAMAR_TARBALL}"
            exit 1
        fi
        tar -xzf "${jacamar_dir}/${JACAMAR_TARBALL}" -C "${jacamar_dir}" jacamar
        rm -f "${jacamar_dir}/${JACAMAR_TARBALL}"
        chmod +x "${jacamar_bin}"
    fi
    "${jacamar_bin}" --version | head -n 1
    ln -sfn "${JACAMAR_VERSION}" "${service_parent_install_dir}/jacamar-ci/current"
fi

echo "::notice title=Info::Controller setup complete."
