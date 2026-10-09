#!/bin/bash
# Usage: install-tensorboard.sh <python-path-file>
# Idempotent install of TensorBoard from conda-forge (no sudo) as the env
# `tensorboard` of the Miniforge prefix
# ${service_parent_install_dir:-$HOME/pw/software}/physicsnemo/miniforge, for
# tensorboard-server.py on the login node. The login node may have neither the
# training container nor Docker, so TensorBoard does not run from the image.
# Runs on the login node with internet access; a working env is kept. Writes the
# env's python interpreter to <python-path-file>. TENSORBOARD_VERSION pins the
# release (default 2.20.0).
set -o pipefail

path_file="$1"
if [ -z "${path_file}" ]; then
    echo "::error::usage: install-tensorboard.sh <python-path-file>"
    exit 1
fi
app_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${app_dir}/../../../tools/utils/miniforge.sh" || exit 1

TENSORBOARD_VERSION="${TENSORBOARD_VERSION:-2.20.0}"
prefix=$(miniforge_prefix physicsnemo)
python="${prefix}/envs/tensorboard/bin/python"

f_ok() {
    [ -x "${python}" ] && "${python}" -c "import tensorboard, sys; sys.exit(tensorboard.__version__ != '${TENSORBOARD_VERSION}')" > /dev/null 2>&1
}

miniforge_lock "${prefix}" || exit 1
if f_ok; then
    echo "::notice::TensorBoard ${TENSORBOARD_VERSION} already installed in ${prefix}/envs/tensorboard"
else
    miniforge_bootstrap "${prefix}" || exit 1
    echo "::notice::Installing TensorBoard ${TENSORBOARD_VERSION} into ${prefix}/envs/tensorboard"
    "${prefix}/bin/conda" create -y -q -n tensorboard -c conda-forge "python=3.12" "tensorboard=${TENSORBOARD_VERSION}" || {
        echo "::error::Could not create the TensorBoard environment in ${prefix}"
        exit 1
    }
    if ! f_ok; then
        echo "::error::TensorBoard ${TENSORBOARD_VERSION} does not import from ${python}"
        exit 1
    fi
fi
echo "${python}" > "${path_file}"
