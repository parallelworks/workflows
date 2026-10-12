set -o pipefail

################################################################################
# Interactive Session Controller - Grafana + Prometheus
#
# Purpose: Check the form's values before the job is submitted. The images
#          are pulled in start-template.sh on the node where the job runs
#          (controller or compute node), because image caches are not shared
#          between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

if ! [[ "${grafana_retention}" =~ ^[0-9]+(ms|s|m|h|d|w|y)$ ]]; then
    echo "::error title=Error::Invalid Prometheus Retention '${grafana_retention}': use a number with a unit, such as 15d, 12h or 4w"
    exit 1
fi

# The editor input arrives with its newlines escaped
printf "%b" "${grafana_extra_targets:-}" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' | while read -r target; do
    if ! [[ "${target}" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
        echo "::error title=Error::Invalid scrape target '${target}': use host:port, one per line"
        exit 1
    fi
done || exit 1

echo "::notice title=Info::Controller setup complete."
