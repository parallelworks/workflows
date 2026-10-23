#!/bin/bash
# Fractures the source mesh (mesh_dir/mesh_file, an OBJ, from app/fetch-source.sh) with
# the Blast SDK tools app/install-blast.sh built, into fracture/scene.usda in the job
# directory, and points scene_dir and scene_file at it, so the fracture example opens
# it like the bundled wall. Reads fracture_cells, fracture_seed, fracture_strength and
# service_parent_install_dir. Runs on the login node after inputs.sh is sourced.
set -eo pipefail
tools="${service_parent_install_dir:-${HOME}/pw/software}/omniverse/blast"
app="${PW_PARENT_JOB_DIR}/workflows/omniverse/app"
if ! [ -x "${tools}/blast-fracture" ] || ! [ -x "${tools}/usd/bin/python" ]; then
    echo "::error title=Error::The Blast SDK tools are not in ${tools}; the controller builds them when the fracture box is on"
    exit 1
fi
if [ -z "${mesh_dir}" ] || ! [ -f "${mesh_dir}/${mesh_file}" ]; then
    echo "::error title=Error::No mesh to fracture (mesh_dir=${mesh_dir}, mesh_file=${mesh_file})"
    exit 1
fi
rm -rf fracture
mkdir -p fracture
echo "::group::Fracture"
"${tools}/blast-fracture" --out fracture/chunks.obj --cells "${fracture_cells:-24}" --seed "${fracture_seed:-7}" --obj "${mesh_dir}/${mesh_file}"
"${tools}/usd/bin/python" "${app}/fracture/make-scene.py" fracture/chunks.obj fracture/scene.usda --strength "${fracture_strength:-150000}" --ball auto
echo "::endgroup::"
{
    echo "export scene_dir=\"${PWD}/fracture\""
    echo "export scene_file=\"scene.usda\""
    echo "export scene_script=\"\""
} >> inputs.sh
echo "::notice::Fractured ${mesh_file} into ${PWD}/fracture/scene.usda"
