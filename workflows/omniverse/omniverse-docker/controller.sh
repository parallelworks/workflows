set -o pipefail

################################################################################
# Interactive Session Controller - Omniverse render (Docker)
#
# Purpose: Check the form's values before the job is submitted. The image is
#          pulled in start-template.sh on the node where the job runs, because
#          image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_*, files_*: the form, checked by app/check-inputs.sh (the builder has
#     no service_* fields)
#   - software_image: the Isaac Sim image
#   - service_parent_install_dir: where omniverse/cache, Isaac Sim's home shared by runs, goes
################################################################################

source workflows/omniverse/app/check-inputs.sh

if [ -z "${software_image}" ]; then
    echo "::error title=Error::The container image is empty"
    exit 1
fi

echo "::notice title=Info::Controller setup complete."
