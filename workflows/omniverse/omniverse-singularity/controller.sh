set -o pipefail
set -x

################################################################################
# Interactive Session Controller - Omniverse (Singularity)
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
#   - desktop_app: set by the desktop workflow only, which also gets an Isaac Sim entry
#     in the Applications menu of desktop sessions
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

# The GUI launcher for a desktop session, beside the image it starts, and the script
# it hands Kit to open and follow a stage
cp workflows/omniverse/app/isaac-sim-gui.sh "${service_parent_install_dir}/omniverse/isaac-sim-gui.sh"
chmod a+rx "${service_parent_install_dir}/omniverse/isaac-sim-gui.sh"
mkdir -p "${service_parent_install_dir}/omniverse/kit-scripts"
cp workflows/omniverse/app/stage-follow.py "${service_parent_install_dir}/omniverse/kit-scripts/stage-follow.py"
chmod a+r "${service_parent_install_dir}/omniverse/kit-scripts/stage-follow.py"

# An Isaac Sim entry in the Applications menu of the platform's desktop sessions, on
# any node that shares this home directory
if [ -n "${desktop_app}" ]; then
    mkdir -p "${HOME}/.local/share/applications"
    cat > "${HOME}/.local/share/applications/pw-isaac-sim.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Isaac Sim
Comment=NVIDIA Isaac Sim (Omniverse Kit) from the omniverse workflow's image; the window takes a minute or more
Exec=/bin/bash ${service_parent_install_dir}/omniverse/isaac-sim-gui.sh physx
Terminal=false
Categories=Graphics;3DGraphics;
EOF
fi

if [ "${fracture_own_mesh}" = true ]; then
    bash workflows/omniverse/app/install-blast.sh "${service_parent_install_dir}"
fi

echo "::notice title=Info::Controller setup complete."
