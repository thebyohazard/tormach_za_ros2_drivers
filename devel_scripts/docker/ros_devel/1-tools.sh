#!/bin/bash -e
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x

# Ensure apt cache is up to date
apt-get update

###########################
# Tools
###########################

# Install and configure sudo, passwordless for everyone
apt-get install -y \
    sudo
echo "%robotusers	ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/passwordless

# install XML QA tools
apt-get install -y \
    xmlindent

# Install QA tool packages
apt-get install -y \
    clang-format

# install nano
apt-get install -y \
    nano

# Shell quality-of-life tools (devel only)
apt-get install -y \
    fd-find \
    jq \
    less \
    ripgrep \
    tmux \
    tree

# ROS GUI and debug tools (devel only)
apt-get install -y \
    ros-${ROS_DISTRO}-demo-nodes-cpp \
    ros-${ROS_DISTRO}-foxglove-bridge \
    ros-${ROS_DISTRO}-plotjuggler-ros \
    ros-${ROS_DISTRO}-rqt \
    ros-${ROS_DISTRO}-rqt-common-plugins \
    ros-${ROS_DISTRO}-rqt-controller-manager \
    ros-${ROS_DISTRO}-rqt-joint-trajectory-controller \
    ros-${ROS_DISTRO}-rviz2 \
    ros-${ROS_DISTRO}-topic-tools

# Deps of other workspace packages commonly built inside the container,
# which the image's rosdep pass (za6_* packages only) doesn't see
# - tf_transformations:  Python TF math, e.g. for jogging GUIs
apt-get install -y \
    ros-${ROS_DISTRO}-tf-transformations
