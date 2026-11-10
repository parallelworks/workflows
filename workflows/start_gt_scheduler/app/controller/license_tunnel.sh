#!/bin/bash
# The license server's firewall only admits the user workspace, so the tunnel jumps
# through it. The last command's status is the script's: non-zero when neither port
# is listening, which is what the callers retry on.
source "$(dirname "$0")/inputs.sh"
set -x

access_ok=false
for attempt in 1 2 3 4 5; do
    if ssh -q -o BatchMode=yes -o ConnectTimeout=10 -J usercontainer ${resource_ssh_usercontainer_options} ${gt_license_user}@${gt_license_ip} exit; then
        access_ok=true
        break
    fi
    echo "WARNING: No SSH access to the license server yet (attempt ${attempt}/5). Retrying in 30s..."
    sleep 30
done

if [ "${access_ok}" != "true" ]; then
    echo; echo
    echo "ERROR: Controller has no SSH access to the license server."
    echo "       ssh -J usercontainer ${resource_ssh_usercontainer_options} ${gt_license_user}@${gt_license_ip}"
    exit 1
fi

echo "Creating the license tunnel"
ssh -J usercontainer \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=5 \
    -o ConnectTimeout=10 \
    -o ExitOnForwardFailure=yes \
    -o TCPKeepAlive=yes \
    -o ConnectionAttempts=5 \
    -fN \
    -L 0.0.0.0:${gt_license_port}:localhost:${gt_license_port} \
    -L 0.0.0.0:${gt_license_vendor_port}:localhost:${gt_license_vendor_port} \
    ${gt_license_user}@${gt_license_ip} </dev/null &>/dev/null &

sleep 5

echo
echo "License server ports"
netstat -tuln | grep ":${gt_license_port} \|:${gt_license_vendor_port} "
