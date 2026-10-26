# Sourced by start-template.sh and build-template.sh on the node that runs the job,
# after inputs.sh: the directories, the GPU check, the container runtime
# (omniverse-<runtime>/runtime.sh) and how a script is run in the Isaac Sim container.

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
app_dir="${PW_PARENT_JOB_DIR}/workflows/omniverse/app"
runtime_dir="${PW_PARENT_JOB_DIR}/workflows/omniverse/${software_runtime}"
cache_dir="${service_parent_install_dir}/omniverse/cache"
mkdir -p "${cache_dir}/kit"

# The GPU: the scheduler's allocation when there is one, else every GPU of the node
if ! smi=$(nvidia-smi -L 2>&1) || ! grep -q '^GPU ' <<< "${smi}"; then
    echo "::error title=Error::No usable GPU on $(hostname): $(head -n 1 <<< "${smi}"). Choose a GPU node (partition, GPUs per job) or a GPU server."
    exit 1
fi
echo "${smi}"

# What every container run gets, besides the binds the caller lists in
# container_binds (host:container[:ro]): Isaac Sim's home and Kit's cache in the
# install directory (the shader caches compile once, later runs on the node start
# fast), the license, the app directory for the scripts' imports. A FIPS host
# (/proc is not namespaced) makes the image's OpenSSL fail without a FIPS provider,
# so it is told not to use one
container_env=(ACCEPT_EULA=Y OMNIVERSE_APP=/app)
if [ "$(cat /proc/sys/crypto/fips_enabled 2> /dev/null)" = 1 ]; then
    container_env+=(OPENSSL_FORCE_FIPS_MODE=0)
fi
container_binds=()

# runtime_setup, write_cancel_script and container_run, per runtime
source "${runtime_dir}/runtime.sh"
