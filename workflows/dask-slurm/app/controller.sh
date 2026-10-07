set -o pipefail

################################################################################
# Controller - Dask on SLURM
#
# Purpose: Prepare the Python environment with Dask, distributed and
#          dask-jobqueue in a Miniforge (conda-forge) prefix, and write
#          dask-env.sh, the file the service and the workload step source
# Runs on: Login node (internet access; sbatch for the worker jobs)
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - cluster_scheduler_type: must be slurm (the resource's schedulerType)
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_conda_install: Whether to install conda (true/false)
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_install_instructions: latest | yaml | <conda-env-yaml-name>
#       latest  = Miniforge plus the newest dask, distributed, dask-jobqueue, bokeh,
#                 numpy, pandas and pyarrow from conda-forge
#       <name>  = the environment pinned in workflows/dask-slurm/app/<name>.yaml
#       yaml    = the environment pasted in the form (conda-env-form.yaml)
#   - service_load_env: Command to load an environment with Dask (when conda_install=false)
################################################################################

if [ -n "${PW_PARENT_JOB_DIR}" ]; then
    cd "${PW_PARENT_JOB_DIR}"
fi

f_fail() {
    echo "::error title=Error::$1"
    exit 1
}

if [ "${cluster_scheduler_type}" != "slurm" ]; then
    f_fail "This workflow needs a SLURM cluster: the Dask workers are SLURM jobs. The selected resource's scheduler is '${cluster_scheduler_type:-none}'"
fi
command -v sbatch > /dev/null 2>&1 || f_fail "sbatch not found on the login node: the Dask workers are submitted with it"

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p "${service_parent_install_dir}"

source tools/utils/miniforge.sh

conda_prefix=${service_parent_install_dir}/${service_conda_install_dir}
# The installer the environment files under workflows/dask-slurm/app were exported from;
# latest and pasted environments bootstrap the newest Miniforge instead
miniforge_pinned_url=https://github.com/conda-forge/miniforge/releases/download/26.7.2-0/Miniforge3-Linux-x86_64.sh
service_conda_sh=${conda_prefix}/etc/profile.d/conda.sh
dask_packages="dask distributed dask-jobqueue bokeh numpy pandas pyarrow"

# Strips name/prefix so the yaml applies to any environment; prints the hash that keys
# the "environment already matches this yaml" marker
f_prepare_yaml() {
    sed -i -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' "$1"
    sha256sum "$1" | cut -c1-16
}

f_conda_env_exists() {
    conda env list | awk '{print $1}' | grep -qx "$1"
}

f_ensure_conda() {
    if [ ! -f "${service_conda_sh}" ]; then
        echo "::notice::Conda not found in <${conda_prefix}>. Installing Miniforge..."
        miniforge_bootstrap "${conda_prefix}" || f_fail "Miniforge installation failed"
    fi
    echo "::notice::Sourcing Conda SH <${service_conda_sh}>"
    source "${service_conda_sh}" || f_fail "Could not source ${service_conda_sh}"
}

f_set_up_conda_from_yaml() {
    local conda_yaml=$1 yaml_hash=$2
    f_ensure_conda
    if ! f_conda_env_exists "${service_conda_env}"; then
        echo "::notice::Creating Conda Environment <${service_conda_env}>"
        conda create -y --name "${service_conda_env}" || f_fail "Could not create the conda environment ${service_conda_env}"
    fi
    echo "::notice::Updating Conda environment <${service_conda_env}> from ${conda_yaml}"
    conda env update -n "${service_conda_env}" -f "${conda_yaml}" || f_fail "conda env update from ${conda_yaml} failed"
    mkdir -p "${conda_prefix}/.pw-env-markers"
    touch "${conda_prefix}/.pw-env-markers/${service_conda_env}-${yaml_hash}"
}

f_set_up_conda_latest() {
    f_ensure_conda
    if ! f_conda_env_exists "${service_conda_env}"; then
        echo "::notice::Creating Conda Environment <${service_conda_env}>"
        conda create -y --name "${service_conda_env}" || f_fail "Could not create the conda environment ${service_conda_env}"
    fi
    conda activate "${service_conda_env}" || f_fail "Could not activate the conda environment ${service_conda_env}"
    if ! python -c 'import dask_jobqueue, distributed, bokeh, numpy, pandas, pyarrow' > /dev/null 2>&1; then
        echo "::notice::Installing ${dask_packages} into <${service_conda_env}>"
        conda install -y -c conda-forge ${dask_packages} || f_fail "conda install ${dask_packages} failed"
    fi
}

if [[ "${service_conda_install}" == "true" ]]; then
    echo "::group::Dask Installation"
    # Several runs may install into the same prefix at once (a cold cluster): the
    # lock is held until this script exits, so one installs and the others find it
    miniforge_lock "${conda_prefix}" || f_fail "Could not lock ${conda_prefix}"
    if [[ "${service_install_instructions}" == "latest" ]]; then
        echo "::notice::Installing the latest Dask from conda-forge"
        f_set_up_conda_latest
    else
        if [[ "${service_install_instructions}" == "yaml" ]]; then
            echo "::notice::Installing the conda environment pasted in the form"
            [ -s conda-env-form.yaml ] || f_fail "The form's conda environment YAML is empty"
            cp conda-env-form.yaml conda.yaml
        else
            echo "::notice::Installing conda environment ${service_install_instructions}.yaml"
            conda_yaml_src=workflows/dask-slurm/app/${service_install_instructions}.yaml
            [ -f "${conda_yaml_src}" ] || f_fail "Conda environment definition ${conda_yaml_src} not found in $(pwd)"
            cp "${conda_yaml_src}" conda.yaml
            export MINIFORGE_URL=${miniforge_pinned_url}
        fi
        cat conda.yaml
        yaml_hash=$(f_prepare_yaml conda.yaml)
        env_marker=${conda_prefix}/.pw-env-markers/${service_conda_env}-${yaml_hash}
        if [ -f "${service_conda_sh}" ] && [ -f "${env_marker}" ]; then
            echo "::notice::Conda environment <${service_conda_env}> in <${conda_prefix}> already matches conda.yaml; skipping the update"
        else
            f_set_up_conda_from_yaml conda.yaml "${yaml_hash}"
        fi
    fi
    echo "::endgroup::"
    if [ -z "${service_load_env}" ]; then
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
fi

# dask-env.sh puts the environment on PATH for the service (start-template.sh) and
# the workload step; a workflow step is not a login shell, so `module` is initialized
# first for a load command that needs it
cat > dask-env.sh << EOT
# Dask environment: $( [[ "${service_conda_install}" == "true" ]] && echo "the conda-forge env under ${conda_prefix}" || echo "the load command given in the workflow form" )
if ! command -v module > /dev/null 2>&1; then
    for f in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \\
             /usr/share/lmod/lmod/init/bash /usr/share/Modules/init/bash; do
        if [ -r "\${f}" ]; then
            source "\${f}"
            break
        fi
    done
fi
${service_load_env}
EOT

if ! out=$(bash -c 'source ./dask-env.sh && python -c "
import dask, distributed, dask_jobqueue, bokeh, numpy, pandas
print(f\"dask {dask.__version__}, distributed {distributed.__version__}, dask-jobqueue {dask_jobqueue.__version__}, bokeh {bokeh.__version__}, numpy {numpy.__version__}, pandas {pandas.__version__}\")
"' 2>&1); then
    echo "${out}"
    echo "--- dask-env.sh"
    cat dask-env.sh
    f_fail "Sourcing dask-env.sh does not provide a Python with dask, distributed, dask-jobqueue, bokeh, numpy and pandas"
fi
echo "::notice::Dask environment ready: ${out##*$'\n'}"
