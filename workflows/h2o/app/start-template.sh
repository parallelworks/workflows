################################################################################
# Interactive Session Service Starter - H2O-3
#
# Purpose: Serve H2O-3 and its Flow UI through a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug, ...)
#   - service_parent_install_dir: Installation directory
#   - service_download_url: H2O-3 release zip the controller installed
#   - service_load_env: Command that puts java on the PATH (optional)
#   - service_jvm_args: Extra JVM arguments, e.g. -Xmx8g (optional)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_install_dir=${service_parent_install_dir}/$(basename "${service_download_url}" .zip)
service_jar=${service_install_dir}/h2o.jar
service_jre_dir=${service_parent_install_dir}/h2o-jre

if ! [ -f "${service_jar}" ]; then
    echo "::error title=Error::Missing ${service_jar}"
    exit 1
fi

eval "${service_load_env}"
if ! command -v java > /dev/null 2>&1 && [ -x "${service_jre_dir}/bin/java" ]; then
    export PATH=${service_jre_dir}/bin:${PATH}
fi
if ! command -v java > /dev/null 2>&1; then
    echo "::error title=Error::java command not found"
    exit 1
fi

echo "::group::Start Service"
echo "::notice::Starting H2O with $(command -v java) ($(java -version 2>&1 | head -1)): pw endpoints run ${pw_endpoints_args} -- java ${service_jvm_args} -jar ${service_jar} -port {port}"

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to. The
# REST API and Flow bind to the loopback the tunnel reaches, and the cloud name
# is unique per run so two H2O nodes on one network never join each other.
pw endpoints run ${pw_endpoints_args} -- java ${service_jvm_args} -jar "${service_jar}" \
    -port {port} \
    -ip 127.0.0.1 \
    -web_ip 127.0.0.1 \
    -name "h2o-${PW_RUN_SLUG}" \
    -log_dir "${PWD}/h2ologs"

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
