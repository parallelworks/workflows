################################################################################
# Batch job - Omniverse USD builder
#
# Purpose: Build a USD scene from a manifest in the Isaac Sim container on the
#          node's GPU (meshes converted, robots imported, physics applied), then
#          copy it to the destination when one is given. Records its own exit
#          status in build.exit: the submitter never forwards it
# Runs on: Controller or compute node
# Called by: Workflow after controller setup, through app/create-start-script.sh,
#            with omniverse-<runtime>/runtime.sh for the container runtime
#
# Required Environment Variables:
#   - manifest_file: the manifest (the form's text, the source's manifest.yaml or
#     the bundled example's), from preprocessing
#   - scene_dir: the source directory (the manifest's files), from app/fetch-source.sh
#   - files_destination: optional; where the scene is copied
#   - software_runtime, software_image / software_sif, service_parent_install_dir
################################################################################

set -o pipefail
set -x

status_file="${PWD}/build.exit"
trap 'echo $? > "${status_file}"' EXIT
# A scancel's TERM reaches this script alone: record it and let the trap kill the rest
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

source "${PW_PARENT_JOB_DIR}/workflows/omniverse/app/start-common.sh"
build_dir="${PWD}/build"
mkdir -p "${build_dir}"
write_cancel_script
runtime_setup

echo "::group::Build"
source_dir="${scene_dir:-${app_dir}/examples/build}"
container_binds=("${build_dir}:/build" "${source_dir}:/source:ro" "${manifest_file}:/manifest.yaml:ro")
rm -f "${build_dir}/build.json"
# In the background with wait, so a TERM from the scheduler is handled at once
container_run /isaac-sim/python.sh /app/build.py --manifest /manifest.yaml --source /source --out /build --tag "${PW_RUN_SLUG}" &
wait $!
status=$?
if [ "${status}" -ne 0 ] || ! [ -s "${build_dir}/build.json" ]; then
    echo "::error title=Error::The build failed (output above)"
    exit 1
fi
echo "::notice::Built $(python3 -c "import json; d = json.load(open('${build_dir}/build.json')); print(d['scene'], 'with', len(d['objects']), 'objects,', d['rigid_bodies'], 'rigid bodies and', d['joints'], 'joints')")"
echo "::endgroup::"

if [ -n "${files_destination}" ]; then
    echo "::group::Deliver"
    bash "${app_dir}/deliver-results.sh" "${build_dir}" "${files_destination}" "${PW_RUN_SLUG}" || exit 1
    echo "::endgroup::"
fi
