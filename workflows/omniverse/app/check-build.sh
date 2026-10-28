#!/bin/bash
# check-build.sh <exit file>
# The builder's verdict, after the submitter (which never forwards the script's exit
# status): no exit file means the script never ran to its end, a non-zero one that the
# build failed. Publishes SCENE. Runs in the job directory on the login node.
set -o pipefail
set -x
exit_file="$1"
if [ ! -f "${exit_file}" ]; then
    echo "::error title=Error::No exit status in ${exit_file}: the build script did not run to its end (killed, walltime exceeded, node failure); the tail of its output follows"
    tail -n 40 run.*.out 2> /dev/null
    exit 1
fi
status=$(cat "${exit_file}")
if [ "${status}" != "0" ]; then
    echo "::error title=Error::The build exited with status ${status}; the tail of its output follows"
    tail -n 40 run.*.out 2> /dev/null
    exit 1
fi
scene=$(python3 -c "import json; print(json.load(open('build/build.json'))['scene'])")
echo "::notice::The scene is ${PWD}/build/${scene}, with its assets under build/assets/; give that directory, or where it was copied, as the render workflow's source"
echo "SCENE=${PWD}/build/${scene}" | tee -a "${OUTPUTS}"
