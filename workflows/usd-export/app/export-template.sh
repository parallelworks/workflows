
# The export itself, after the variables prepare.sh writes above. Records its own exit
# status, since the submitter does not forward it. The exporter runs in the background
# so a scancel, a walltime or a cancel of the run is recorded too, and the signal is
# passed on to it: SLURM signals this script alone, not its children.
set -o pipefail
set -x
trap 'echo $? > "${exit_file}"' EXIT

source "${env_file}"
python "${export_app}/export_usd.py" \
    --source "${results_source}" \
    --stage-dir "${stage_directory}" \
    --format "${results_format:-openfoam-naca}" \
    --columns "${stage_columns:-4}" \
    --follow-minutes "${results_follow_minutes:-0}" &
exporter=$!
trap 'kill -TERM ${exporter} 2> /dev/null; wait ${exporter}; exit 143' TERM HUP
trap 'kill -TERM ${exporter} 2> /dev/null; wait ${exporter}; exit 130' INT
wait ${exporter}
