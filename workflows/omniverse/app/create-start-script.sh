#!/bin/bash
# create-start-script.sh service|batch
# Assembles the script the submitter runs, inputs.sh first: for a service, the cleanup
# trap every endpoint workflow carries and start-template.sh; for a batch job,
# build-template.sh, which records its own exit status. Publishes the script's path,
# the SKIP_CLEANUP path and the core and GPU requests as scheduler directives. Runs
# in the job directory on the login node.
set -eo pipefail
mode="$1"
app=workflows/omniverse/app
rm -f HOSTNAME SESSION_PORT job.ended job.started
case "${mode}" in
    service)
        script="start-service-${PW_JOB_ID}.sh"
        {
            cat inputs.sh
            cat <<'TRAP'

cleanup() {
    trap - EXIT INT TERM HUP QUIT USR1 USR2 PIPE
    echo "::notice::Cleaning up..."
    if [ -f cancel.sh ]; then
        mv cancel.sh cancel.sh.submitted
        echo "echo Cleanup script was already executed" > cancel.sh
        bash cancel.sh.submitted
    fi
    kill -- -$$
}

trap cleanup EXIT INT TERM HUP QUIT USR1 USR2 PIPE

echo "::notice::Starting service"
TRAP
            cat "${app}/start-template.sh"
        } > "${script}"
        echo "SKIP_CLEANUP_PATH=${PWD}/SKIP_CLEANUP" | tee -a "${OUTPUTS}"
        ;;
    batch)
        # not run.sh: the submitter writes its assembled job script under that name here
        script="build-${PW_JOB_ID}.sh"
        rm -f build.exit
        cat inputs.sh "${app}/build-template.sh" > "${script}"
        echo "EXIT_FILE=${PWD}/build.exit" | tee -a "${OUTPUTS}"
        ;;
    *)
        echo "::error title=Error::create-start-script.sh takes 'service' or 'batch'"
        exit 1
        ;;
esac
echo "SCRIPT_PATH=${PWD}/${script}" | tee -a "${OUTPUTS}"

# The core and GPU requests go ahead of the form's directives, so a directive typed
# there wins: sbatch and qsub keep the last value of a repeated option. A job gets one
# core by default, and Kit's task system stalls on one
cpus="${cluster_cpus:-0}"
gpus="${cluster_gpus:-0}"
slurm_cpus=""
slurm_gpus=""
pbs_select=""
if [ "${cluster_scheduler:-false}" = true ]; then
    if [[ "${cpus}" =~ ^[0-9]+$ ]] && [ "${cpus}" -gt 0 ]; then
        slurm_cpus="#SBATCH --cpus-per-task=${cpus}"
        pbs_select="select=1:ncpus=${cpus}"
    fi
    if [[ "${gpus}" =~ ^[0-9]+$ ]] && [ "${gpus}" -gt 0 ]; then
        slurm_gpus="#SBATCH --gres=gpu:${gpus}"
        pbs_select="${pbs_select:-select=1}:ngpus=${gpus}"
    fi
    if [ -n "${pbs_select}" ]; then
        pbs_select="#PBS -l ${pbs_select}"
    fi
fi
echo "SLURM_CPU_DIRECTIVE=${slurm_cpus}" | tee -a "${OUTPUTS}"
echo "SLURM_GPU_DIRECTIVE=${slurm_gpus}" | tee -a "${OUTPUTS}"
echo "PBS_RESOURCE_DIRECTIVE=${pbs_select}" | tee -a "${OUTPUTS}"
