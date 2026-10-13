################################################################################
# Interactive Session Service Starter - Burst Render dashboard
#
# Purpose: Serve the live tile dashboard (FastAPI + WebSocket) behind a pw endpoint
# Runs on: Controller (login) node of the dashboard host
# Called by: Workflow after controller setup, through script_submitter
#
# Required Environment Variables (from inputs.sh):
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Parent directory of the installation
#   - PW_PARENT_JOB_DIR: Run directory; SESSION_PORT is published there
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

app_dir="${PW_PARENT_JOB_DIR}/workflows/burst-render-demo/app"
python="${service_parent_install_dir}/burst-render-demo/venv/bin/python"
port_file="${PW_PARENT_JOB_DIR}/SESSION_PORT"

if [ ! -x "${python}" ]; then
    echo "::error title=Error::Dashboard environment not found at ${python}"
    exit 1
fi
if [ ! -f "${app_dir}/dashboard.py" ]; then
    echo "::error title=Error::dashboard.py not found at ${app_dir}"
    exit 1
fi

rm -f "${port_file}"
# pw endpoints run assigns the local port and exports it as PORT to the command it
# wraps; the launcher publishes it for the render job, whose /api/config call and
# site tunnels target localhost:PORT on this host
cat <<EOF > launch-dashboard.sh
#!/bin/bash
echo "\${PORT}" > "${port_file}"
exec "${python}" -m uvicorn dashboard:app --host 0.0.0.0 --port "\${PORT}" --app-dir "${app_dir}"
EOF
chmod +x launch-dashboard.sh

echo "::group::Start Service"
echo "::notice::Starting dashboard: pw endpoints run ${pw_endpoints_args} -- ./launch-dashboard.sh"

set -x
pw endpoints run ${pw_endpoints_args} -- ./launch-dashboard.sh

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Only a
    # launch that never registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
