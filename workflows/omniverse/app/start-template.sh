################################################################################
# Interactive Session Service Starter - Omniverse render
#
# Purpose: Render the scene to PNG frames with Isaac Sim (an Omniverse Kit
#          application) in a Docker or Singularity container on the node's GPU,
#          then serve the frames as a flipbook page behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_frames, service_resolution, service_renderer: the render settings
#   - service_scene: optional; a USD file on the cluster's filesystem
#   - software_runtime: docker or singularity
#   - software_image: the Isaac Sim image (Docker)
#   - software_sif: optional; a SIF of your own (Singularity), else the one the controller pulled
#   - service_parent_install_dir: holds omniverse/cache, Isaac Sim's home (shader caches,
#     logs) shared by runs, and omniverse/containers, the SIF
################################################################################

set -o pipefail
set -x

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
app_dir="${PW_PARENT_JOB_DIR}/workflows/omniverse/app"
render_dir="${PWD}/render"
cache_dir="${service_parent_install_dir}/omniverse/cache"
container_name="omniverse-${PW_RUN_SLUG}"
mkdir -p "${render_dir}" "${cache_dir}/kit"

# The GPU: the scheduler's allocation when there is one, else every GPU of the node
if ! smi=$(nvidia-smi -L 2>&1) || ! grep -q '^GPU ' <<< "${smi}"; then
    echo "::error title=Error::No usable GPU on $(hostname): $(head -n 1 <<< "${smi}"). Choose a GPU node (partition, GPUs per job) or a GPU server."
    exit 1
fi
echo "${smi}"
# Docker takes a list of device IDs only inside literal double quotes
gpus_arg=all
if [ -n "${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES:-}}" ]; then
    gpus_arg="\"device=${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES}}\""
fi

render_args=(
    --out /render --frames "${service_frames}"
    --width "${service_resolution%x*}" --height "${service_resolution#*x}"
    --renderer "${service_renderer}"
)
if [ -n "${service_scene}" ]; then
    render_args+=(--scene "/scene/$(basename "${service_scene}")")
fi
# A FIPS host (/proc is not namespaced) makes the image's OpenSSL fail without
# a FIPS provider, so it is told not to use one
fips_env=()
if [ "$(cat /proc/sys/crypto/fips_enabled 2> /dev/null)" = 1 ]; then
    fips_env=(OPENSSL_FORCE_FIPS_MODE=0)
fi
rm -f "${render_dir}/render.json"

case "${software_runtime}" in
docker)
# The container belongs to the docker daemon, not the endpoint's process tree,
# so a cancel during the render needs cancel.sh (run by the cleanup trap)
cat > cancel.sh <<CANCELEOF
#!/bin/bash
docker rm -f ${container_name} > /dev/null 2>&1 || sudo -n docker rm -f ${container_name} > /dev/null 2>&1 || true
CANCELEOF
chmod +x cancel.sh

sudo -n systemctl start docker > /dev/null 2>&1 || true
if docker info > /dev/null 2>&1; then
    docker_cmd=(docker)
elif sudo -n docker info > /dev/null 2>&1; then
    docker_cmd=(sudo -n docker)
else
    echo "::error title=Error::Docker is not available on $(hostname) (neither docker nor passwordless sudo docker works); choose the Singularity runtime"
    exit 1
fi

echo "::group::Image Pull"
# Pull on the node where the job runs, before the endpoint registers, so the
# run only completes once the container could start. The image is 11 GB
# compressed and 20 GB unpacked, and Docker keeps it under its own storage, not
# the install directory: refuse at once when that filesystem cannot hold it
if ! "${docker_cmd[@]}" image inspect "${software_image}" > /dev/null 2>&1; then
    store=$("${docker_cmd[@]}" info --format '{{.DockerRootDir}}' 2> /dev/null)
    required_gb=25
    if "${docker_cmd[@]}" info 2> /dev/null | grep -q 'io.containerd.snapshotter'; then
        # Docker 29's containerd image store keeps the layers and the unpacked image
        # in containerd's root, whatever Docker's root directory says
        store=$(sed -n 's/^\s*root\s*=\s*"\(.*\)".*/\1/p' /etc/containerd/config.toml 2> /dev/null | head -n 1)
        store=${store:-/var/lib/containerd}
        required_gb=35
    fi
    available_gb=$(df -Pk "${store}" 2> /dev/null | awk 'NR == 2 {print int($4 / 1048576)}')
    if [ -n "${available_gb}" ] && [ "${available_gb}" -lt "${required_gb}" ]; then
        echo "::error title=Error::Pulling ${software_image} needs about ${required_gb} GB free in Docker's image store ${store} on $(hostname), which has ${available_gb} GB. Free space there, move Docker's storage to a larger filesystem, or choose the Singularity runtime, whose image goes to the install directory."
        exit 1
    fi
    if ! "${docker_cmd[@]}" pull "${software_image}"; then
        echo "::error title=Error::Could not pull ${software_image}"
        exit 1
    fi
fi
echo "::endgroup::"

echo "::group::Render"
# The container runs as the workflow user, so the frames are the user's; the
# image's group gives it read access to /isaac-sim. Its home and Kit's cache,
# where Isaac Sim keeps the shader caches and its logs, are directories in the
# install directory, so the shaders compile once (minutes) and later runs on
# the node start fast.
# The image's entrypoint is the streaming server: the script runs through
# python.sh instead
docker_args=(
    --rm --name "${container_name}" --hostname "$(hostname)" --gpus "${gpus_arg}"
    --entrypoint /isaac-sim/python.sh
    --user "$(id -u):$(id -g)" --group-add 1234
    -e ACCEPT_EULA=Y -e HOME=/cache
    -v "${cache_dir}:/cache" -v "${cache_dir}/kit:/isaac-sim/kit/cache"
    -v "${render_dir}:/render" -v "${app_dir}:/app:ro"
)
for env in "${fips_env[@]}"; do
    docker_args+=(-e "${env}")
done
if [ -n "${service_scene}" ]; then
    docker_args+=(-v "$(dirname "${service_scene}"):/scene:ro")
fi
if ! "${docker_cmd[@]}" run "${docker_args[@]}" "${software_image}" /app/render.py "${render_args[@]}" --image "${software_image}"; then
    echo "::error title=Error::The render failed (output above)"
    exit 1
fi
;;

singularity)
container_sif="${software_sif:-${service_parent_install_dir}/omniverse/containers/isaac-sim-6.2.0.1.sif}"
if ! which singularity > /dev/null 2>&1; then
    if module load apptainer 2> /dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2> /dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
fi
if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi
# The render is a child of this script, so the submitter's process-group kill
# reaches it; cancel.sh covers a Kit process that outlives its starter
cat > cancel.sh <<CANCELEOF
#!/bin/bash
pkill -TERM -f "render.py --out /render .*${PW_RUN_SLUG}" > /dev/null 2>&1 || true
CANCELEOF
chmod +x cancel.sh

# Prefer running the SIF directly; a kernel that cannot mount it (hardened
# images disable squashfs) can still run it in a user namespace, through FUSE
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    userns=()
elif singularity exec --userns "${container_sif}" /bin/true > /dev/null 2>&1; then
    echo "::notice::$(hostname) cannot mount the SIF directly; running it in a user namespace"
    userns=(--userns)
else
    echo "::error title=Error::singularity cannot run ${container_sif} on $(hostname), with or without --userns"
    exit 1
fi

echo "::group::Render"
# Isaac Sim runs as the workflow user with its home in the install directory
# (shader caches, logs), the host environment kept out except the GPU
# allocation and the license; the image itself stays read-only
singularity_args=(
    exec --nv --cleanenv "${userns[@]}"
    --home "${cache_dir}:/cache" --bind "${cache_dir}/kit:/isaac-sim/kit/cache"
    --bind "${render_dir}:/render" --bind "${app_dir}:/app:ro"
    --env ACCEPT_EULA=Y
)
for env in "${fips_env[@]}"; do
    singularity_args+=(--env "${env}")
done
if [ -n "${CUDA_VISIBLE_DEVICES}" ]; then
    singularity_args+=(--env "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}")
fi
if [ -n "${service_scene}" ]; then
    singularity_args+=(--bind "$(dirname "${service_scene}"):/scene:ro")
fi
if ! singularity "${singularity_args[@]}" "${container_sif}" \
        /isaac-sim/python.sh /app/render.py "${render_args[@]}" --image "${container_sif}" --tag "${PW_RUN_SLUG}"; then
    echo "::error title=Error::The render failed (output above)"
    exit 1
fi
;;
esac
if ! [ -s "${render_dir}/render.json" ] || ! ls "${render_dir}"/frames/*.png > /dev/null 2>&1; then
    echo "::error title=Error::The render wrote no frames to ${render_dir} (output above)"
    exit 1
fi
echo "::notice::Rendered $(ls "${render_dir}"/frames/*.png | wc -l) frames into ${render_dir}"
echo "::endgroup::"

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
