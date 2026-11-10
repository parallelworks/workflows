#!/bin/bash
cd "$(dirname "$0")"
source inputs.sh
set -x

# One launch at a time on this node, so that two runs which both found it free cannot
# both get past the check below. The lock ends with this script: screen is started
# without it (9>&-), or the session would hold it for as long as it lives
if command -v flock > /dev/null 2>&1; then
    exec 9> "/tmp/gt-scheduler-${USER}.lock"
    if ! flock -w 120 9; then
        echo "ERROR: Another launch has held /tmp/gt-scheduler-${USER}.lock for two minutes"
        exit 1
    fi
fi

case "$(./session.sh "${PWD}")" in
    mine)
        # The launch is being retried after a dropped connection
        echo "The gt-scheduler session of this run is already running"
        ;;
    foreign)
        echo "ERROR: A gt-scheduler screen session is already running on $(hostname). A cluster runs one GT scheduler at a time."
        exit 1
        ;;
    *)
        echo starting > scheduler.session
        screen -dmS gt-scheduler bash -c "./scheduler.sh &> logs.out" 9>&-
        ;;
esac

session=$(screen -list | grep -o '[0-9]*[.]gt-scheduler' | head -n 1)
if [ -z "${session}" ]; then
    rm -f scheduler.session
    echo "ERROR: The gt-scheduler screen session did not start on $(hostname)"
    exit 1
fi
echo "${session}" > scheduler.session
