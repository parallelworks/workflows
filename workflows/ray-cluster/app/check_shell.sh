#!/bin/sh
# check_shell.sh — Verify bash is available and warn on csh/tcsh login shells.
#
# Written in POSIX sh (no bashisms) so it can run before we know anything
# about the invoking environment. Exits non-zero only if /bin/bash is missing,
# which would mean the rest of the workflow cannot run.

bash_path=""
if [ -x /bin/bash ]; then
    bash_path=/bin/bash
elif command -v bash >/dev/null 2>&1; then
    bash_path=$(command -v bash)
fi

if [ -z "${bash_path}" ]; then
    echo "[check_shell] ERROR: bash not found on PATH or at /bin/bash." >&2
    echo "[check_shell] The Ray cluster workflow requires bash on every node." >&2
    exit 1
fi

echo "[check_shell] bash found at: ${bash_path}"
echo "[check_shell] bash version: $(${bash_path} --version | head -1)"

login_shell="${SHELL:-unknown}"
case "${login_shell}" in
    */tcsh|*/csh)
        echo "[check_shell] NOTE: login shell is ${login_shell} (csh family)."
        echo "[check_shell] The workflow invokes scripts with an explicit bash shebang"
        echo "[check_shell] and 'ssh ... bash -s', so csh/tcsh login shells are supported."
        echo "[check_shell] However, sourcing the Python venv manually from tcsh will fail"
        echo "[check_shell] (activate uses 'export'). Use 'source venv/bin/activate.csh' or"
        echo "[check_shell] invoke via 'bash -c' if you need the venv in an interactive shell."
        ;;
    *)
        echo "[check_shell] login shell: ${login_shell}"
        ;;
esac

exit 0
