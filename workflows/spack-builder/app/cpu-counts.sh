#!/usr/bin/env bash
# cpu-counts.sh
# Prints this node's CPU counts as sourceable KEY="VALUE" lines:
#   CPUS_LOGICAL   = online logical CPUs (hardware threads) on the node
#   CPUS_PHYSICAL  = distinct physical cores among them
#   CPUS_SLURM     = CPUs Slurm has configured for this node (CPUTot), or empty
#                    outside a Slurm job
#
# All three are node-wide. nproc is not: inside a job it reports only the CPUs
# the job was given, which is why the inspection job always saw 1.
#
# PHYSICAL exists because a cloud worker launched with hyperthreading disabled
# can still be configured in Slurm with the instance type's vCPU count, so
# Slurm's figure and even the instance type overstate what the node has. A core
# shared by two threads counts once.

set -uo pipefail

logical="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc --all 2>/dev/null || echo '')"

physical=""
if command -v lscpu >/dev/null 2>&1; then
  physical="$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
fi
if ! [ "${physical:-0}" -gt 0 ] 2>/dev/null; then
  physical="$(for c in /sys/devices/system/cpu/cpu[0-9]*; do
      [ "$(cat "$c/online" 2>/dev/null || echo 1)" = 1 ] || continue
      echo "$(cat "$c/topology/physical_package_id" 2>/dev/null):$(cat "$c/topology/core_id" 2>/dev/null)"
    done | sort -u | wc -l)"
fi
[ "${physical:-0}" -gt 0 ] 2>/dev/null || physical="$logical"

slurm=""
if [ -n "${SLURMD_NODENAME:-}" ] && command -v scontrol >/dev/null 2>&1; then
  slurm="$(scontrol show node "$SLURMD_NODENAME" 2>/dev/null \
           | grep -o 'CPUTot=[0-9]*' | head -1 | cut -d= -f2)"
fi

printf 'CPUS_LOGICAL="%s"\nCPUS_PHYSICAL="%s"\nCPUS_SLURM="%s"\n' \
  "$logical" "$physical" "$slurm"
