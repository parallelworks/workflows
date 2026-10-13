################################################################################
# Interactive Session Service Starter - marimo
#
# Purpose: Serve marimo (edit or run mode) through a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Installation directory
#   - service_conda_install: Whether conda was installed by the controller
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_load_env: Command to load marimo (when conda_install=false)
#   - service_mode: edit | run
#   - service_script: notebook (.py) to open or serve; in edit mode a directory opens
#       marimo's home page there and an empty value opens it in ${HOME}
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [[ "${service_conda_install}" == "true" ]] && [ -z "${service_load_env}" ]; then
    service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi
eval "${service_load_env}"

if ! command -v marimo > /dev/null 2>&1; then
    echo "::error title=Error::marimo command not found"
    exit 1
fi

service_mode=${service_mode:-edit}
# {port} is replaced by pw endpoints run with the local port it forwards to; the
# endpoint already requires the platform login, so marimo's own token is off
marimo_args=(--host 127.0.0.1 --port {port} --headless --no-token)

case "${service_mode}" in
    run)
        if [ -z "${service_script}" ]; then
            echo "::error title=Error::Run mode needs the path of the notebook to serve"
            exit 1
        fi
        if ! [ -f "${service_script}" ]; then
            echo "::error title=Error::Notebook ${service_script} not found"
            exit 1
        fi
        cd "$(dirname "${service_script}")"
        marimo_cmd=(marimo run "${service_script}" "${marimo_args[@]}")
        ;;
    edit)
        if [ -z "${service_script}" ]; then
            cd "${HOME}"
            marimo_cmd=(marimo edit "${marimo_args[@]}")
        elif [ -d "${service_script}" ]; then
            cd "${service_script}"
            marimo_cmd=(marimo edit "${marimo_args[@]}")
        elif [ -f "${service_script}" ] || [[ "${service_script}" == *.py ]]; then
            # a .py that does not exist yet is a new notebook: marimo creates it on save
            mkdir -p "$(dirname "${service_script}")"
            cd "$(dirname "${service_script}")"
            marimo_cmd=(marimo edit "${service_script}" "${marimo_args[@]}")
        else
            echo "::error title=Error::${service_script} is neither a notebook (.py) nor a directory"
            exit 1
        fi
        ;;
    *)
        echo "::error title=Error::Unknown mode ${service_mode} (expected edit or run)"
        exit 1
        ;;
esac

echo "::group::Start Service"
echo "::notice::Starting marimo in $(pwd): pw endpoints run ${pw_endpoints_args} -- ${marimo_cmd[*]}"

set -x
pw endpoints run ${pw_endpoints_args} -- "${marimo_cmd[@]}"

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
