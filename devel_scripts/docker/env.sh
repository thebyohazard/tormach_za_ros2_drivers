# Set up environment parameters in Docker scripts

# Defaults
DEFAULT_ROS_DISTRO=jazzy
DEFAULT_OS_VENDOR=ubuntu
DEFAULT_DEBIAN_SUITE=noble

# Directory paths
# - The devel_scripts/docker directory
DOCKER_SCRIPTS_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

# Current OS info
# - Vendor:  debian, ubuntu
OS_VENDOR=${OS_VENDOR:-${DEFAULT_OS_VENDOR}}
# - Suite:  buster, focal, etc.
DEBIAN_SUITE=${DEBIAN_SUITE:-${DEFAULT_DEBIAN_SUITE}}

# Set up ccache for CI system
if test -d /ccache -a -z "$CCACHE_DIR"; then
    export CCACHE_DIR=/ccache
    PATH=/usr/lib/ccache:$PATH
fi
run_with_ccache() {
    ccache -s
    ccache -z
    "$@"
    ccache -s
}

# Guarantee the script is running in one of these environments, or bail
ENV_COOKIE=${ENV_COOKIE:-bare-metal} # docker-build, docker-run, bare-metal
test_environment() {
    # test_environment [ bare-metal | docker-build | docker-run | any ]
    # return true if current environment matches one on the cmdline, else false
    local e
    for e in $*; do
        if test ${ENV_COOKIE:-bare-metal} = $e -o $e = any; then
            return 0
        fi
    done
    return 1
}
assert_environment() {
    if test_environment $*; then
        return # We're running in the right place
    fi
    echo "This script is not meant for running in the" \
        "${ENV_COOKIE} environment" >&2
    exit 1
}
# - Run assert_environment now if instructed
test -z "${WANT_ENV}" || assert_environment ${WANT_ENV}
