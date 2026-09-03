set -o pipefail

# The service is the host's own KasmVNC desktop: kasmvncserver and GNOME are
# system packages on the emed compute image, and the web client ships with
# them, so there is nothing to download or install. The compute image cannot
# be inspected from here (the login node does not carry kasmvncserver);
# start-template.sh verifies the prerequisites on the node it runs on and
# fails loud there.
echo "::notice::Nothing to install: vncserver uses the compute image's kasmvncserver and GNOME"
