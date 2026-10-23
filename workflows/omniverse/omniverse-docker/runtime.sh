################################################################################
# Container runtime - Docker
#
# Purpose: Run a script in the Isaac Sim image with Docker, as the workflow user,
#          with the GPU. Sourced by app/start-common.sh on the node that runs
#          the job; the three functions are what the templates call.
# Required Environment Variables:
#   - software_image: the Isaac Sim image
#   - cache_dir, app_dir, container_env, container_binds: from start-common.sh
################################################################################

container_name="omniverse-${PW_RUN_SLUG}"

runtime_setup() {
    sudo -n systemctl start docker > /dev/null 2>&1 || true
    if docker info > /dev/null 2>&1; then
        docker_cmd=(docker)
    elif sudo -n docker info > /dev/null 2>&1; then
        docker_cmd=(sudo -n docker)
    else
        echo "::error title=Error::Docker is not available on $(hostname) (neither docker nor passwordless sudo docker works); choose the Singularity runtime"
        exit 1
    fi
    # Docker takes a list of device IDs only inside literal double quotes
    gpus_arg=all
    if [ -n "${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES:-}}" ]; then
        gpus_arg="\"device=${SLURM_JOB_GPUS:-${CUDA_VISIBLE_DEVICES}}\""
    fi

    echo "::group::Image Pull"
    # Pull on the node where the job runs, before anything registers, so the run
    # only completes once the container could start. The image is 11 GB compressed
    # and 20 GB unpacked, and Docker keeps it under its own storage, not the install
    # directory: refuse at once when that filesystem cannot hold it
    if ! "${docker_cmd[@]}" image inspect "${software_image}" > /dev/null 2>&1; then
        local store required_gb available_gb
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
    container_image_label="${software_image}"
}

# The container belongs to the docker daemon, not the job's process tree, so a
# cancel during the run needs cancel.sh (run by the cleanup trap)
write_cancel_script() {
    cat > cancel.sh <<CANCELEOF
#!/bin/bash
docker rm -f ${container_name} > /dev/null 2>&1 || sudo -n docker rm -f ${container_name} > /dev/null 2>&1 || true
CANCELEOF
    chmod +x cancel.sh
}

# container_run <command...>: the command in the image, as the workflow user (the
# image's group gives it read access to /isaac-sim), the image's entrypoint (the
# streaming server) replaced by python.sh
container_run() {
    local args=(
        --rm --name "${container_name}" --hostname "$(hostname)" --gpus "${gpus_arg}"
        --entrypoint /isaac-sim/python.sh
        --user "$(id -u):$(id -g)" --group-add 1234
        -e HOME=/cache
        -v "${cache_dir}:/cache" -v "${cache_dir}/kit:/isaac-sim/kit/cache" -v "${app_dir}:/app:ro"
    )
    local item
    for item in "${container_env[@]}"; do
        args+=(-e "${item}")
    done
    for item in "${container_binds[@]}"; do
        args+=(-v "${item}")
    done
    "${docker_cmd[@]}" run "${args[@]}" "${software_image}" "$@"
}
