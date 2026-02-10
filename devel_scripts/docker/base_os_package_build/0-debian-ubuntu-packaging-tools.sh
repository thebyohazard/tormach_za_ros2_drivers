#!/bin/bash -xe

# These should run in minimal environment, so avoid populating
# PathPilot Robot set of environment variables

####################################################
# Set up Debian (Ubuntu) packaging tools
####################################################

# Ensure apt cache is up to date
apt-get update

# Install the actual build tools (notice the 'equivs'
# needed for Ubuntu)
apt-get install -y \
    build-essential \
    lsb-release \
    fakeroot \
    devscripts \
    equivs \
    jq \
    curl \
    git

###########################
# The CMake build-system tool
###########################

# Kitware is publishing pre-built binaries only for amd64 and arm64 architectures!
curl -1vLf \
    $(curl -s https://api.github.com/repos/kitware/cmake/releases/latest |
        jq -r --arg FILE "cmake-\d{1,}\.\d{1,}\.\d{1,}(-.{1,})?-linux-$(dpkg-architecture -qDEB_BUILD_GNU_CPU)\.sh" \
            '.assets | .[] | select(.name? | match($FILE)) | .browser_download_url') \
    --output /tmp/cmake.sh &&
    bash /tmp/cmake.sh --skip-license --prefix=/usr/local

###########################
# Machinekit dependencies repository
###########################

# Cloudsmith.io hosting provider specific installation
apt-get install -y debian-keyring \
    debian-archive-keyring \
    apt-transport-https

install_cloudsmith_repo() {
    BASE="https://dl.cloudsmith.io/public"
    ORG=$1
    REPO=$2
    KEY_ID=$3
    DISTRO=$(lsb_release -is)
    CODENAME=${4:-$(lsb_release -cs)}  # Optional 4th arg overrides codename
    KEYRING_LOCATION="/usr/share/keyrings/${ORG}-${REPO}-archive-keyring.gpg"
    CLOUDSMITH_ARGS="distro=${DISTRO,}&codename=${CODENAME}"
    curl -1sLf ${BASE}/${ORG}/${REPO}/gpg.${KEY_ID}.key |
        gpg --dearmor >${KEYRING_LOCATION}
    curl -1sLf "${BASE}/${ORG}/${REPO}/config.deb.txt?${CLOUDSMITH_ARGS}" \
        >/etc/apt/sources.list.d/${ORG}-${REPO}.list
}

# FIXME: No Noble packages yet; use Jammy packages
install_cloudsmith_repo machinekit machinekit A9B6D8B4BD8321F3 jammy

apt-get update
