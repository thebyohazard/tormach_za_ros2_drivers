#!/bin/bash -xe
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
BASE_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/base

echo $'LANG=en_US.UTF-8\nLC_COLLATE=C.UTF-8' >/etc/default/locale

###########################
# Checks
###########################

# If the EtherCAT master is running, the etherlabmaster-dkms install
# will fail below.  Fail now to save some frustration.
if grep -q /proc/modules -e ^ec_master; then
    set +x
    echo "WARNING:  The Docker image is known to not build" >&2
    echo "WARNING:  when the EtherCAT master is running." >&2
    echo "WARNING:  Stop the master and re-run the build:" >&2
    echo "WARNING:      sudo systemctl stop ethercat" >&2
    exit 1
fi

###########################
# Update system & install general dependencies
###########################

# Prevent accidental installations of packages
PACKAGE_BLACKLIST=(
    python3-pint # Installed from pip; see pp-rosdep.yaml
)

>/etc/apt/preferences.d/10blacklist
for pkg in ${PACKAGE_BLACKLIST[@]}; do
    tee -a /etc/apt/preferences.d/10blacklist <<-EOF

	Package: $pkg
	Pin: release *
	Pin-Priority: -1
	EOF
done

apt-get update
apt-get upgrade -y

# Install basic utilities
apt-get install -y \
    ssh-client \
    wget \
    lsb-release \
    gnupg2 \
    qtchooser \
    mesa-utils \
    build-essential \
    gdb \
    doxygen \
    git \
    cgroup-tools

# Install python
apt-get install -y \
    python3-dbg \
    python3-pip \
    python3-setuptools
# - Make python3 and pip3 the default when running `python` or `pip`
update-alternatives --install /usr/bin/python python /usr/bin/python3 1
update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

# setup locale
apt-get install -y \
    locales
sed 's/.*#\s*\(en_US.UTF-8 UTF-8\).*/\1/' /etc/locale.gen -i
locale-gen
update-locale

# ccache
apt-get install -y \
    ccache
# - add a couple of missing symlinks if needed
test -f /usr/lib/ccache/c++ || ln -s ../../bin/ccache /usr/lib/ccache/c++
test -f /usr/lib/ccache/cc || ln -s ../../bin/ccache /usr/lib/ccache/cc

# APT repo tools
apt-get install -y \
    apt-transport-https \
    curl
if test $OS_VENDOR = debian; then
    apt-get install -y debian-keyring
    apt-get install -y debian-archive-keyring
fi

###########################
# Docker CE
###########################

# Configure official Docker repo
DOCKER_KEYRING=/usr/share/keyrings/docker.gpg
DOCKER_REPO=https://download.docker.com/linux/${OS_VENDOR}
curl -fsSL https://download.docker.com/linux/${OS_VENDOR}/gpg |
    gpg --dearmor >$DOCKER_KEYRING
echo "deb [signed-by=${DOCKER_KEYRING}] ${DOCKER_REPO} ${DEBIAN_SUITE} stable" |
    tee /etc/apt/sources.list.d/docker.list

# Install docker-ce package
apt-get update
apt-get install -y docker-ce

###########################
# Update apt cache
###########################

apt-get update

###########################
# Machinekit, EtherLab Master, hal_ros_control
###########################

# Cloudsmith.io hosting provider specific installation
apt-get install -y \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https

install_cloudsmith_repo() {
    BASE="https://dl.cloudsmith.io/public"
    ORG=$1
    REPO=$2
    KEY_ID=$3
    CODENAME=${4:-${DEBIAN_SUITE}}  # Optional 4th arg overrides codename
    KEYRING_LOCATION="/usr/share/keyrings/${ORG}-${REPO}-archive-keyring.gpg"
    CLOUDSMITH_ARGS="distro=${OS_VENDOR}&codename=${CODENAME}"
    curl -1sLf ${BASE}/${ORG}/${REPO}/gpg.${KEY_ID}.key |
        gpg --dearmor >${KEYRING_LOCATION}
    curl -1sLf "${BASE}/${ORG}/${REPO}/config.deb.txt?${CLOUDSMITH_ARGS}" \
        >/etc/apt/sources.list.d/${ORG}-${REPO}.list
}

# FIXME Use Zultron's temporary repo to pick up a few patched headers and avoid
# FIXME some problems in recent upstream releases where a new CMake build system
# FIXME is not yet stable
# install_cloudsmith_repo machinekit machinekit-hal D35981AB4276AC36
# FIXME: No Noble packages yet; use Jammy packages
install_cloudsmith_repo zultron machinekit EB6FA9FCFA405632 jammy
# - Machinekit support package repo
install_cloudsmith_repo machinekit machinekit A9B6D8B4BD8321F3 jammy
# - IgH EtherCAT Master and linuxcnc-ethercat HAL driver package repo
# FIXME: No Noble packages yet; use Jammy packages (DKMS compiles locally)
install_cloudsmith_repo zultron etherlabmaster-test 5161F3B5339BE1C3 jammy

apt-get update

# Run EtherCAT master from inside container
# - Min. v. 2:1.5.2~3
apt-get install -y etherlabmaster-dkms
