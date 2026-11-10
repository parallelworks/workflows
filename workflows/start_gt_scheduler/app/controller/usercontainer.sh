#!/bin/bash
# Prepares this node's side of the connection back to the user workspace: the key it
# presents there and the usercontainer host entry the license tunnel and the balance
# queries go through. Prints the port of that entry and the public key to authorize.
workspace_user=$1

mkdir -p ~/.ssh
chmod 700 ~/.ssh

if ! [ -f ~/.ssh/pw_id_rsa ]; then
    ssh-keygen -t rsa -N "" -q -f ~/.ssh/pw_id_rsa
fi

if ! grep -q '^Host usercontainer' ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config <<HERE
Host usercontainer
    HostName localhost
    User ${workspace_user}
    Port 2222
    IdentityFile ~/.ssh/pw_id_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
HERE
    chmod 600 ~/.ssh/config
fi

port=$(awk 'tolower($1) == "host" {found = ($2 == "usercontainer")} found && tolower($1) == "port" {print $2; exit}' ~/.ssh/config)
echo "USERCONTAINER_PORT=${port:-2222}"
echo "USERCONTAINER_KEY=$(cat ~/.ssh/pw_id_rsa.pub)"
