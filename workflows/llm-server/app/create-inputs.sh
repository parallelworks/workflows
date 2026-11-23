#!/bin/bash
# create-inputs.sh <form file>: the Create Inputs step of every variant
# (yamls/*.yaml). Writes ./inputs.sh from the run's PW_* environment and the
# form file, a list of key="value" lines the YAML renders from its inputs, and
# publishes the endpoint name and the GPU count the scheduler request needs.
#
# The form values are copied, never evaluated here: a path such as
# ${PROJECTS_HOME:-$HOME/pw}/hsp expands where inputs.sh is sourced.

set -o pipefail

form=$1
if [ ! -s "${form}" ]; then
    echo "::error title=Error::form file ${form:-<none>} is missing or empty"
    exit 1
fi

form_value() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "${form}" | sed 's/^undefined$//' | head -1; }

engine=$(form_value engine)
case "${engine}" in
    vllm|sglang|llamacpp) ;;
    *)
        echo "::error title=Error::unknown inference engine '${engine}'; expected vllm, sglang or llamacpp"
        exit 1
        ;;
esac

# An endpoint name becomes a DNS label: lowercase a-z 0-9 and dashes only
endpoint_name=$(form_value endpoint_name | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
endpoint_name="${endpoint_name:-${engine}-${PW_RUN_SLUG}}"

case "${engine}" in
    llamacpp) num_gpus=1 ;;
    *) num_gpus=$(form_value "${engine}_num_gpus") ;;
esac
case "${num_gpus}" in
    ''|*[!0-9]*) num_gpus=1 ;;
esac

{
    # PW_API_KEY stays out: it dies with the run, and a script that needs it
    # reads the runtime environment
    env | grep '^PW_' | grep -v 'PW_API_KEY' | sed 's/=\(.*\)/="\1"/'
    echo 'PATH=$HOME/pw:$PATH'
    grep -v '^endpoint_name=' "${form}"
    echo "endpoint_name=\"${endpoint_name}\""
    echo "pw_endpoints_args=\"--name ${endpoint_name} --openai\""
} > inputs.sh

# An input the form hides, ignores or leaves empty is dropped, so the scripts
# test a variable with -n and take their own default
sed -i '/^[A-Za-z_0-9]*=\s*$/d; /^[A-Za-z_0-9]*=undefined\s*$/d; /^[A-Za-z_0-9]*=""\s*$/d; /^[A-Za-z_0-9]*="undefined"\s*$/d' inputs.sh
sed -i 's/^/export /' inputs.sh

{
    echo "ENDPOINT_NAME=${endpoint_name}"
    echo "NUM_GPUS=${num_gpus}"
} | tee -a "${OUTPUTS:-/dev/null}"
