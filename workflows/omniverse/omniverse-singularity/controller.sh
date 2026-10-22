set -o pipefail

################################################################################
# Interactive Session Controller - Omniverse render (Singularity)
#
# Purpose: Check the form's values before the job is submitted and pull the
#          Isaac Sim SIF (idempotent) into the install directory, which the
#          compute nodes share
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_frames, service_resolution, service_renderer: the render settings
#   - service_scene: optional; a USD file on the cluster's filesystem
#   - software_sif: optional; a SIF you already have (empty pulls one)
#   - service_parent_install_dir: where omniverse/cache (Isaac Sim's home shared by
#     runs) and omniverse/containers (the SIF) go
################################################################################

source workflows/omniverse/app/check-inputs.sh
source tools/oras/libs.sh

if [ -n "${software_sif}" ]; then
    if ! [ -r "${software_sif}" ]; then
        echo "::error title=Error::The Singularity image ${software_sif} is not a readable file on $(hostname)"
        exit 1
    fi
else
    container_sif="${service_parent_install_dir}/omniverse/containers/isaac-sim-6.2.0.1.sif"
    mkdir -p "$(dirname "${container_sif}")"
    if ! [ -s "${container_sif}" ]; then
        echo "::group::Isaac Sim SIF Download"
        oras_pull_file ghcr.io/parallelworks/isaac-sim:6.2.0.1 isaac-sim-6.2.0.1.sif "${container_sif}"
        if ! [ -s "${container_sif}" ]; then
            echo "::error title=Error::Failed to download ${container_sif}"
            exit 1
        fi
        chmod a+r "${container_sif}"
        echo "::endgroup::"
    fi
fi

echo "::notice title=Info::Controller setup complete."
