#!/bin/bash
cd "$(dirname "$0")"
source inputs.sh

screen -wipe > /dev/null 2>&1
if screen -list | grep -q '[.]gt-scheduler'; then
    # A session this run started means the launch is being retried after a dropped
    # connection; any other one is another run's scheduler, and a second sensing
    # loop on the same cluster would fight it over the same executors
    if [ -f scheduler.session ]; then
        echo "The gt-scheduler session of this run is already running"
        exit 0
    fi
    echo "ERROR: A gt-scheduler screen session is already running on $(hostname). A cluster runs one GT scheduler at a time."
    exit 1
fi

touch scheduler.session
screen -dmS gt-scheduler bash -c "./scheduler.sh &> logs.out"
