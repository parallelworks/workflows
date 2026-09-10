set -o pipefail
set -x

source tools/oras/libs.sh

container_mode=${container_mode:-sif_path}
finetune_registry=${finetune_registry:-ghcr.io/parallelworks/finetune:latest}
# Cache the SIF in a registry-derived directory so changing the registry input
# cannot silently reuse an image downloaded from another reference
registry_slug=$(printf '%s' "${finetune_registry}" | tr -c 'a-zA-Z0-9._-' '_')

service_parent_install_dir=${service_parent_install_dir/#\~/$HOME}
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
        #
        # The pin set is part of the cache key: an image built from
        # requirements-tf5.txt is a different artifact from the default 4.x
        # one, and reusing the wrong one is exactly the silent failure this
        # mode should not produce (4.x + gemma-4 = KeyError 'gemma4';
        # 5.x + a MoE profile = the memory regression).
        requirements_file=${container_requirements_file:-requirements.txt}
        req_slug=$(printf '%s' "${requirements_file}" | tr -c 'a-zA-Z0-9._-' '_')
        container_sif=${service_parent_install_dir}/containers/${registry_slug}/finetune-${req_slug}.sif
        if ! [ -f "${container_sif}" ]; then
            echo "::group::Building finetune.sif on-the-fly (pins: ${requirements_file})"
            bash ${PW_PARENT_JOB_DIR}/workflows/finetuning/app/build-container.sh \
                "${container_sif}" "" "${requirements_file}"
            echo "::endgroup::"
        fi
        ;;
    *)
        echo "::error title=Error::unknown container_mode ${container_mode}"
        exit 1
        ;;
esac

# Resolve base_model_id to the flat cache directory the (parallel, no needs
# edge to this job) prepare_model job downloads into -- same formula as that
# job's TARGET_DIR (yamls/general.yaml). Re-exported into ./inputs.sh so
# preprocessing's "Create Service Script" step (which runs after this one,
# in the same job) picks up the resolved directory instead of the bare HF ID:
# start-template.sh/train-entrypoint.sh/train.py all consume base_model_id as
# whatever this exports last. model_source=local is left untouched -- it is
# already a real path.
if [ "${model_source}" = "huggingface" ]; then
    resolved_model_cache_dir="${model_cache_dir/#\~/$HOME}"
    base_model_id="${resolved_model_cache_dir}/${base_model_id##*/}"
    echo "export base_model_id=\"${base_model_id}\"" >> ./inputs.sh
fi
