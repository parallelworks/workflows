#!/bin/bash
# Writes launch-gui.sh, the desktop's startup command (app/gui-launcher.sh with the
# SIF, the cache directory and the application filled in), publishes its path as
# LAUNCHER and the core and GPU requests. Runs in the job directory on the login node
# after inputs.sh is sourced: desktop_app, software_sif, software_sif_registry,
# service_parent_install_dir.
set -eo pipefail
app=workflows/omniverse/app
case "${desktop_app}" in
    isaac-sim|isaac-sim.newton) ;;
    *)
        echo "::error title=Error::Unknown application '${desktop_app}': isaac-sim or isaac-sim.newton"
        exit 1
        ;;
esac
install_dir="${service_parent_install_dir:-${HOME}/pw/software}"
{
    echo '#!/bin/bash'
    echo "container_sif=\"${software_sif:-${install_dir}/omniverse/containers/isaac-sim-${software_sif_registry##*:}.sif}\""
    echo "cache_dir=\"${install_dir}/omniverse/cache\""
    echo "gui_app=\"${desktop_app}\""
    cat "${app}/gui-launcher.sh"
} > launch-gui.sh
chmod +x launch-gui.sh
echo "LAUNCHER=${PWD}/launch-gui.sh" | tee -a "${OUTPUTS}"
bash "${app}/scheduler-directives.sh"
