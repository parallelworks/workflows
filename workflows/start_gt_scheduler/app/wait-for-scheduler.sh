#!/bin/bash
# The run's evidence that the scheduler works: it completes once the scheduler's
# first sensing cycle has run with the GT daemon active, and fails the run when the
# scheduler exits or never gets there.
set -o pipefail
cd "${PW_PARENT_JOB_DIR:-${PWD}}"
source inputs.sh
source controller.env
source workflows/start_gt_scheduler/app/libs.sh

fail() {
    echo "::error title=Error::$1"
    echo "The end of ${remote_dir}/logs.out on ${controller}:"
    controller_ssh "tail -n 40 ${remote_dir}/logs.out"
    exit 1
}

# The scheduler job fails the run when it cannot launch, which cancels this step:
# the limit here only keeps the wait from being open-ended
waited=0
until [ -f scheduler.launched ]; do
    [ ${waited} -lt 3600 ] || fail "The scheduler was not launched within ${waited} s"
    sleep 5
    waited=$((waited + 5))
done

cycle=${adv_pw_ds_cycle:-60}
budget=$((2 * cycle + 600))
waited=0
while true; do
    report=$(controller_ssh "echo session=\$(screen -list | grep -c '[.]gt-scheduler'); echo daemon=\$(systemctl is-active gtdistd.service); echo cycles=\$(grep -c 'CORE SUPPLY:' ${remote_dir}/logs.out 2> /dev/null)")
    session=$(sed -n 's/^session=//p' <<< "${report}")
    daemon=$(sed -n 's/^daemon=//p' <<< "${report}")
    cycles=$(sed -n 's/^cycles=//p' <<< "${report}")
    echo "$(date) session=${session:-?} gtdistd=${daemon:-?} sensing cycles=${cycles:-?}"

    if [ "${session}" == "0" ]; then
        fail "The GT scheduler on ${controller} exited before its first sensing cycle"
    fi
    if [ "${daemon}" == "active" ] && [ "${cycles:-0}" -ge 1 ]; then
        break
    fi
    [ ${waited} -lt ${budget} ] || fail "The GT scheduler on ${controller} did not complete a sensing cycle within ${budget} s"
    sleep 15
    waited=$((waited + 15))
done

echo "::notice::GT scheduler ${gt_version} is running on ${resource_name}: gtdistd is active and the first sensing cycle completed. GT clients submit to ${controller#*@}. Cancel this run to stop it."
