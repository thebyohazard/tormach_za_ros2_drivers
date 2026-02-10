#!/bin/bash -e
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x

###########################
# Build ROS workspace
###########################

cd ${WS_DIR}

# ROS2 build environment
source /opt/ros/$ROS_DISTRO/setup.bash
# - FIXME https://robotics.stackexchange.com/questions/24088/
PYTHONPATH+=:/opt/ros/$ROS_DISTRO/local/lib/python3.12/dist-packages

# Build packages into install space
export CXXFLAGS=-g
run_with_ccache \
    colcon build \
    --install-base /opt/ros/${ROS_DISTRO} --merge-install \
    --packages-skip hal_rrbot_control \
    --cmake-args -DCMAKE_BUILD_TYPE=Release \
    --event-handlers console_cohesion+
