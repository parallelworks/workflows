#!/bin/bash
# Publishes the core and GPU requests as scheduler directives through $OUTPUTS:
# SLURM_CPU_DIRECTIVE, SLURM_GPU_DIRECTIVE and PBS_RESOURCE_DIRECTIVE, composed ahead
# of the form's directives by the YAMLs, so a directive typed there wins (sbatch and
# qsub keep the last value of a repeated option). A job gets one core by default, and
# Kit's task system stalls on one. Reads cluster_scheduler, cluster_cpus, cluster_gpus.
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
