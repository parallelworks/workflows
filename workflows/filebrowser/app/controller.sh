set -o pipefail

################################################################################
# Interactive Session Controller - File Browser
#
# Purpose: Create the directories the service mounts. The image is pulled in
#          start-template.sh on the node where the job runs (controller or
#          compute node), because image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

mkdir -p "${filebrowser_rundir}/config" "${filebrowser_rundir}/database" "${filebrowser_data_dir}"
echo "::notice title=Info::Controller setup complete."
