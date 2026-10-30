set -o pipefail

################################################################################
# Interactive Session Controller - GitLab (Singularity)
#
# Purpose: The shared checks and runner tools (lib/controller.sh), then the
#          GitLab SIF, pulled once into the install directory
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: where containers/gitlab-<tag>.sif lives, with
#     a containers/gitlab.sif symlink the start template follows
#   - service_rundir: must not be a run directory the Docker runtime wrote
################################################################################

# The SIF is built from gitlab-singularity/gitlab.def (build-container.sh) and
# pushed as ghcr.io/parallelworks/gitlab:<tag>, the file named after the tag
GITLAB_SIF_TAG=19.5.1-ee

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/controller.sh"
source tools/oras/libs.sh

sif_name="gitlab-${GITLAB_SIF_TAG}.sif"
container_sif="${service_parent_install_dir}/containers/${sif_name}"
if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ] && ! mkdir -p "${service_parent_install_dir}" 2>/dev/null; then
    echo "::warning::${container_sif} does not exist and ${service_parent_install_dir} is not writable; using ${HOME}/pw/software instead"
    service_parent_install_dir=${HOME}/pw/software
    container_sif="${service_parent_install_dir}/containers/${sif_name}"
fi
mkdir -p "${service_parent_install_dir}/containers"
chmod a+rX "${service_parent_install_dir}/containers"
if ! [ -f "${container_sif}" ]; then
    echo "::group::GitLab SIF Download"
    oras_pull_file "ghcr.io/parallelworks/gitlab:${GITLAB_SIF_TAG}" "${sif_name}" "${container_sif}"
    if [ ! -s "${container_sif}" ]; then
        echo "::error title=Error::Failed to download ${container_sif}"
        exit 1
    fi
    chmod a+r "${container_sif}"
    echo "::endgroup::"
fi
ln -sfn "${sif_name}" "${service_parent_install_dir}/containers/gitlab.sif"

# Docker writes config/, data/ and logs/ as root; the user namespace this
# runtime runs in cannot write them, so such a run directory is refused
not_owned=$(find "${rundir}" -maxdepth 2 -user 0 -print -quit 2>/dev/null)
if [ -n "${not_owned}" ]; then
    echo "::error title=Error::${not_owned} belongs to root: a run directory of the Docker runtime cannot be reused by the Singularity one. Choose another run directory"
    exit 1
fi

echo "::notice title=Info::Controller setup complete."
