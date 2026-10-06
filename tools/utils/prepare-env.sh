#!/bin/bash
# Usage: prepare-env.sh <tool> <env-file> <installer> [required-command...] < load-snippet
#
# Writes <env-file>, the script every later step and every case `source`s to put
# <tool> on PATH. Its content is the load snippet read from stdin (the form's
# "<tool> environment commands": `module load ...`, `source .../etc/bashrc`,
# exports) when one was given; otherwise <installer> runs (`bash <installer>
# <env-file>`): it installs the tool idempotently and writes the activation of
# what it installed into <env-file>. The file is then sourced in a fresh shell
# and every required command must resolve, so a snippet that does not deliver
# the tool fails the run in preprocessing rather than in the first case.
set -o pipefail

tool="$1"
env_file="$2"
installer="$3"
shift 3
required=("$@")
if [ -z "${tool}" ] || [ -z "${env_file}" ] || [ -z "${installer}" ]; then
    echo "::error::usage: prepare-env.sh <tool> <env-file> <installer> [required-command...] < load-snippet"
    exit 1
fi

snippet=$(cat)
if [ -n "$(printf '%s' "${snippet}" | tr -d '[:space:]')" ]; then
    echo "::notice::${tool}: using the environment commands from the form"
    # a workflow step is not a login shell, so `module` may be undefined: initialize
    # it from the usual init files before the snippet runs (no-op where it exists)
    cat > "${env_file}" << EOT
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
EOT
else
    echo "::notice::${tool}: no environment commands given; running $(basename "${installer}")"
    bash "${installer}" "${env_file}" || exit 1
    if [ ! -f "${env_file}" ]; then
        echo "::error::${tool}: ${installer} did not write ${env_file}"
        exit 1
    fi
fi

# a required `mpirun` means "the MPI launcher": an environment that exports MPIRUN
# (the launcher override, e.g. `srun --mpi=pmix`) is checked for that command instead
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
