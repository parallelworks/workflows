#!/bin/bash
# Prints whose gt-scheduler session runs on this node, seen from the run whose
# directory is given: mine, foreign or none. A run only watches, and only stops, the
# session it started: launch_scheduler.sh leaves that session's id in the run's
# scheduler.session ("starting" for the moment before the id is known, when the launch
# lock guarantees that a session found here can only be the one being started).
run_dir=$1

screen -wipe > /dev/null 2>&1
sessions=$(screen -list 2> /dev/null | grep -o '[0-9]*[.]gt-scheduler')
mine=$(cat "${run_dir}/scheduler.session" 2> /dev/null)

if [ -z "${sessions}" ]; then
    echo none
elif [ "${mine}" == "starting" ] || { [ -n "${mine}" ] && grep -qxF "${mine}" <<< "${sessions}"; }; then
    echo mine
else
    echo foreign
fi
