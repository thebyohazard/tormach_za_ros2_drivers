#!/bin/bash -xe
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh

apt-get update
cd ros_d_common

###########################
# Set up supervisord
###########################
apt-get install -y supervisor

mkdir -p \
    /etc/pathpilot \
    /var/log/pathpilot \
    /var/run/pathpilot

cp supervisord.conf /etc/pathpilot/

# Install py3-compatible supervisor_stdout
git clone https://github.com/zultron/supervisor-stdout
(
    cd supervisor-stdout
    PIP_BREAK_SYSTEM_PACKAGES=1 python3 setup.py install
)
rm -rf supervisor-stdout

###########################
# Install XVFB
###########################

VGL_VER=2.6.2
VGL_DEB=virtualgl_${VGL_VER}_amd64.deb
apt-get install -y wget
wget https://downloads.sourceforge.net/project/virtualgl/${VGL_VER}/${VGL_DEB}
apt-get install -y xvfb xauth ./$VGL_DEB

###########################
# Install x11vnc
###########################

apt-get install -y \
    x11vnc \
    xserver-xorg-video-dummy \
    gtk2-engines-murrine \
    gtk2-engines-pixbuf \
    x11-utils
cp xorg.conf /etc/pathpilot/xorg.conf

###########################
# Clean up
###########################
rm -f $VGL_DEB
