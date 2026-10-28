#!/bin/bash
# Brings the source input (a bucket URI or a cluster path: a USD scene, or a directory
# holding one and maybe a run.py) where the render node can read it, and appends to
# inputs.sh what the start script binds at /scene:
#   scene_dir      the directory (a bucket source is copied into <job dir>/scene)
#   scene_file     the USD file in it, if any (scene.usd*, or the only USD there)
#   scene_script   run.py, when the directory has one: it replaces the example's script
# Runs on the login node (it has pw and the run's key), after inputs.sh is sourced.
set -o pipefail
set -x

f_fail() {
    echo "::error title=Error::$1"
    exit 1
}
f_bucket_copy() {
    # S3 signing and network errors are transient: retry before failing
    local attempt
    for attempt in 1 2 3; do
        pw buckets cp "$@" && return 0
        echo "::warning::Download attempt ${attempt} failed; retrying in 30 s"
        sleep 30
    done
    return 1
}

source="${files_source:-}"
scene_dir=""
scene_file=""
scene_script=""
if [ -z "${source}" ]; then
    echo "::notice::No source: the example runs with its bundled scene"
    exit 0
fi
case "${source}" in
    pw://*|s3://*|gs://*)
        rm -rf scene
        mkdir -p scene
        echo "::group::Source Download"
        case "$(tr '[:upper:]' '[:lower:]' <<< "${source}")" in
            *.usd|*.usda|*.usdc|*.usdz)
                f_bucket_copy "${source}" "scene/$(basename "${source}")" || f_fail "Could not download ${source}"
                scene_file=$(basename "${source}")
                ;;
            *.obj)
                f_bucket_copy "${source}" "scene/$(basename "${source}")" || f_fail "Could not download ${source}"
                scene_file=$(basename "${source}")
                ;;
            *)
                # The trailing slash copies the directory's contents, not the directory
                f_bucket_copy -r "${source%/}/" scene/ || f_fail "Could not download ${source}"
                ;;
        esac
        echo "::endgroup::"
        scene_dir="${PWD}/scene"
        ;;
    /*)
        if [ -f "${source}" ]; then
            scene_dir=$(dirname "${source}")
            scene_file=$(basename "${source}")
        elif [ -d "${source}" ]; then
            scene_dir="${source%/}"
        else
            f_fail "The source ${source} does not exist on $(hostname)"
        fi
        ;;
    *)
        f_fail "The source must be a bucket URI (pw://, s3://, gs://) or an absolute path, got '${source}'"
        ;;
esac

if [ "${fracture_own_mesh}" = true ]; then
    # The mesh to fracture: the file named, or the one OBJ in the directory
    case "$(tr '[:upper:]' '[:lower:]' <<< "${scene_file}")" in
        *.obj) ;;
        "")
            mapfile -t meshes < <(find "${scene_dir}" -maxdepth 1 -type f -iname '*.obj' -printf '%f\n' | sort)
            if [ "${#meshes[@]}" -ne 1 ]; then
                f_fail "The source must hold one OBJ file to fracture; ${source} holds ${#meshes[@]}"
            fi
            scene_file="${meshes[0]}"
            ;;
        *) f_fail "The mesh to fracture must be an OBJ file, got ${scene_file}" ;;
    esac
    echo "::notice::Mesh to fracture: ${scene_dir}/${scene_file}"
    {
        echo "export mesh_dir=\"${scene_dir}\""
        echo "export mesh_file=\"${scene_file}\""
    } >> inputs.sh
    exit 0
fi
if [ -z "${scene_file}" ]; then
    for name in scene.usd scene.usda scene.usdc scene.usdz; do
        if [ -f "${scene_dir}/${name}" ]; then
            scene_file="${name}"
            break
        fi
    done
fi
if [ -z "${scene_file}" ]; then
    mapfile -t candidates < <(find "${scene_dir}" -maxdepth 1 -type f \( -iname '*.usd' -o -iname '*.usda' -o -iname '*.usdc' -o -iname '*.usdz' \) -printf '%f\n' | sort)
    if [ "${#candidates[@]}" -eq 1 ]; then
        scene_file="${candidates[0]}"
    elif [ "${#candidates[@]}" -gt 1 ]; then
        f_fail "The source holds ${#candidates[@]} USD files (${candidates[*]}): name the file itself, or call the scene scene.usd/.usda/.usdc"
    fi
fi
if [ -f "${scene_dir}/run.py" ]; then
    scene_script=run.py
fi
if [ -z "${scene_file}" ] && [ -z "${scene_script}" ] && [ -n "${service_example}" ]; then
    f_fail "The source ${source} holds no USD file (.usd, .usda, .usdc, .usdz) and no run.py"
fi
if [ "${service_example}" = scene ] && [ -z "${scene_file}" ]; then
    f_fail "The 'scene' example needs a USD file in the source; ${source} has none"
fi
echo "::notice::Source: ${scene_dir}${scene_file:+, scene ${scene_file}}${scene_script:+, script ${scene_script}}"
{
    echo "export scene_dir=\"${scene_dir}\""
    echo "export scene_file=\"${scene_file}\""
    echo "export scene_script=\"${scene_script}\""
} >> inputs.sh
