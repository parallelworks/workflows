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

# The one test of what an entry is, for adding it and for reading its port
entry_port() {
    awk 'tolower($1) == "host" { inside = 0; for (i = 2; i <= NF; i++) if ($i == "usercontainer") inside = 1 }
         inside && tolower($1) == "host" { found = 1 }
         inside && tolower($1) == "port" { port = $2 }
         END { if (found) print "port=" port }' ~/.ssh/config 2> /dev/null
}

if [ -z "$(entry_port)" ]; then
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

port=$(entry_port)
echo "USERCONTAINER_PORT=${port#port=}"
echo "USERCONTAINER_KEY=$(cat ~/.ssh/pw_id_rsa.pub)"
