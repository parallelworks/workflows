#!/bin/bash
# Resume support for simulator.sh, which sources this file: everything that lets
# an interrupted OpenFOAM case continue where it stopped instead of starting over,
# so that a workflow can resubmit the case until it completes
# (workflows/openfoam-naca-restart). The case directory is the cwd and the
# OpenFOAM case is ./case; the state is plain files, readable by hand:
#
#   attempts.log                 the history: one start and one end line per attempt
#   attempt.lock                 held by the running attempt's process tree (flock)
#   case/restart/inputs          the design and the settings the case was built
#                                from: a case is only resumed when they match
#   case/restart/<stage>.done    the stages finished (blockMesh, decomposePar,
#                                potentialFoam, simpleFoam), each with the attempt
#                                that finished it: a finished stage is skipped
#   case/restart/failed          the stage that failed on its own (a diverged
#                                solver): the case is never solved again
#   case/restart/solver.attempt  the attempt that ran simpleFoam last; its log is
#                                kept as case/log.simpleFoam.<attempt> when the
#                                next one starts
#
# A checkpoint is a time directory simpleFoam wrote (every CHECKPOINT_EVERY
# iterations, the last KEEP_CHECKPOINTS kept). It is complete when every field of
# 0/ is in it ending with OpenFOAM's closing line, in every processor directory of
# a decomposed case: a write cut short by a kill is discarded, and the solver
# restarts from the one before. An interruption is a signal (the scheduler's
# walltime, the platform canceling the attempt) or a lost node: the signal is
# trapped, passed on to the running tool and recorded with the attempt's exit
# status 128 + signal; a lost node leaves no record, which the next attempt notes.
# A tool that stops on its own with a non-zero status failed: that is recorded as
# final and no later attempt solves the case again.

RESTART_DIR=case/restart
ATTEMPTS_LOG=attempts.log
ATTEMPT_LOCK=attempt.lock

restart_log() {
    printf '%s  attempt %s  %-5s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" | tee -a "${ATTEMPTS_LOG}"
}

stage_done() { [ -f "${RESTART_DIR}/$1.done" ]; }
stage_mark() { echo "attempt ${ATTEMPT}" > "${RESTART_DIR}/$1.done"; }
stage_by() { cat "${RESTART_DIR}/$1.done" 2>/dev/null; }

# the iterations the solver wrote (the top-level time directories, or processor0's)
restart_times() {
    local dir=case
    [ -d case/processor0 ] && dir=case/processor0
    ls "${dir}" 2>/dev/null | grep -E '^[0-9]+([.][0-9]+)?$' | grep -vx 0 | sort -g | tr '\n' ' '
}

restart_iteration() {
    if [ -f case/log.simpleFoam ]; then
        awk '/^Time = / {t = $3} END {print t + 0}' case/log.simpleFoam
    else
        echo 0
    fi
}

# where the case stands, for the log lines
restart_where() {
    local done="" s
    for s in blockMesh decomposePar potentialFoam simpleFoam; do
        stage_done "${s}" && done="${done:+${done}, }${s}"
    done
    echo "done: ${done:-nothing}; solver log at iteration $(restart_iteration); checkpoints: $(restart_times)"
}

# Opens the attempt: takes the case lock, decides between continuing ./case and
# starting over, and writes the start line. $1 is the inputs text, one
# "<name> <value>" line per design parameter and setting that decides the
# solution. Sets ATTEMPT and RESUMED (1 when the case is kept); exits 1 when the
# case failed on an earlier attempt.
restart_begin() {
    local inputs="$1" how
    # two attempts must never work on one case at once (the previous one may still
    # be dying when the next is submitted): the lock belongs to this process tree,
    # the solver included, and goes away with it, even killed outright
    if command -v flock > /dev/null; then
        exec 9> "${ATTEMPT_LOCK}"
        if ! flock -w 120 9; then
            echo "another attempt still holds ${PWD}/${ATTEMPT_LOCK} after 120 s; giving up"
            exit 1
        fi
    else
        echo "::warning::flock not found: concurrent attempts on ${PWD} are not prevented"
    fi
    ATTEMPT=$(( $(awk '$2 == "attempt" && $4 == "start" {n = $3} END {print n + 0}' "${ATTEMPTS_LOG}" 2>/dev/null) + 1 ))
    export ATTEMPT
    if [ "${ATTEMPT}" -gt 1 ] && ! awk -v n="$((ATTEMPT - 1))" '$2 == "attempt" && $3 == n && $4 == "end" {f = 1} END {exit !f}' "${ATTEMPTS_LOG}"; then
        restart_log "$((ATTEMPT - 1))" end "interrupted without a record (killed outright or node lost); $(restart_where)"
    fi
    RESUMED=0
    if [ "${RESUME}" != true ]; then
        how="from scratch: resume off"
    elif [ ! -d case ]; then
        how="from scratch: no case yet"
    elif [ ! -f "${RESTART_DIR}/inputs" ]; then
        how="from scratch: case/ has no restart state"
    elif ! printf '%s\n' "${inputs}" | cmp -s - "${RESTART_DIR}/inputs"; then
        how="from scratch: the inputs changed ($(printf '%s\n' "${inputs}" | diff "${RESTART_DIR}/inputs" - | grep '^[<>]' | tr '\n' ' '))"
    elif [ -f "${RESTART_DIR}/failed" ]; then
        restart_log "${ATTEMPT}" start "refused: $(cat "${RESTART_DIR}/failed")"
        restart_log "${ATTEMPT}" end "not run: a case that failed on its own is not solved again (change the inputs or remove ${PWD}/case to start over)"
        exit 1
    else
        RESUMED=1
        how="resume; $(restart_where)"
    fi
    [ "${RESUMED}" = 1 ] || rm -rf case
    restart_log "${ATTEMPT}" start "${how}"
    mkdir -p "${RESTART_DIR}"
    printf '%s\n' "${inputs}" > "${RESTART_DIR}/inputs"
}

# Prints the latest complete checkpoint, 0 when there is none, after discarding
# the incomplete ones and all but the last KEEP_CHECKPOINTS: where simpleFoam
# restarts from (startFrom latestTime). Complete: every field of 0/ is there,
# and every file there (phi included, which the solver reads back when present)
# ends with OpenFOAM's closing line. Messages go to stderr.
restart_checkpoints() {
    local dirs=(case) d t f fields ok complete=()
    [ -d case/processor0 ] && dirs=(case/processor[0-9]*)
    fields=$(ls -p "${dirs[0]}/0" | grep -v '/$')
    for t in $(restart_times); do
        ok=1
        for d in "${dirs[@]}"; do
            for f in ${fields}; do
                if [ ! -f "${d}/${t}/${f}" ]; then
                    ok=0
                    break 2
                fi
            done
            for f in $(ls -p "${d}/${t}" | grep -v '/$'); do
                if ! tail -n 1 "${d}/${t}/${f}" | grep -q '^// \*'; then
                    ok=0
                    break 2
                fi
            done
        done
        if [ "${ok}" = 1 ]; then
            complete+=("${t}")
        else
            echo "checkpoint ${t} is incomplete (${d}/${t}/${f} was cut short): discarded" >&2
            for d in "${dirs[@]}"; do rm -rf "${d}/${t}"; done
        fi
    done
    while [ "${#complete[@]}" -gt "${KEEP_CHECKPOINTS}" ]; do
        t="${complete[0]}"
        complete=("${complete[@]:1}")
        for d in "${dirs[@]}"; do rm -rf "${d}/${t}"; done
        echo "checkpoint ${t} removed: the last ${KEEP_CHECKPOINTS} are kept" >&2
    done
    if [ "${#complete[@]}" -gt 0 ]; then echo "${complete[-1]}"; else echo 0; fi
}

# The signal is remembered and passed on to the running tool's whole process tree
# (mpirun, its proxies and ranks, the log filters). The scheduler's walltime
# SIGTERM reaches the batch script alone, which forwards it here; bash runs the
# handler at once while it waits on a background job.
INTERRUPTED=""
TOOL_PID=""
restart_descendants() {
    local c
    for c in $(pgrep -P "$1"); do
        restart_descendants "${c}"
        echo "${c}"
    done
}
restart_on_signal() {
    [ -n "${INTERRUPTED}" ] && return
    INTERRUPTED="$1"
    if [ -n "${TOOL_PID}" ]; then
        kill "-${1}" $(restart_descendants "${TOOL_PID}") "${TOOL_PID}" 2>/dev/null
    fi
}
trap 'restart_on_signal TERM' TERM
trap 'restart_on_signal INT' INT
trap 'restart_on_signal HUP' HUP

# Runs a tool in the background and waits, so a signal is handled while it runs
# instead of once it ends; returns the tool's status, 143 without running it when
# a signal already came.
run_interruptible() {
    local rc
    [ -z "${INTERRUPTED}" ] || return 143
    "$@" &
    TOOL_PID=$!
    wait "${TOOL_PID}"
    rc=$?
    # a trapped signal returns wait at once while the tool is still dying
    if [ -n "${INTERRUPTED}" ] && kill -0 "${TOOL_PID}" 2>/dev/null; then
        wait "${TOOL_PID}"
        rc=$?
    fi
    TOOL_PID=""
    return "${rc}"
}

# Ends the attempt after a stage ($1) returned a non-zero status ($2). An
# interruption is recorded and the attempt exits 128 + signal, so the next
# attempt carries on from the case's state; anything else is the case failing
# on its own, recorded as final so that no attempt solves it again (the caller
# then prints the log tails and exits 1).
restart_failed() {
    local stage="$1" rc="$2" reason
    if [ -n "${INTERRUPTED}" ]; then
        restart_log "${ATTEMPT}" end "interrupted (SIG${INTERRUPTED}) in ${stage}; solver log at iteration $(restart_iteration); checkpoints: $(restart_times)"
        exit $(( 128 + $(kill -l "${INTERRUPTED}") ))
    fi
    # every OpenFOAM log opens with a "trapFpe: Floating point exception trapping
    # enabled" banner: not the crash
    reason=$(grep -E 'FOAM FATAL|sigFpe|Floating point exception' "case/log.${stage}" 2>/dev/null | grep -v trapFpe | head -n 1 | sed 's/ in [^ ]*lib[^ ]*$//' | head -c 120)
    case "${stage}" in
        simpleFoam|potentialFoam) [ -z "${reason}" ] || reason="diverged: ${reason}" ;;
    esac
    reason="exit status ${rc}${reason:+, ${reason}}"
    echo "${stage} failed on attempt ${ATTEMPT} (${reason})" > "${RESTART_DIR}/failed"
    restart_log "${ATTEMPT}" end "failed: ${stage} stopped on its own (${reason}); not an interruption, so no later attempt solves this case"
}
