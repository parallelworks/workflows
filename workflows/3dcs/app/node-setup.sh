# Runs on the compute node before 3DCS. Assembled after dcs_environment/<version>.sh by
# yamls/general.yaml; the worker and merge templates call ensure_wine_runs.

ensure_wine_runs() {
    # wine 8.0.2 is a 32-bit binary that needs the 32-bit loader (glibc.i686), which the cluster's
    # user bootstrap installs at node start. When that failed (a broken dnf repository is enough
    # to abort it) the shell reports the binary itself as missing: install the loader here.
    if ! wine --version > /dev/null 2>&1; then
        echo "$(date) INFO: wine cannot run on $(hostname); installing glibc.i686"
        sudo -n timeout 900 dnf install -y --setopt='*.skip_if_unavailable=true' glibc.i686
    fi
    if ! wine --version; then
        echo "$(date) ERROR: wine cannot run on $(hostname): $(command -v wine || echo 'wine not in PATH'); check the node bootstrap log ~/user_bootstrap.log" >&2
        return 1
    fi
}
