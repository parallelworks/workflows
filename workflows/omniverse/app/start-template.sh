################################################################################
# Interactive Session Service Starter - Omniverse
#
# Purpose: Run the chosen example (or the source's run.py) in the Isaac Sim
#          container on the node's GPU: a render to PNG frames, or a physics-only
#          run; copy the outputs to the destination when one is given; then serve
#          the outputs as a page behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup, through app/create-start-script.sh,
#            with omniverse-<runtime>/runtime.sh for the container runtime
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_example, service_engine, service_frames, service_resolution,
#     service_renderer, service_snapshots: the run's settings
#   - scene_dir, scene_file, scene_script: the source, from app/fetch-source.sh
#   - files_destination: optional; where the outputs are copied
#   - software_runtime, software_image / software_sif, service_parent_install_dir
################################################################################

set -o pipefail
set -x

source "${PW_PARENT_JOB_DIR}/workflows/omniverse/app/start-common.sh"
render_dir="${PWD}/render"
mkdir -p "${render_dir}"
write_cancel_script
runtime_setup

echo "::group::Run"
# A physics-only run's form hides the render fields; the script still takes them
service_resolution="${service_resolution:-1280x720}"
service_renderer="${service_renderer:-RayTracedLighting}"
script="/app/examples/${service_example}/run.py"
if [ -n "${scene_script}" ]; then
    script="/scene/${scene_script}"
fi
delivered_to=""
if [ -n "${files_destination}" ]; then
    delivered_to="${files_destination%/}/${PW_RUN_SLUG}"
fi
run_args=(
    --out /render --frames "${service_frames}" --fps 30
    --width "${service_resolution%x*}" --height "${service_resolution#*x}"
    --renderer "${service_renderer}" --engine "${service_engine}" --snapshots "${service_snapshots:-30}"
    --image "${container_image_label}" --delivered-to "${delivered_to}" --tag "${PW_RUN_SLUG}"
)
container_binds=("${render_dir}:/render")
if [ -n "${scene_dir}" ]; then
    container_binds+=("${scene_dir}:/scene:ro")
fi
if [ -n "${scene_file}" ]; then
    run_args+=(--scene "/scene/${scene_file}")
fi
rm -f "${render_dir}/render.json"
if ! container_run /isaac-sim/python.sh "${script}" "${run_args[@]}"; then
    echo "::error title=Error::The run failed (output above)"
    exit 1
fi
if ! [ -s "${render_dir}/render.json" ]; then
    echo "::error title=Error::The run wrote no render.json to ${render_dir} (output above)"
    exit 1
fi
if ls "${render_dir}"/frames/*.png > /dev/null 2>&1; then
    echo "::notice::Rendered $(ls "${render_dir}"/frames/*.png | wc -l) frames into ${render_dir}"
elif [ -s "${render_dir}/poses.csv" ]; then
    echo "::notice::Simulated $(($(wc -l < "${render_dir}/poses.csv") - 1)) body poses into ${render_dir}/poses.csv, $(ls "${render_dir}"/snapshots/ 2> /dev/null | wc -l) snapshots"
else
    echo "::error title=Error::The run wrote neither frames nor poses to ${render_dir} (output above)"
    exit 1
fi
echo "::endgroup::"

if [ -n "${delivered_to}" ]; then
    echo "::group::Deliver"
    bash "${app_dir}/deliver-results.sh" "${render_dir}" "${files_destination}" "${PW_RUN_SLUG}" || exit 1
    echo "::endgroup::"
fi

echo "::group::Start Service"
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- python3 "${app_dir}/serve.py" \
    --port {port} --web "${app_dir}/web" --render "${render_dir}"

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Treating
    # that as a failure cancelled the whole run from inside the compute job:
    # ollama_gguf runs 24-26 finished "canceled" with the service up, until
    # #1055 disabled this line for that service. Only a launch that never
    # registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
