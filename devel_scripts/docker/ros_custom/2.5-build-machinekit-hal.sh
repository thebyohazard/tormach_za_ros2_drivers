#!/bin/bash -e
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x
ROS_CUSTOM_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/ros_custom

###########################
# Build and install machinekit-hal
###########################

# machinekit-hal uses autotools, not cmake/ament
# Build it separately before colcon builds the ROS packages

cd ${WS_DIR}/src/machinekit-hal/src

# Generate configure script
./autogen.sh

# Configure with /usr prefix so headers go to /usr/include/machinekit
# and tools (instcomp, comp) go to /usr/bin
./configure --prefix=/usr --sysconfdir=/etc

# Build
make -j$(nproc)

# Install to system paths
make install

# Verify installation
echo "Verifying machinekit-hal installation..."
ls -la /usr/include/machinekit/
which instcomp

# Ensure machinekit.ini config file exists
if [ ! -f /etc/machinekit/machinekit.ini ]; then
    echo "machinekit.ini not found, copying from build directory..."
    mkdir -p /etc/machinekit
    cp ${WS_DIR}/src/machinekit-hal/etc/machinekit/machinekit.ini /etc/machinekit/
    cp ${WS_DIR}/src/machinekit-hal/etc/machinekit/rtapi.ini /etc/machinekit/
fi
ls -la /etc/machinekit/

###########################
# Build and install linuxcnc-ethercat
###########################

# linuxcnc-ethercat uses Makefile, needs halcompile from machinekit-hal

cd ${WS_DIR}/src/linuxcnc-ethercat

# Build (configure is done automatically by Makefile)
make -j$(nproc)

# Install
make install

# Verify installation
echo "Verifying linuxcnc-ethercat installation..."
ls -la /usr/lib/machinekit/modules/lcec*.so 2>/dev/null || ls -la /usr/lib/linuxcnc/modules/lcec*.so 2>/dev/null || echo "lcec modules location TBD"
