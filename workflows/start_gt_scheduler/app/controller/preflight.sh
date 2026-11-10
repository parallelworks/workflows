#!/bin/bash
# Prints what the workspace needs to know about this node before it starts anything here.
gt_version=$1

echo "home=${HOME}"
echo "private_ip=$(hostname -I | awk '{print $1}')"

screen -wipe > /dev/null 2>&1
if screen -list 2> /dev/null | grep -q '[.]gt-scheduler'; then
    echo "scheduler_running=true"
else
    echo "scheduler_running=false"
fi

if [ -d "/software/gtsuite/${gt_version}" ]; then
    echo "gt_installed=true"
else
    echo "gt_installed=false"
fi

missing=""
for tool in screen sbatch squeue sinfo scancel netstat curl python3 jq rsync; do
    command -v ${tool} > /dev/null 2>&1 || missing="${missing} ${tool}"
done
sudo -n true 2> /dev/null || missing="${missing} sudo-without-password"
echo "missing=${missing# }"
