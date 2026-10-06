# The body of benchmark.sh, the script the submitter runs on the compute node
# (or the login node). inputs.sh precedes it in that file, so the form's values,
# the PW_* variables, benchmark_bin_dir and benchmark_mpi_env are set. The
# submitter cds into the run's job directory first and streams this script's
# output to the run log. It never forwards the exit status, so the status goes
# to benchmark.exit for the results job; the raw benchmark output goes to
# results/<benchmark>.out for summarize.py.
set -o pipefail
job_dir="${PWD}"
io_root=""
io_run_dir=""
f_exit() {
    local rc=$?
    echo "${rc}" > "${job_dir}/benchmark.exit"
    if [ -n "${io_run_dir}" ]; then
        rm -rf "${io_run_dir}"
        if [ "${io_root}" = "${job_dir}/io" ]; then
            rmdir "${io_root}" 2> /dev/null || true
        fi
    fi
}
trap f_exit EXIT
# scancel and qdel send SIGTERM; without these traps bash runs the exit trap with
# the status of the last command completed before the benchmark, which is 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
set -e

source "${benchmark_mpi_env}"

# the rank layout comes from the allocation, on the login node from the form
if [ -n "${SLURM_JOB_ID:-}" ]; then
    nodes="${SLURM_JOB_NUM_NODES}"
    np="${SLURM_NTASKS:-$(( SLURM_JOB_NUM_NODES * ${SLURM_NTASKS_PER_NODE:-${benchmark_ntasks_per_node}} ))}"
elif [ -n "${PBS_NODEFILE:-}" ]; then
    nodes=$(sort -u "${PBS_NODEFILE}" | wc -l)
    np=$(wc -l < "${PBS_NODEFILE}")
else
    nodes=1
    np="${benchmark_ntasks_per_node}"
fi
ppn=$(( np / nodes ))

mpi_version="$(mpirun --version 2>&1 | head -n 1)"
if [ -n "${MPIRUN:-}" ]; then
    # the environment commands may replace the launcher (export MPIRUN="srun --mpi=pmix")
    read -r -a launcher <<< "${MPIRUN}"
else
    launcher=(mpirun -np "${np}")
    # Open MPI reads a SLURM allocation itself; a PBS one only when built with PBS
    # support, so the node file is handed over as a hostfile (a subset of the
    # allocation is accepted when it did detect it)
    if [ -n "${PBS_NODEFILE:-}" ] && [[ "${mpi_version}" == *"Open MPI"* ]]; then
        launcher+=(--hostfile "${PBS_NODEFILE}")
    fi
fi

# IOR and mdtest work in a directory per run on the file system under test; the
# exit trap removes it, and so does cancel.sh, which the submitter runs on the node
# when the run is cancelled (the job may be killed before the trap can run)
case "${benchmark}" in
    ior|mdtest)
        io_root="${benchmark_io_dir:-${job_dir}/io}"
        io_run_dir="${io_root%/}/${PW_RUN_SLUG}"
        mkdir -p "${io_run_dir}"
        ;;
esac
{
    echo '#!/bin/bash'
    if [ -n "${io_run_dir}" ]; then
        echo "rm -rf \"${io_run_dir}\""
        if [ "${io_root}" = "${job_dir}/io" ]; then
            echo "rmdir \"${io_root}\" 2> /dev/null || true"
        fi
    fi
} > "${job_dir}/cancel.sh"
chmod +x "${job_dir}/cancel.sh"

mkdir -p "${job_dir}/results"
out="${job_dir}/results/${benchmark}.out"
rm -f "${out}"
case "${benchmark}" in
    imb-pingpong|imb-alltoall)
        # -map <ppn>x<nodes> numbers the ranks so that 0 and <ppn> sit on different
        # nodes: PingPong then measures the interconnect, not the node (IMB user guide)
        imb_args=()
        if [ "${nodes}" -gt 1 ]; then
            imb_args+=(-map "${ppn}x${nodes}")
        fi
        read -r -a extra <<< "${benchmark_imb_args:-}"
        cmd=("${launcher[@]}" "${benchmark_bin_dir}/IMB-MPI1" "${imb_args[@]}" "${extra[@]}" "${benchmark#imb-}")
        ;;
    ior)
        case "${benchmark_preset}" in
            minimal)  args="-w -r -i 1 -t 1m -b 16m -s 16 -F -C -e" ;;
            standard) args="-w -r -i 3 -t 64m -b 64m -s 16 -F -C -e" ;;
            custom)   args="${benchmark_ior_args:-}" ;;
            *) echo "unknown preset '${benchmark_preset}'"; exit 1 ;;
        esac
        read -r -a extra <<< "${args}"
        cmd=("${launcher[@]}" "${benchmark_bin_dir}/ior" "${extra[@]}" -o "${io_run_dir}/ior.testfile")
        ;;
    mdtest)
        case "${benchmark_preset}" in
            minimal)  args="-n 20840 -i 1 -u" ;;
            standard) args="-n 20840 -e 4096 -w 4096 -i 3 -u" ;;
            custom)   args="${benchmark_mdtest_args:-}" ;;
            *) echo "unknown preset '${benchmark_preset}'"; exit 1 ;;
        esac
        read -r -a extra <<< "${args}"
        cmd=("${launcher[@]}" "${benchmark_bin_dir}/mdtest" "${extra[@]}" -d "${io_run_dir}")
        ;;
    *)
        echo "unknown benchmark '${benchmark}'"
        exit 1
        ;;
esac

echo "Benchmark     : ${benchmark}${benchmark_preset:+ (${benchmark_preset})}"
echo "Host          : $(hostname)${SLURM_JOB_NODELIST:+, SLURM job ${SLURM_JOB_ID} on ${SLURM_JOB_NODELIST}}${PBS_JOBID:+, PBS job ${PBS_JOBID}}"
echo "MPI           : ${mpi_version}"
echo "Ranks         : ${np} on ${nodes} node(s), ${ppn} per node"
if [ -n "${io_run_dir}" ]; then
    echo "I/O directory : ${io_run_dir}"
fi
echo "Command       : ${cmd[*]}"
echo "Started       : $(date)"
echo
"${cmd[@]}" 2>&1 | tee "${out}"
echo
echo "Finished      : $(date)"
