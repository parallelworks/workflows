#!/bin/bash
# Usage: OUTPUTS=<file> create-case.sh        (run from the job directory)
#
# The Create the Case step of every openfoam-naca variant, one script so that
# the YAMLs differ only where the platform does: builds the case's params.in
# from the form and the params file, writes the script the submitter runs in
# the case directory (case.sh, which runs simulator.sh and records its exit
# status) and publishes CASE_DIR. Runs where the workflow checked out the app
# and wrote openfoam-env.sh (and paraview-env.sh): the job directory, whose
# absolute path is baked into case.sh. Environment, the form's values:
#   CASE_DIR          absolute path of the case directory; empty: <job dir>/case
#   PARAMS_FILE       a Dakota-style params file whose lines win over the form's
#   MAX_CAMBER, CAMBER_POSITION, THICKNESS, ANGLE_OF_ATTACK   the design
#   MESH_SCALE, CORES_PER_CASE                                the case settings
#   RESUME, CHECKPOINT_EVERY, KEEP_CHECKPOINTS                the restart group
#   GENERATE_IMAGES   true: case.sh renders the images once the case is solved
#   OUTPUTS           the file the workflow collects KEY=value outputs from
set -o pipefail
set -x
if [ -z "${OUTPUTS}" ]; then
    echo "::error::usage: OUTPUTS=<file> create-case.sh"
    exit 1
fi
app="workflows/openfoam-naca/app"
case_dir="${CASE_DIR}"
case "${case_dir}" in
    ''|undefined) case_dir="${PWD}/case" ;;
esac
mkdir -p "${case_dir}" || exit 1
params_file="${PARAMS_FILE}"
case "${params_file}" in
    ''|undefined) params_file="" ;;
    *)
        if [ ! -f "${params_file}" ]; then
            echo "::error::params_file ${params_file} does not exist"
            exit 1
        fi
        ;;
esac
# the file may only name this runner's design parameters, the ones
# design-parameters.txt publishes: a misspelled name would otherwise be
# dropped silently and the case solved with the form's value
if [ -n "${params_file}" ]; then
    bash tools/utils/check-params.sh "${app}/design-parameters.txt" "${params_file}" || exit 1
fi
# the file's lines win over the form's values of the same name, and the form
# fills in whatever the file does not list (first occurrence wins)
{
    if [ -n "${params_file}" ]; then
        cat "${params_file}"
        echo
    fi
    printf '%s max_camber\n%s camber_position\n%s thickness\n%s angle_of_attack\n' \
        "${MAX_CAMBER}" "${CAMBER_POSITION}" "${THICKNESS}" "${ANGLE_OF_ATTACK}"
} | awk 'NF >= 2 && !seen[$2]++' > "${case_dir}/params.in.tmp" || exit 1
mv "${case_dir}/params.in.tmp" "${case_dir}/params.in" || exit 1
# a stale verdict from an earlier run of the same directory is removed, so a
# missing results.out always means this run's solver failed
rm -f "${case_dir}/results.out" "${case_dir}/exit_code"

resume="${RESUME}"
[ "${resume}" = true ] || resume=false
checkpoint_every="${CHECKPOINT_EVERY}"
keep_checkpoints="${KEEP_CHECKPOINTS}"
case "${checkpoint_every}" in ''|undefined) checkpoint_every=0 ;; esac
case "${keep_checkpoints}" in ''|undefined) keep_checkpoints=2 ;; esac
for v in checkpoint_every keep_checkpoints; do
    if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
        echo "::error::restart.${v} must be a non-negative integer, got '${!v}'"
        exit 1
    fi
done
if [ "${resume}" = true ] && [ "${checkpoint_every}" -eq 0 ]; then
    echo "::warning::resume is on but restart.checkpoint_every is 0: no checkpoints are written, so an interrupted solver starts again from iteration 0"
fi
if [ "${resume}" = true ] && [ -d "${case_dir}/case" ]; then
    echo "::notice::resume is on: the case in ${case_dir}/case is continued when it matches this design and these settings (its attempts so far are in ${case_dir}/attempts.log)"
fi

# the submitter inlines the script body, so the absolute paths are baked in;
# it is not named run.sh because the submitter writes its assembled job
# script under that name in the same directory. The simulator runs in the
# background: the scheduler's walltime SIGTERM reaches this script alone, and
# the trap passes it on at once, so the simulator stops the solver and records
# the interruption (restart.sh). exit_code says the simulator ran to its end,
# and how it ended; a signal (status 128 + n) leaves none, so "no results.out
# and no exit_code" still means killed mid-way to a caller (dakota's optimizer
# re-proposes such a case instead of counting it as failed); attempts.log
# keeps the record
cat > "${case_dir}/case.sh" << PW_CASE_EOF
#!/bin/bash
cd "${case_dir}"
MESH_SCALE="${MESH_SCALE}" CORES_PER_CASE="${CORES_PER_CASE}" \\
  RESUME="${resume}" CHECKPOINT_EVERY="${checkpoint_every}" KEEP_CHECKPOINTS="${keep_checkpoints}" \\
  OPENFOAM_ENV="${PWD}/openfoam-env.sh" \\
  bash "${PWD}/${app}/simulator.sh" &
pid=\$!
trap 'kill -TERM \${pid} 2>/dev/null' TERM
trap 'kill -INT \${pid} 2>/dev/null' INT
trap 'kill -HUP \${pid} 2>/dev/null' HUP
wait \${pid}
rc=\$?
# a trapped signal returns wait at once: wait for the simulator to finish
if [ "\${rc}" -gt 128 ] && kill -0 \${pid} 2>/dev/null; then
  wait \${pid}
  rc=\$?
fi
if [ "\${rc}" -le 128 ]; then
  echo "\${rc}" > exit_code
fi
if [ "\${rc}" -eq 0 ] && [ "${GENERATE_IMAGES}" = "true" ]; then
  PARAVIEW_ENV="${PWD}/paraview-env.sh" \\
    bash "${PWD}/${app}/render-images.sh" case images params.in results.out
fi
exit "\${rc}"
PW_CASE_EOF
echo "--- ${case_dir}/params.in"
cat "${case_dir}/params.in"
echo "CASE_DIR=${case_dir}" | tee -a "${OUTPUTS}"
