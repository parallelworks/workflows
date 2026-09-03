set -o pipefail
set -x

source tools/oras/libs.sh

container_mode=${container_mode:-sif_path}
finetune_registry=${finetune_registry:-ghcr.io/parallelworks/finetune:latest}
# Cache the SIF in a registry-derived directory so changing the registry input
# cannot silently reuse an image downloaded from another reference
registry_slug=$(printf '%s' "${finetune_registry}" | tr -c 'a-zA-Z0-9._-' '_')

mkdir -p "${service_parent_install_dir}" || true
if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/${registry_slug}/finetune.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers/${registry_slug} ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/containers/${registry_slug} ${service_parent_install_dir}/tools

container_sif=${service_parent_install_dir}/containers/${registry_slug}/finetune.sif

case "${container_mode}" in
    registry)
        # Download only when not already present (idempotent)
        if ! [ -f "${container_sif}" ]; then
            echo "::group::Finetune SIF Download"
            echo "::notice::Downloading finetune.sif from ${finetune_registry}"
            oras_pull_file ${finetune_registry} finetune.sif ${container_sif}
            if [ ! -s ${container_sif} ]; then
                echo "::error title=Error::Failed to download file ${container_sif}. The registry artifact must contain a file named finetune.sif."
                exit 1
            fi
            chmod a+r ${container_sif}
            echo "::endgroup::"
        fi
        ;;
    sif_path)
        # Validation only; start-template.sh reads container_sif_path directly.
        resolved_sif_path=${container_sif_path/#\~/$HOME}
        if ! [ -f "${resolved_sif_path}" ]; then
            echo "::error title=Error::.sif not found at ${resolved_sif_path}"
            exit 1
        fi
        ;;
    build)
        # Build only when not already cached under this registry_slug's path
        # (a maintainer-run build for the same target lands in the same spot,
        # so a later switch to registry/sif_path mode never silently reuses a
        # stale local build under a mismatched key).
        if ! [ -f "${container_sif}" ]; then
            echo "::group::Building finetune.sif on-the-fly"
            bash ${PW_PARENT_JOB_DIR}/workflows/finetuning/app/build-container.sh "${container_sif}"
            echo "::endgroup::"
        fi
        ;;
    *)
        echo "::error title=Error::unknown container_mode ${container_mode}"
        exit 1
        ;;
esac
