#!/bin/bash
# Usage: prepare-env.sh <openfoam|dakota> <env-file> [required-command...] < load-snippet
#
# Writes <env-file>, the script every later step and every case `source`s to put
# the tool on PATH. Its content is the load snippet read from stdin (the form's
# software.<tool>_load: `module load ...`, `source .../etc/bashrc`, exports) when
# one was given, else the activation of the conda-forge env that install-<tool>.sh
# creates (installed here first, idempotently). The file is then sourced in a
# fresh shell and every required command must resolve, so a snippet that does not
# deliver the tool fails the run in preprocessing rather than in the first case.
set -o pipefail
cd "$(dirname "$0")"
source ./install-common.sh

tool="$1"
env_file="$2"
shift 2
required=("$@")

case "${tool}" in
    openfoam|dakota) ;;
    *) echo "::error::prepare-env.sh: unknown tool '${tool}' (openfoam|dakota)"; exit 1 ;;
esac

snippet=$(cat)
if [ -n "$(printf '%s' "${snippet}" | tr -d '[:space:]')" ]; then
    echo "::notice::${tool}: using the environment commands from the form"
    # a workflow step is not a login shell, so `module` may be undefined: initialize
    # it from the usual init files before the snippet runs (no-op where it exists)
    cat > "${env_file}" << EOF
# ${tool} environment: the commands given in the workflow form
if ! command -v module > /dev/null 2>&1; then
    for f in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \\
             /usr/share/lmod/lmod/init/bash /usr/share/Modules/init/bash; do
        if [ -r "\${f}" ]; then
            source "\${f}"
            break
        fi
    done
fi
${snippet}
EOF
else
    echo "::notice::${tool}: no environment commands given; using the conda-forge install"
    bash "./install-${tool}.sh" || exit 1
    cat > "${env_file}" << EOF
# ${tool} environment: the conda-forge env created by install-${tool}.sh
source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh"
conda activate ${tool}
EOF
fi

# a required `mpirun` means "the MPI launcher": an environment that exports MPIRUN
# (simulator.sh's launcher override, e.g. `srun`) is checked for that command instead
printf -v check 'source %q\n' "${env_file}"
for cmd in "${required[@]}"; do
    if [ "${cmd}" = mpirun ]; then
        check+='launcher="${MPIRUN:-mpirun}"; command -v "${launcher%% *}" > /dev/null || { echo "MPI launcher ${launcher%% *} not found on PATH"; exit 1; }'$'\n'
    else
        printf -v line 'command -v %q > /dev/null || { echo "%s not found on PATH"; exit 1; }\n' "${cmd}" "${cmd}"
        check+="${line}"
    fi
done
if ! out=$(bash -c "${check}" 2>&1); then
    echo "::error::${tool}: sourcing ${env_file} does not provide ${required[*]}"
    echo "${out}"
    echo "--- ${env_file}"
    cat "${env_file}"
    exit 1
fi
echo "::notice::${tool} environment ready: ${env_file} provides ${required[*]}"
