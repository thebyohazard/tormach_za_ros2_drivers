#!/bin/bash -xe
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh

apt-get update
cd ros_d_common

###########################
# Additional software
###########################

# Add Python sh for devel_scripts
apt-get install -y \
    python3-sh

###########################
# Misc. cleanups
###########################

# On Debian, LD_LIBRARY_PATH isn't allowed in setuid programs
# rtapi_app runs setuid, so all library paths must be in ldconfig
HOST_ARCH=$(dpkg-architecture -q DEB_HOST_GNU_TYPE)
LIBRARY_PATHS=(
    /opt/ros/${ROS_DISTRO}/lib
    /opt/ros/${ROS_DISTRO}/lib/${HOST_ARCH}
    /opt/ros/${ROS_DISTRO}/opt/rviz_ogre_vendor/lib
    /opt/ros/${ROS_DISTRO}/opt/sdformat_vendor/lib
    /opt/ros/${ROS_DISTRO}/opt/gz_math_vendor/lib
    /opt/ros/${ROS_DISTRO}/opt/gz_utils_vendor/lib
)
for LPATH in "${LIBRARY_PATHS[@]}"; do
    if [ -d "$LPATH" ]; then
        echo $LPATH | tee -a /etc/ld.so.conf.d/ros-${ROS_DISTRO}.conf
    fi
done
ldconfig

# Ensure `ethercat` group exists
# (`etherlabmaster` package that creates it isn't installed)
addgroup --system ethercat

# Ensure `robotusers` group exists
# (used for 'sudo' privileges in DIST and DEVEL images both)
addgroup --system robotusers

# Fix pytest
# - Should this go somewhere else?  Either earlier in the image build,
#   or even in a ROS package <test_depend>?
apt-get install -y \
    python3-pyside2.qttest

# Install Logrotate
apt-get install -y \
    cron \
    anacron \
    logrotate
mkdir -p /etc/pathpilot/
cp logrotate_ros.conf /etc/pathpilot/logrotate_ros.conf

# Install rsyslog
apt-get install -y \
    rsyslog

## Install Firefox web browser
apt-get install -y \
    firefox \
    libpci3

# Install and configure sudo, allow passwordless execution as root
apt-get install -y \
    sudo
echo "%robotusers ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/passwordless

# Install CycloneDDS config
cp -a cyclonedds.xml /etc/
