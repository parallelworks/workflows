set -o pipefail

################################################################################
# Interactive Session Controller - Pydio Cells
#
# Purpose: Check the form's directories before the job is submitted. The
#          images are pulled in start-template.sh on the node where the job
#          runs (controller or compute node), because image caches are not
#          shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

rundir=$(realpath -m "${pydio_rundir}")
data_dir=$(realpath -m "${pydio_data_dir}")

# Cells indexes the Data Directory and writes a .pydio file into every folder:
# a Run Directory inside it would expose and alter the live database files
case "${rundir}/" in
    "${data_dir%/}/"*)
        echo "::error title=Error::The Run Directory (${rundir}) must not be inside the Data Directory (${data_dir})"
        exit 1
        ;;
esac

echo "::notice title=Info::Controller setup complete."
