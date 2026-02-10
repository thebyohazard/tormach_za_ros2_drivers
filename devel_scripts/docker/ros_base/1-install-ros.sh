#!/bin/bash -xe
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
ROS_BASE_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/ros_base

apt-get update
apt-get install -y wget

###########################
# Set up ROS
###########################

# Configure ROS repo
ROS_KEYRING=/usr/share/keyrings/ros.gpg
ROS_REPO=http://packages.ros.org/ros2/ubuntu
curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc |
    gpg --dearmor >$ROS_KEYRING
{
    echo "deb [signed-by=${ROS_KEYRING}] ${ROS_REPO} ${DEBIAN_SUITE} main"
    echo "deb-src [signed-by=${ROS_KEYRING}] ${ROS_REPO} ${DEBIAN_SUITE} main"
} | tee /etc/apt/sources.list.d/ros-latest.list

apt-get update
apt-get install -y \
    python3-rosdep \
    python3-colcon-common-extensions \
    python3-colcon-mixin \
    python3-vcstool

# Install rosdep file with Machinekit keys & update local database
rm -f /etc/ros/rosdep/sources.list.d/20-default.list
rosdep init
echo "yaml file:///etc/ros/rosdep/pp-rosdep.yaml" |
    tee /etc/ros/rosdep/sources.list.d/10-local.list
cp ${ROS_BASE_SCRIPTS_DIR}/pp-rosdep.yaml /etc/ros/rosdep/pp-rosdep.yaml
rosdep update

# Install base ROS distro
apt-get install ros-${ROS_DISTRO}-ros-base
