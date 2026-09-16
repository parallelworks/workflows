set -o pipefail

################################################################################
# Interactive Session Controller - JupyterLab Host
#
# Purpose: Install JupyterLab in a conda environment
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_conda_install: Whether to install conda (true/false)
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_install_instructions: latest | yaml | <conda-env-yaml-name>
#   - service_conda_source: auto | native | artifact (default: auto)
#       native   = download Miniconda from repo.anaconda.com and build the env
#       artifact = unpack the prebuilt env ghcr.io/parallelworks/jupyterlab-conda:<install_instructions>
#       auto     = native, falling back to artifact when the native path fails
#   - service_load_env: Command to load jupyter-lab (when conda_install=false)
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p ${service_parent_install_dir}

conda_prefix=${service_parent_install_dir}/${service_conda_install_dir}
service_conda_sh=${conda_prefix}/etc/profile.d/conda.sh
service_conda_source=${service_conda_source:-auto}
conda_artifact_registry=${conda_artifact_registry:-ghcr.io/parallelworks/jupyterlab-conda}
# Written into the prefix by whichever path installed it (native | artifact). Only a
# prefix carrying it may be wiped when the native setup fails and the artifact takes over.
conda_source_marker=.pw-jupyterlab-conda-source

f_fail() {
    echo "::error title=Error::$1"
    exit 1
}

# Strips name/prefix so the yaml applies to any environment; prints the hash that keys
# the "environment already matches this yaml" marker (the artifact build uses the same hash)
f_prepare_yaml() {
    sed -i -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' $1
    sha256sum $1 | cut -c1-16
}

f_install_miniconda() {
    local install_dir=$1 conda_repo installer
    if [[ "${service_install_instructions}" == "latest" ]]; then
        conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    else
        conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.9.2-0-Linux-x86_64.sh"
    fi
    installer=$(mktemp /tmp/miniconda-XXXXXX.sh)
    echo "::notice::Downloading ${conda_repo}"
    if ! wget --no-check-certificate --timeout=60 --tries=3 -nv -O ${installer} ${conda_repo}; then
        rm -f ${installer}
        echo "::warning::Could not download ${conda_repo}"
        return 1
    fi
    rm -rf ${install_dir}
    mkdir -p $(dirname ${install_dir})
    if ! bash ${installer} -b -p ${install_dir}; then
        rm -f ${installer}
        rm -rf ${install_dir}
        echo "::warning::The Miniconda installer failed"
        return 1
    fi
    rm -f ${installer}
    echo native > ${install_dir}/${conda_source_marker}
    source ${install_dir}/etc/profile.d/conda.sh || return 1
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
}

f_conda_env_exists() {
    conda env list | awk '{print $1}' | grep -qx "$1"
}

f_set_up_conda_from_yaml() {
    local conda_dir=$1 conda_env=$2 conda_yaml=$3 yaml_hash=$4
    local conda_sh=${conda_dir}/etc/profile.d/conda.sh

    if [ ! -f "${conda_sh}" ]; then
        echo "::notice::Conda not found in <${conda_dir}>. Installing Miniconda..."
        f_install_miniconda ${conda_dir} || return 1
    fi
    echo "::notice::Sourcing Conda SH <${conda_sh}>"
    source ${conda_sh} || return 1

    if ! f_conda_env_exists ${conda_env}; then
        echo "::notice::Creating Conda Environment <${conda_env}>"
        conda create -y --name ${conda_env} || return 1
    fi
    echo "::notice::Updating Conda environment <${conda_env}> from ${conda_yaml}"
    conda env update -n ${conda_env} -f ${conda_yaml} || return 1
    mkdir -p ${conda_dir}/.pw-env-markers
    touch ${conda_dir}/.pw-env-markers/${conda_env}-${yaml_hash}
}

f_set_up_conda_latest() {
    local conda_dir=$1 conda_env=$2
    local conda_sh=${conda_dir}/etc/profile.d/conda.sh

    if [ ! -f "${conda_sh}" ]; then
        echo "::notice::Conda not found in <${conda_dir}>. Installing Miniconda..."
        f_install_miniconda ${conda_dir} || return 1
    fi
    source ${conda_sh} || return 1
    if ! f_conda_env_exists ${conda_env}; then
        conda create -y -n ${conda_env} jupyter || return 1
    fi
    conda activate ${conda_env} || return 1
    if [ -z "$(which jupyter-lab 2> /dev/null)" ]; then
        conda install -y -c conda-forge jupyterlab || return 1
        conda install -y nb_conda_kernels || return 1
        conda install -y -c anaconda jinja2 || return 1
        pip install ipywidgets || return 1
        if command -v sinfo &> /dev/null; then
            # SLURM extension for Jupyter Lab https://github.com/NERSC/jupyterlab-slurm
            pip install jupyterlab_slurm || return 1
        fi
    fi
}

f_install_conda_artifact() {
    local conda_dir=$1 conda_env=$2 tag=$3 yaml_hash=$4
    local ref=${conda_artifact_registry}:${tag}
    local tarball=${PWD}/conda-env.tar.gz
    local arch glibc

    case "${tag}" in
        yaml|latest)
            f_fail "No prebuilt conda environment exists for the '${tag}' installation. Select 'Jupyter Lab 4.1.5 with Python 3.11.5' (jupyterlab4.1.5-python3.11.5): it is the installation that works when repo.anaconda.com is unreachable"
            ;;
    esac
    if [[ "${conda_env}" != "base" ]]; then
        f_fail "The prebuilt conda environment only provides the base environment; set the conda environment to base (got '${conda_env}')"
    fi
    arch=$(uname -m)
    glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
    if [[ "${arch}" != "x86_64" ]] || [[ "$(printf '%s\n' 2.28 "${glibc:-0}" | sort -V | head -1)" != "2.28" ]]; then
        f_fail "The prebuilt conda environment needs x86_64 and glibc >= 2.28; this node has ${arch} and glibc ${glibc:-unknown}"
    fi
    if [ -d "${conda_dir}" ]; then
        if [ -f "${conda_dir}/${conda_source_marker}" ]; then
            echo "::warning::Removing the conda installation in <${conda_dir}> left by the failed setup"
            rm -rf ${conda_dir}
        else
            f_fail "<${conda_dir}> exists but was not installed by this workflow; fix that environment or choose another conda installation directory to unpack the prebuilt environment into"
        fi
    fi

    echo "::notice::Pulling the prebuilt conda environment ${ref}"
    source tools/oras/libs.sh
    oras_pull_file ${ref} conda-env.tar.gz ${tarball}
    if [ ! -s "${tarball}" ]; then
        f_fail "The artifact ${ref} did not contain conda-env.tar.gz"
    fi
    echo "::notice::Unpacking the environment into <${conda_dir}>"
    mkdir -p ${conda_dir}
    if ! tar -xzf ${tarball} -C ${conda_dir}; then
        rm -rf ${conda_dir} ${tarball}
        f_fail "Could not unpack conda-env.tar.gz into <${conda_dir}>"
    fi
    rm -f ${tarball}
    # conda-unpack's shebang is /usr/bin/env python, which RHEL 8 hosts do not provide
    if ! ${conda_dir}/bin/python ${conda_dir}/bin/conda-unpack; then
        rm -rf ${conda_dir}
        f_fail "conda-unpack failed in <${conda_dir}>"
    fi
    echo artifact > ${conda_dir}/${conda_source_marker}
    mkdir -p ${conda_dir}/.pw-env-markers
    touch ${conda_dir}/.pw-env-markers/${conda_env}-${yaml_hash}
    source ${conda_dir}/etc/profile.d/conda.sh || f_fail "Could not source ${conda_dir}/etc/profile.d/conda.sh after unpacking ${ref}"
    echo "::notice::Prebuilt conda environment ${ref} installed in <${conda_dir}>"
}

# $1 native setup: "yaml <file>" or "latest"; $2 artifact tag; $3 yaml hash ("" for latest)
f_provide_conda() {
    local native=$1 tag=$2 yaml_hash=$3
    f_native() {
        if [[ "${native}" == "latest" ]]; then
            f_set_up_conda_latest ${conda_prefix} ${service_conda_env}
        else
            f_set_up_conda_from_yaml ${conda_prefix} ${service_conda_env} ${native#yaml } ${yaml_hash}
        fi
    }
    case "${service_conda_source}" in
        native)
            f_native || f_fail "Conda setup failed and conda_source=native disables the prebuilt fallback"
            ;;
        artifact)
            f_install_conda_artifact ${conda_prefix} ${service_conda_env} ${tag} "${yaml_hash}"
            ;;
        *)
            if ! f_native; then
                echo "::warning::Conda setup from repo.anaconda.com failed; falling back to the prebuilt environment ${conda_artifact_registry}:${tag}"
                f_install_conda_artifact ${conda_prefix} ${service_conda_env} ${tag} "${yaml_hash}"
            fi
            ;;
    esac
}

if [[ "${service_conda_install}" == "true" ]]; then
    echo "::group::Conda Installation"
    if [[ "${service_install_instructions}" == "install_command" ]]; then
        echo "::notice::Running install command ${service_install_command}"
        eval ${service_install_command}
    elif [[ "${service_install_instructions}" == "latest" ]]; then
        echo "::notice::Installing latest conda environment"
        f_provide_conda latest latest ""
    else
        if [[ "${service_install_instructions}" == "yaml" ]]; then
            echo "::notice::Installing custom conda environment"
            printf "%b" "${service_yaml}" > conda.yaml
            cat conda.yaml
            conda_yaml=conda.yaml
        else
            echo "::notice::Installing conda environment ${service_install_instructions}.yaml"
            conda_yaml=${service_install_instructions}.yaml
        fi
        [ -f "${conda_yaml}" ] || f_fail "Conda environment definition ${conda_yaml} not found in $(pwd)"
        yaml_hash=$(f_prepare_yaml ${conda_yaml})
        env_marker=${conda_prefix}/.pw-env-markers/${service_conda_env}-${yaml_hash}
        if [ -f "${service_conda_sh}" ] && [ -f "${env_marker}" ]; then
            echo "::notice::Conda environment <${service_conda_env}> in <${conda_prefix}> already matches ${conda_yaml}; skipping the update"
        else
            f_provide_conda "yaml ${conda_yaml}" ${service_install_instructions} ${yaml_hash}
        fi
    fi
    echo "::endgroup::"
    if [ -z "${service_load_env}" ]; then
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
fi

eval "${service_load_env}"

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    echo "::error title=Error::jupyter-lab command not found"
    exit 1
fi

if [[ "${service_conda_install}" != "true" ]]; then
    exit 0
fi

if [ -n "${service_install_kernels}" ] && [[ "$(cat ${conda_prefix}/${conda_source_marker} 2>/dev/null)" == "artifact" ]]; then
    echo "::warning::Skipping the additional kernels (${service_install_kernels}): this conda environment came from the prebuilt artifact, used because repo.anaconda.com was unreachable, and installing kernels needs those repositories"
    exit 0
fi

if [[ $service_install_kernels == *"julia-kernel"* ]]; then
    if [ -z $(which julia 2> /dev/null) ]; then
        curl -fsSL https://install.julialang.org | sh -s -- -y
        source ~/.bashrc
        source ~/.bash_profile
        julia -e 'using Pkg; Pkg.add("IJulia")'
    fi
fi

if [[ $service_install_kernels == *"R-kernel"* ]]; then
    conda install r-recommended r-irkernel -y
    R -e 'IRkernel::installspec()'
fi
