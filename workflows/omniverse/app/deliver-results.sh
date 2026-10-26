#!/bin/bash
# deliver-results.sh <output dir> <destination> <subdirectory>
# Copies the outputs to <destination>/<subdirectory>/: a bucket (pw://, s3://, gs://)
# through pw buckets cp, or a directory on the cluster. Runs on the node that produced
# them; the local copy stays where it is.
set -o pipefail
set -x
output_dir="$1"
destination="${2%/}"
target="${destination}/$3"
case "${destination}" in
    pw://*|s3://*|gs://*)
        for attempt in 1 2 3; do
            # The trailing slash copies the directory's contents into the target
            if pw buckets cp -r "${output_dir%/}/" "${target}/"; then
                echo "::notice::Outputs copied to ${target}/"
                exit 0
            fi
            echo "::warning::Upload attempt ${attempt} failed; retrying in 30 s"
            sleep 30
        done
        echo "::error title=Error::Could not upload ${output_dir} to ${target}"
        exit 1
        ;;
    /*)
        if mkdir -p "${target}" && cp -a "${output_dir%/}/." "${target}/"; then
            echo "::notice::Outputs copied to ${target}/"
            exit 0
        fi
        echo "::error title=Error::Could not copy ${output_dir} to ${target}"
        exit 1
        ;;
    *)
        echo "::error title=Error::The destination must be a bucket URI or an absolute path, got '${destination}'"
        exit 1
        ;;
esac
