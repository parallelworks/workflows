# The body of train.sh, the script the submitter runs on the compute node (or the
# login node). inputs.sh precedes it in that file, so the form's values, the PW_*
# variables, physicsnemo_src (the examples tree) and physicsnemo_sif (Singularity)
# are set. The submitter cds into the run's job directory first and streams this
# script's output to the run log. It never forwards the exit status, so the status
# goes to train.exit for the results job; the training output also goes to
# work/train.log, which TensorBoard and the results job read.
set -o pipefail
job_dir="${PWD}"
work_dir="${job_dir}/work"
app_dir="${job_dir}/workflows/physicsnemo/app"
container_name="physicsnemo-${PW_RUN_SLUG}"
docker_cmd=()

f_stop_container() {
    if [ "${#docker_cmd[@]}" -gt 0 ]; then
        "${docker_cmd[@]}" rm -f "${container_name}" > /dev/null 2>&1 || true
    fi
}
f_exit() {
    local rc=$?
    f_stop_container
    echo "${rc}" > "${job_dir}/train.exit"
}
trap f_exit EXIT
# scancel and qdel send SIGTERM: without these traps the exit trap would record the
# status of the last command completed before the training, 0. The training runs
# in the background in its own process group and is waited for, so the trap runs at
# once instead of after the pipeline (workflows/benchmarks/app/run-template.sh)
f_killed() {
    trap - HUP INT TERM
    if [ -n "${train_pid:-}" ] && kill -0 "${train_pid}" 2> /dev/null; then
        kill -TERM -- "-${train_pid}" 2> /dev/null || true
        f_stop_container
        for _ in 1 2 3 4 5; do
            kill -0 "${train_pid}" 2> /dev/null || break
            sleep 1
        done
        kill -KILL -- "-${train_pid}" 2> /dev/null || true
    fi
    exit "$1"
}
trap 'f_killed 129' HUP
trap 'f_killed 130' INT
trap 'f_killed 143' TERM
set -e

# the submitter runs this on a cancel, on the node of the job: a Docker container
# belongs to the daemon, so neither scancel nor killing this script's process group
# stops it
cat > "${job_dir}/cancel.sh" << EOF
#!/bin/bash
docker rm -f ${container_name} > /dev/null 2>&1 || sudo -n docker rm -f ${container_name} > /dev/null 2>&1 || true
pid=\$(cat "${job_dir}/train.pid" 2> /dev/null)
if [ -n "\${pid}" ]; then
    kill -TERM -- "-\${pid}" 2> /dev/null || true
fi
EOF
chmod +x "${job_dir}/cancel.sh"
rm -f "${job_dir}/train.pid"

echo "Training    : ${physicsnemo_mode}${physicsnemo_example:+ ${physicsnemo_example}} on the ${physicsnemo_device}, ${physicsnemo_runtime} runtime"
echo "Host        : $(hostname)${SLURM_JOB_ID:+, SLURM job ${SLURM_JOB_ID} on ${SLURM_JOB_NODELIST}}${PBS_JOBID:+, PBS job ${PBS_JOBID}}"
echo "Started     : $(date)"

# the GPU: the scheduler's allocation when there is one (SLURM_JOB_GPUS holds the
# physical indices Docker needs; CUDA_VISIBLE_DEVICES is already set for the rest),
# else the form's GPU index on this node
gpu=""
if [ "${physicsnemo_device}" = gpu ]; then
    if ! command -v nvidia-smi > /dev/null 2>&1; then
        echo "::error::No GPU on $(hostname): nvidia-smi is not installed. Choose a GPU node (partition, gres) or set the device to CPU."
        exit 1
    fi
    if ! smi=$(nvidia-smi -L 2>&1) || ! grep -q '^GPU ' <<< "${smi}"; then
        echo "::error::No usable GPU on $(hostname): nvidia-smi -L says: $(head -n 1 <<< "${smi}")"
        exit 1
    fi
    if [ -n "${SLURM_JOB_GPUS:-}" ]; then
        gpu="${SLURM_JOB_GPUS%%,*}"
    elif [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
        gpu="${CUDA_VISIBLE_DEVICES%%,*}"
    else
        gpu="${physicsnemo_gpu_index:-0}"
    fi
    if ! info=$(nvidia-smi -i "${gpu}" --query-gpu=index,name,memory.used,memory.total --format=csv,noheader 2>&1); then
        echo "::error::GPU ${gpu} does not exist on $(hostname): ${info}"
        echo "${smi}"
        exit 1
    fi
    echo "GPU         : ${info}"
fi
echo

mkdir -p "${work_dir}"
rm -rf "${work_dir}/example" "${work_dir}/train.log" "${work_dir}/.home"
if [ -f "${job_dir}/overrides.txt" ]; then
    cp "${job_dir}/overrides.txt" "${work_dir}/overrides.txt"
fi
if [ -f "${job_dir}/custom.sh" ]; then
    cp "${job_dir}/custom.sh" "${work_dir}/custom.sh"
fi

envs=(
    PHYSICSNEMO_MODE="${physicsnemo_mode}"
    PHYSICSNEMO_EXAMPLE="${physicsnemo_example:-}"
    PHYSICSNEMO_EPOCHS="${physicsnemo_epochs:-}"
    PHYSICSNEMO_ITERATIONS="${physicsnemo_iterations:-}"
    PHYSICSNEMO_BATCH_SIZE="${physicsnemo_batch_size:-0}"
    PHYSICSNEMO_DEVICE="${physicsnemo_device}"
    PHYSICSNEMO_REF="${physicsnemo_ref}"
    PHYSICSNEMO_SRC=/opt/physicsnemo-src
    PYTHONUNBUFFERED=1
)

case "${physicsnemo_runtime}" in
    docker)
        sudo -n systemctl start docker > /dev/null 2>&1 || true
        if docker info > /dev/null 2>&1; then
            docker_cmd=(docker)
        elif sudo -n docker info > /dev/null 2>&1; then
            docker_cmd=(sudo -n docker)
        else
            echo "::error::Docker is not available on $(hostname) (neither docker nor passwordless sudo docker works). Choose the Singularity runtime on this cluster."
            exit 1
        fi
        if ! "${docker_cmd[@]}" image inspect "${physicsnemo_image}" > /dev/null 2>&1; then
            echo "Pulling ${physicsnemo_image} on $(hostname) (once per node; the 25.06 image is 17 GB)"
            pulled=false
            for attempt in 1 2 3; do
                if "${docker_cmd[@]}" pull "${physicsnemo_image}"; then
                    pulled=true
                    break
                fi
                echo "::warning::docker pull attempt ${attempt} of ${physicsnemo_image} failed"
                sleep $(( attempt * 15 ))
            done
            if [ "${pulled}" != true ]; then
                echo "::error::Could not pull ${physicsnemo_image} on $(hostname)"
                exit 1
            fi
        fi
        f_stop_container
        # as the workflow user, so everything the training writes into the job
        # directory is the user's; HOME inside the image for the caches
        mkdir -p "${work_dir}/.home"
        cmd=("${docker_cmd[@]}" run --rm --name "${container_name}" --init
            --user "$(id -u):$(id -g)" --ipc=host --ulimit memlock=-1 --ulimit stack=67108864
            -e HOME=/workspace/.home -e USER="$(id -un)" -e LOGNAME="$(id -un)"
            -v "${work_dir}:/workspace" -v "${app_dir}:/opt/physicsnemo-workflow:ro"
            -v "${physicsnemo_src}:/opt/physicsnemo-src:ro" -w /workspace)
        for e in "${envs[@]}"; do
            cmd+=(-e "${e}")
        done
        if [ -n "${gpu}" ]; then
            cmd+=(--gpus "device=${gpu}")
        else
            # the NGC images ask the NVIDIA runtime for every GPU, and on hosts where
            # that runtime is the default it would hand them over without --gpus
            cmd+=(-e NVIDIA_VISIBLE_DEVICES=void -e CUDA_VISIBLE_DEVICES=)
        fi
        cmd+=("${physicsnemo_image}" bash /opt/physicsnemo-workflow/run-example.sh)
        ;;
    singularity)
        if command -v singularity > /dev/null 2>&1; then
            runtime=singularity
        elif command -v apptainer > /dev/null 2>&1; then
            runtime=apptainer
        else
            echo "::error::Neither singularity nor apptainer is on PATH on $(hostname)"
            exit 1
        fi
        if [ ! -r "${physicsnemo_sif}" ]; then
            echo "::error::The Singularity image ${physicsnemo_sif} is not readable from $(hostname)"
            exit 1
        fi
        cmd=("${runtime}" exec --cleanenv --pwd /workspace
            -B "${work_dir}:/workspace" -B "${app_dir}:/opt/physicsnemo-workflow:ro"
            -B "${physicsnemo_src}:/opt/physicsnemo-src:ro")
        for e in "${envs[@]}"; do
            cmd+=(--env "${e}")
        done
        if [ -n "${gpu}" ]; then
            # a scheduler's CUDA_VISIBLE_DEVICES already names the allocation
            cmd+=(--nv --env "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-${gpu}}")
        else
            cmd+=(--env CUDA_VISIBLE_DEVICES=)
        fi
        cmd+=("${physicsnemo_sif}" bash /opt/physicsnemo-workflow/run-example.sh)
        ;;
    *)
        echo "::error::Unknown runtime '${physicsnemo_runtime}'"
        exit 1
        ;;
esac

echo "Command     : ${cmd[*]}"
echo
set -m
( set -o pipefail; "${cmd[@]}" 2>&1 | tee "${work_dir}/train.log" ) &
train_pid=$!
set +m
echo "${train_pid}" > "${job_dir}/train.pid"
wait "${train_pid}"
echo
echo "Finished    : $(date)"
