set -o pipefail

################################################################################
# Interactive Session Controller - H2O-3
#
# Purpose: Download an H2O-3 release and make sure a Java runtime is available
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_download_url: H2O-3 release zip (https://h2o-release.s3.amazonaws.com/h2o/...)
#   - service_load_env: Command that puts java on the PATH (optional, e.g. module load java)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p "${service_parent_install_dir}"

service_zip_basename=$(basename "${service_download_url}")
service_install_dir=${service_parent_install_dir}/$(basename "${service_zip_basename}" .zip)
service_jar=${service_install_dir}/h2o.jar
service_jre_dir=${service_parent_install_dir}/h2o-jre
# Latest Temurin 17 JRE (an LTS release H2O-3 supports); the API redirects to the tarball
service_jre_url=${service_jre_url:-https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jre/hotspot/normal/eclipse}

f_fail() {
    echo "::error title=Error::$1"
    exit 1
}

f_unzip() {
    if command -v unzip > /dev/null 2>&1; then
        unzip -q "$1" -d "$2"
    else
        python3 -m zipfile -e "$1" "$2"
    fi
}

f_install_h2o() {
    local zip=${service_parent_install_dir}/${service_zip_basename} tmp jar
    echo "::notice::Downloading ${service_download_url}"
    if ! wget --timeout=120 --tries=3 -nv -O "${zip}" "${service_download_url}"; then
        rm -f "${zip}"
        f_fail "Could not download ${service_download_url}"
    fi
    tmp=$(mktemp -d "${service_parent_install_dir}/.h2o-unzip-XXXXXX")
    if ! f_unzip "${zip}" "${tmp}"; then
        rm -rf "${tmp}" "${zip}"
        f_fail "Could not unzip ${zip}"
    fi
    jar=$(find "${tmp}" -name h2o.jar | head -1)
    if [ -z "${jar}" ]; then
        rm -rf "${tmp}" "${zip}"
        f_fail "${service_zip_basename} does not contain h2o.jar"
    fi
    rm -rf "${service_install_dir}"
    mv "$(dirname "${jar}")" "${service_install_dir}"
    rm -rf "${tmp}" "${zip}"
}

f_install_jre() {
    local tgz=${service_parent_install_dir}/h2o-jre.tar.gz tmp
    echo "::notice::Downloading a Temurin 17 JRE from ${service_jre_url}"
    if ! wget --timeout=120 --tries=3 -nv -O "${tgz}" "${service_jre_url}"; then
        rm -f "${tgz}"
        f_fail "Could not download a Java runtime; set the command that loads Java in the form (e.g. module load java)"
    fi
    tmp=$(mktemp -d "${service_parent_install_dir}/.h2o-jre-XXXXXX")
    if ! tar -xzf "${tgz}" -C "${tmp}"; then
        rm -rf "${tmp}" "${tgz}"
        f_fail "Could not unpack the Java runtime"
    fi
    rm -rf "${service_jre_dir}"
    mv "${tmp}"/* "${service_jre_dir}"
    rm -rf "${tmp}" "${tgz}"
}

echo "::group::H2O Installation"
if [ -f "${service_jar}" ]; then
    echo "::notice::H2O already installed: ${service_jar}"
else
    f_install_h2o
fi
[ -f "${service_jar}" ] || f_fail "Missing ${service_jar}"
echo "::endgroup::"

echo "::group::Java Runtime"
eval "${service_load_env}"
if ! command -v java > /dev/null 2>&1; then
    if [ -x "${service_jre_dir}/bin/java" ]; then
        echo "::notice::Using the Java runtime in ${service_jre_dir}"
    else
        echo "::notice::No java on the PATH; installing a Java runtime into ${service_jre_dir}"
        f_install_jre
    fi
    export PATH=${service_jre_dir}/bin:${PATH}
fi
command -v java > /dev/null 2>&1 || f_fail "java command not found"
echo "::notice::Using $(command -v java): $(java -version 2>&1 | head -1)"
echo "::endgroup::"
