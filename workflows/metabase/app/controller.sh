set -o pipefail

################################################################################
# Interactive Session Controller - Metabase
#
# Purpose: Create the data directory the container mounts. The image is pulled
#          in start-template.sh on the node where the job runs (controller or
#          compute node), because image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

mkdir -p "${metabase_data_dir}/plugins"
echo "::notice title=Info::Controller setup complete."
