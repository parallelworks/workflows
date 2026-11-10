#!/bin/bash
here=$(cd "$(dirname "$0")" && pwd)
source "${here}/inputs.sh"
set -x

user=$(id -u)

# This run's own whatever else is on the node: its scripts still in flight and the
# tails that stream its log, which would otherwise wait forever on a file that no
# longer grows
pkill -u ${user} -f -- "${here}/(license_tunnel|launch_scheduler)[.]sh"
pkill -u ${user} -f -- "tail .*${here}/logs[.]out"

# A cleanup only reaches what its own run started. With another run's scheduler
# serving here, the session, the tunnels, the daemon and the SLURM jobs are that
# run's: this one was refused, or lost its own session before the other started
if [ "$("${here}/session.sh" "${here}")" == "foreign" ]; then
    echo "Another run's GT scheduler is running on $(hostname): nothing else here is this run's to stop"
    exit 0
fi

screen -X -S gt-scheduler quit
pkill -u ${user} -f -- "ssh .*-L 0[.]0[.]0[.]0:${gt_license_port}:"
pkill -u ${user} -f -- "ssh .*usercontainer"
pkill -u ${user} -f -- "logs[.]out"
# Only once the loop is gone: an executor it was submitting would land behind the scancel
sleep 2
scancel -u ${USER}
sudo systemctl stop gtdistd.service
exit 0
