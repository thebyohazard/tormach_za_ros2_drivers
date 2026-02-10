#!/bin/bash -e
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x
ROS_CUSTOM_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/ros_custom

apt-get update

###########################
# Build and install custom external packages
###########################

# machinekit-hal build dependencies (from debian/control.in)
apt-get install -y \
    autoconf \
    autoconf-archive \
    automake \
    libmodbus-dev \
    libudev-dev \
    libglib2.0-dev \
    libgtk2.0-dev \
    libusb-1.0-0-dev \
    libpython3-dev \
    cython3 \
    dh-python \
    pkg-config \
    psmisc \
    libboost-dev \
    libzmq3-dev \
    libczmq-dev \
    libjansson-dev \
    libwebsockets-dev \
    python3-zmq \
    procps \
    liburiparser-dev \
    libssl-dev \
    python3-setuptools \
    uuid-dev \
    uuid-runtime \
    libavahi-client-dev \
    libprotobuf-dev \
    protobuf-compiler \
    python3-protobuf \
    libprotoc-dev \
    python3-simplejson \
    python3-sh \
    python3-pytest \
    libcgroup-dev \
    yapps2 \
    python3-yapps \
    python3-pyftpdlib \
    libck-dev \
    libreadline-dev \
    gettext

# linuxcnc-ethercat build dependencies
apt-get install -y \
    etherlabmaster-dev \
    libexpat1-dev

cd ${ROS_CUSTOM_SCRIPTS_DIR}

# Compute and install ROS workspace package dependencies
${ROS_CUSTOM_SCRIPTS_DIR}/run_rosdep.sh
