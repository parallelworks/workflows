#!/bin/bash
# Picks the builder's manifest and appends manifest_file to inputs.sh: the form's text
# (written to manifest-form.yaml by the YAML) wins; else the source's manifest.yaml;
# else the bundled example's. Runs in the job directory on the login node after
# inputs.sh is sourced (scene_dir from app/fetch-source.sh).
sed -i '/^\s*undefined\s*$/d' manifest-form.yaml
if grep -q '[^[:space:]]' manifest-form.yaml; then
    manifest_file="${PWD}/manifest-form.yaml"
elif [ -n "${scene_dir}" ] && [ -f "${scene_dir}/manifest.yaml" ]; then
    manifest_file="${scene_dir}/manifest.yaml"
elif [ -n "${scene_dir}" ]; then
    echo "::error title=Error::The source ${scene_dir} has no manifest.yaml and the form's manifest is empty"
    exit 1
else
    manifest_file="${PWD}/workflows/omniverse/app/examples/build/manifest.yaml"
fi
echo "::notice::Manifest: ${manifest_file}"
echo "export manifest_file=\"${manifest_file}\"" >> inputs.sh
