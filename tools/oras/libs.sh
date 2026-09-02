

download_oras(){
    if [ -x "${service_parent_install_dir}/tools/oras/oras" ]; then
        return
    fi
    VER="1.2.0"
    wget --no-check-certificate https://github.com/oras-project/oras/releases/download/v${VER}/oras_${VER}_linux_amd64.tar.gz || \
        { echo "::error title=Error::wget failed to download oras v${VER}"; exit 1; }
    if [ ! -f "oras_${VER}_linux_amd64.tar.gz" ]; then
        echo "::error title=Error::Failed to download oras v${VER}"
        exit 1
    fi
    mkdir -p ${service_parent_install_dir}/tools/oras
    tar -xvf oras_${VER}_linux_amd64.tar.gz -C ${service_parent_install_dir}/tools/oras
    chmod -R a+rX ${service_parent_install_dir}/tools/oras
    rm oras_${VER}_linux_amd64.tar.gz
}

oras_pull_file(){
    repo=$1
    repo_path=$2
    host_path=$3
    local output_dir oras_bin anon_config
    output_dir=$(dirname ${host_path})
    oras_bin=${PW_PARENT_JOB_DIR}/tools/oras/oras
    # Pull anonymously first: the packages are public by contract, and a stale
    # ghcr login left in ~/.docker/config.json makes the registry answer
    # "denied" for a package anonymous access serves fine. The stored
    # credentials remain the fallback for the rare private package.
    anon_config=$(mktemp)
    echo '{}' > "${anon_config}"
    # ghcr.io intermittently answers "toomanyrequests" to anonymous pulls;
    # a short retry rides out the rate limit instead of failing the workflow
    local attempt
    for attempt in 1 2 3; do
        if ${oras_bin} pull --registry-config "${anon_config}" ${repo} -o ${output_dir} \
           || ${oras_bin} pull ${repo} -o ${output_dir}; then
            rm -f "${anon_config}"
            return 0
        fi
        [ "${attempt}" -lt 3 ] && sleep $((attempt * 5))
    done
    rm -f "${anon_config}"
    echo "::error title=Error::oras pull failed for ${repo} after ${attempt} attempts"
    exit 1
}
