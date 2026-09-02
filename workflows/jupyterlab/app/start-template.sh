################################################################################
# Interactive Session Service Starter - JupyterLab Host
#
# Purpose: Serve JupyterLab through a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug, ...)
#   - service_parent_install_dir: Installation directory
#   - service_conda_install: Whether conda was installed by the controller
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_load_env: Command to load jupyter-lab (when conda_install=false)
#   - service_notebook_dir: JupyterLab root directory (default: ${HOME})
#   - service_password: Access password (optional)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [[ "${service_conda_install}" == "true" ]] && [ -z "${service_load_env}" ]; then
    service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi
eval "${service_load_env}"

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    echo "::error title=Error::jupyter-lab command not found"
    exit 1
fi

if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir=${HOME}
fi

# service_base_url is the endpoint's base path: unset ("/") on subdomain
# endpoints, /me/session/<user>/<name>/ on path-based ones (--no-subdomain),
# where the emed YAML computes it in preprocessing. Do NOT use the {path}
# token for this: it includes the --slug, so base_url would become
# <prefix>/lab and the lab UI would hide at <prefix>/lab/lab (verified).
# default_url is pinned because a site-wide jupyter config can redirect the
# server root to /tree, serving the Notebook UI instead of JupyterLab
# (verified on cluster.einsteinmed.edu's shared conda env).
cat > jupyter_lab_config.py <<EOF
c.ServerApp.root_dir = '${service_notebook_dir}'
c.ServerApp.base_url = '${service_base_url:-/}'
c.ServerApp.default_url = '/lab'
c.ServerApp.allow_remote_access = True
c.IdentityProvider.token = ''
EOF

if ! [ -z "${service_password}" ]; then
    python3 <<'PYEOF' >> jupyter_lab_config.py
import os
from jupyter_server.auth import passwd
print(f"c.PasswordIdentityProvider.hashed_password = '{passwd(os.environ['service_password'])}'")
PYEOF
fi

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting JupyterLab: pw endpoints run ${pw_endpoints_args} -- jupyter-lab --port {port} (base_url=${service_base_url:-/})"

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- jupyter-lab \
    --port {port} \
    --no-browser \
    --allow-root \
    --config ${PWD}/jupyter_lab_config.py

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Treating
    # that as a failure cancelled the whole run from inside the compute job:
    # ollama_gguf runs 24-26 finished "canceled" with the service up, until
    # #1055 disabled this line for that service. Only a launch that never
    # registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    exit 1
fi
echo "::endgroup::"
