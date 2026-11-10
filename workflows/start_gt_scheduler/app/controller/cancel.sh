#!/bin/bash
source "$(dirname "$0")/inputs.sh"

scancel -u ${USER}
screen -X -S gt-scheduler quit
kill $(ps -x | grep ssh | grep ${gt_license_port} | grep -v grep | awk '{print $1}') 2>/dev/null
kill $(ps -x | grep ssh | grep usercontainer | grep -v grep | awk '{print $1}') 2>/dev/null
kill $(ps -x | grep logs.out | grep -v grep | awk '{print $1}') 2>/dev/null
sudo systemctl stop gtdistd.service
exit 0
