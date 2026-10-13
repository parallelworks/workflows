set -o pipefail

################################################################################
# Interactive Session Controller - pgAdmin 4
#
# Purpose: Create the data directory the container mounts. The image is pulled
#          in start-template.sh on the node where the job runs (controller or
#          compute node), because image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

mkdir -p "${pgadmin_data_dir}"
echo "::notice title=Info::Controller setup complete."
