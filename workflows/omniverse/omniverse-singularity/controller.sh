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
#   - service_*, files_*: the form, checked by app/check-inputs.sh (the builder has
#     no service_* fields)
#   - software_sif: optional; a SIF you already have (empty pulls one)
#   - software_sif_registry: the ORAS reference of the prebuilt SIF
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
    container_sif="${service_parent_install_dir}/omniverse/containers/isaac-sim-${software_sif_registry##*:}.sif"
    mkdir -p "$(dirname "${container_sif}")"
    if ! [ -s "${container_sif}" ]; then
        echo "::group::Isaac Sim SIF Download"
        oras_pull_file "${software_sif_registry}" "$(basename "${container_sif}")" "${container_sif}"
        if ! [ -s "${container_sif}" ]; then
            echo "::error title=Error::Failed to download ${container_sif}"
            exit 1
        fi
        chmod a+r "${container_sif}"
        echo "::endgroup::"
    fi
fi

# The GUI launcher for a desktop session, beside the image it starts
cp workflows/omniverse/app/isaac-sim-gui.sh "${service_parent_install_dir}/omniverse/isaac-sim-gui.sh"
chmod a+rx "${service_parent_install_dir}/omniverse/isaac-sim-gui.sh"

echo "::notice title=Info::Controller setup complete."
