set -o pipefail

################################################################################
# Interactive Session Controller - PostgreSQL
#
# Purpose: Create the data directory the database lives in. The images are
#          pulled in start-template.sh on the node where the job runs
#          (controller or compute node), because image caches are not shared
#          between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

mkdir -p "${postgres_data_dir}"
echo "::notice title=Info::Controller setup complete."
