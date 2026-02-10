#!/bin/bash -e
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x
ROS_CUSTOM_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/ros_custom
ROS_BASE_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/ros_base

###########################
# Build and install custom external packages
###########################

cd ${ROS_CUSTOM_SCRIPTS_DIR}

# Build and install ROS workspace; first time because workspace
# contains intra-dependencies
${ROS_CUSTOM_SCRIPTS_DIR}/run_colcon_build.sh

# Rebuild, installing into DESTDIR for clean copying into next stage
DESTDIR=/root/ros_colcon_ws/ros-export
# - Create the $DESTDIR directory so `instcomp --install` doesn't fail
mkdir -p $DESTDIR/usr/lib/machinekit/modules
DESTDIR=$DESTDIR ${ROS_CUSTOM_SCRIPTS_DIR}/run_colcon_build.sh
# - hw_device_mgr:  Pure Python package doesn't honor DESTDIR, apparently
PKG_RESOURCES=(
    /opt/ros/${ROS_DISTRO}/share/ament_index/resource_index/packages/hw_device_mgr
    /opt/ros/${ROS_DISTRO}/share/hw_device_mgr
    /opt/ros/${ROS_DISTRO}/share/colcon-core/packages/hw_device_mgr
    /opt/ros/${ROS_DISTRO}/lib/python3.12/site-packages/hw_device_mgr*
)
for i in "${PKG_RESOURCES[@]}"; do
    mkdir -p $DESTDIR/$(dirname $i)
    cp -a $i $DESTDIR/$i
done
