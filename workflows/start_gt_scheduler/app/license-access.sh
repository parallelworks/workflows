#!/bin/bash
# install: authorizes the controller's key on the license server, and in the user
#          workspace its tunnel jumps through, then holds its job open so that the
#          key stays in place for as long as the run does
# remove:  the cleanup of that job; takes the key out of both
mode=$1
set -o pipefail
cd "${PW_PARENT_JOB_DIR:-${PWD}}"
source inputs.sh
source controller.env
source workflows/start_gt_scheduler/app/libs.sh
set -x

license_server="${gt_license_user}@${gt_license_ip}"
license_ssh="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20"

install() {
    # Untraced while it handles the key, which would fill the log
    { set +x; } 2> /dev/null

    # The controller's key may not exist yet right after the cluster starts
    local public_key="" attempt
    for attempt in 1 2 3 4 5; do
        public_key=$(controller_ssh 'cat ~/.ssh/id_rsa.pub')
        [ -n "${public_key}" ] && break
        echo "WARNING: Unable to read the public key of ${controller} (attempt ${attempt}/5). Retrying in 15s..."
        sleep 15
    done
    if [ -z "${public_key}" ]; then
        echo "::error title=Error::Unable to read the public key of ${controller}"
        exit 1
    fi
    echo "Public key of ${controller}: $(ssh-keygen -lf /dev/stdin <<< "${public_key}")"

    local escaped_key
    escaped_key=$(printf '%s' "${public_key}" | sed 's/[&|\\]/\\&/g')
    sed "s|__PUBLIC_KEY__|${escaped_key}|g" "${app_dir}/utils/add_ssh_key.sh" > add_ssh_key.sh
    sed "s|__PUBLIC_KEY__|${escaped_key}|g" "${app_dir}/utils/remove_ssh_key.sh" > remove_ssh_key.sh
    set -x

    bash add_ssh_key.sh

    # The license server occasionally drops connections
    local installed=false
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if ${license_ssh} "${license_server}" < add_ssh_key.sh; then
            installed=true
            break
        fi
        echo "WARNING: Failed to install the public key on the license server (attempt ${attempt}/10). Retrying in 30s..."
        sleep 30
    done
    if [ "${installed}" != "true" ]; then
        echo "::error title=Error::Unable to install the public key of ${controller} on the license server ${license_server}"
        exit 1
    fi

    touch license-access.ready
    sleep inf
}

remove() {
    local confirmed=false
    [ -f license-access.ready ] && confirmed=true
    rm -f license-access.ready
    if ! [ -f remove_ssh_key.sh ]; then
        echo "The controller's key was never installed: nothing to remove"
        exit 0
    fi

    # With another run's scheduler serving on the controller, the key is that run's:
    # this one was refused, or lost its own session before the other started
    if [ "$(controller_script "${app_dir}/controller/session.sh" "'${remote_dir}'")" == "foreign" ]; then
        echo "::notice::Another run's GT scheduler is serving on ${controller}: the controller's key stays on the license server for it"
        exit 0
    fi

    bash remove_ssh_key.sh

    local removed=false attempt
    for attempt in 1 2 3; do
        if ${license_ssh} "${license_server}" < remove_ssh_key.sh; then
            removed=true
            break
        fi
        echo "WARNING: Failed to remove the public key from the license server (attempt ${attempt}/3). Retrying in 15s..."
        sleep 15
    done
    if [ "${removed}" != "true" ] && [ "${confirmed}" == "true" ]; then
        echo "::error title=Error::Unable to remove the public key of ${controller} from the license server ${license_server}: remove it from ~/.ssh/authorized_keys there by hand"
        exit 1
    elif [ "${removed}" != "true" ]; then
        # An install whose connection dropped can have added the key without saying so
        echo "::warning::The public key of ${controller} was not confirmed installed on the license server ${license_server}, which could not be reached to make sure: check ~/.ssh/authorized_keys there"
    fi
}

case "${mode}" in
    install) install ;;
    remove) remove ;;
    *) echo "::error title=Error::usage: license-access.sh install|remove"; exit 1 ;;
esac
