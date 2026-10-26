################################################################################
# Container runtime - Singularity / Apptainer
#
# Purpose: Run a script in the Isaac Sim SIF as the workflow user, with the GPU.
#          Sourced by app/start-common.sh on the node that runs the job; the
#          three functions are what the templates call.
# Required Environment Variables:
#   - software_sif: optional; a SIF of your own, else the one the controller pulled
#     from software_sif_registry (its tag names the file)
#   - service_parent_install_dir, cache_dir, app_dir, container_env, container_binds
################################################################################

container_sif="${software_sif:-${service_parent_install_dir}/omniverse/containers/isaac-sim-${software_sif_registry##*:}.sif}"

runtime_setup() {
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
    container_image_label="${container_sif}"
}

# The script is a child of this job, so the submitter's process-group kill
# reaches it; cancel.sh covers the Kit interpreter when it outlives its starter
# (its command line carries the script and the tag, the starter's only python.sh)
write_cancel_script() {
    cat > cancel.sh <<CANCELEOF
#!/bin/bash
pkill -TERM -f "(run|build)[.]py .*--tag ${PW_RUN_SLUG}( |$)" > /dev/null 2>&1 || true
CANCELEOF
    chmod +x cancel.sh
}

# container_run <command...>: the command in the SIF as the workflow user, the host
# environment kept out except the GPU allocation; the image itself stays read-only
container_run() {
    local args=(
        exec --nv --cleanenv "${userns[@]}"
        --home "${cache_dir}:/cache" --bind "${cache_dir}/kit:/isaac-sim/kit/cache" --bind "${app_dir}:/app:ro"
    )
    local item
    for item in "${container_env[@]}"; do
        args+=(--env "${item}")
    done
    if [ -n "${CUDA_VISIBLE_DEVICES}" ]; then
        args+=(--env "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}")
    fi
    for item in "${container_binds[@]}"; do
        args+=(--bind "${item}")
    done
    singularity "${args[@]}" "${container_sif}" "$@"
}
