#!/bin/bash -e
#
# Run `rosdep install` to install all apt and pip dependencies for ROS
# packages in /opt/ros/${ROS_DISTRO} and optionally ./src

WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x

# PEP 668 compliance for Python 3.12+ (rosdep may install pip packages
# like pymachinetalk and sphinxcontrib-confluencebuilder that lack apt pkgs)
export PIP_BREAK_SYSTEM_PACKAGES=1
BASE_SCRIPTS_DIR=${DOCKER_SCRIPTS_DIR}/base

ROSDEP_SKIP_KEYS=(
    # From OSRF ROS2 Docker image
    # https://github.com/osrf/docker_images/blob/master/ros2/nightly/nightly/Dockerfile#L116-L117
    # cyclonedds

    # RTI Connext requires accepting a license from RTI
    rmw_connextdds

    # Only needed for MoveIt Studio pkgs
    moveit_studio_agent
    moveit_studio_behavior

    # Built from source for now via repos.yaml
    machinekit
    machinekit-dev
    linuxcnc-ethercat
)

for DIR in ${WS_DIR}/src /opt/ros/${ROS_DISTRO}; do
    if test -d $DIR; then
        ROSDEP_ARGS+=" --from-paths $DIR"
    fi
done
ROSDEP_ARGS+=" ${ROSDEP_SKIP_KEYS[*]/#/--skip-keys=}"

cd ${WS_DIR}
if test -f /opt/ros/${ROS_DISTRO}/setup.bash; then
    # rosdep needs this to pick up package deps already installed
    # - don't exit at OpenRAVE env hook
    # https://github.com/jsk-ros-pkg/openrave_planning/blob/master/openrave/env-hooks/99.openrave.sh.in
    set +e
    source /opt/ros/${ROS_DISTRO}/setup.bash
    set -e
fi

# Create script to install ROS package dependencies
DEPS=${BASE_SCRIPTS_DIR}/install_local_package_deps.sh
# - Generate bash script
rosdep install --simulate --ignore-src ${ROSDEP_ARGS} >${DEPS}
cat ${DEPS}

# Run script
if test "$1" != no_install; then
    apt-get update
    bash -xe ${DEPS}

    # Install machinekit-hal runtime dependencies
    # Since we build machinekit-hal from source (skipped in rosdep above),
    # we must manually install its runtime library dependencies.
    # These are the runtime equivalents of the -dev packages in 2-install-deps.sh
    apt-get install -y \
        libprotobuf32t64 \
        libczmq4 \
        libzmq5 \
        libjansson4 \
        libwebsockets19t64 \
        libavahi-client3 \
        libmodbus5 \
        liburiparser1

    # Install additional runtime dependencies not covered by rosdep
    apt-get install -y \
        python3-netifaces \
        python3-yapps \
        yapps2 \
        ros-${ROS_DISTRO}-sdformat-vendor
fi
