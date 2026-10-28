set -o pipefail

################################################################################
# Interactive Session Controller - GitLab (Docker)
#
# Purpose: The shared checks and runner tools (lib/controller.sh); the image
#          itself is pulled by start-template.sh on the node where the job runs
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/controller.sh"

echo "::notice title=Info::Controller setup complete."
