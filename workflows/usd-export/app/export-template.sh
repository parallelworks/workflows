
# The export itself, after the variables prepare.sh writes above. Records its own exit
# status, since the submitter does not forward it; the exporter runs in the background
# so a scancel or a cancel of the run is recorded too.
set -o pipefail
set -x
trap 'echo $? > "${exit_file}"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

source "${env_file}"
python "${export_app}/export_usd.py" \
    --source "${results_source}" \
    --stage-dir "${stage_directory}" \
    --columns "${stage_columns:-4}" \
    --follow-minutes "${results_follow_minutes:-0}" &
wait $!
