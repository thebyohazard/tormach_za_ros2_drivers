# Set up environment parameters used by scripts outside the Docker
# build
#
# See docker/env.sh for parameters used in Docker build scripts

###########################
# Variables
###########################

# Allow variables to be customized here
if test -e ~/.pathpilot_ros.conf; then
    source ~/.pathpilot_ros.conf
fi

# Read in Docker configuration
source $(dirname "${BASH_SOURCE[0]}")/docker/env.sh
# Read in the (Base OS) package specification
source $(dirname "${BASH_SOURCE[0]}")/docker/package-env.sh

# Directory paths
# - The devel_scripts directory (keep this relative to DOCKER_SCRIPTS_DIR)
DEVEL_SCRIPTS_DIR="$(readlink -f "${DOCKER_SCRIPTS_DIR}"/..)"
# - The base repo directory
REPO_DIR="$(readlink -f "${DEVEL_SCRIPTS_DIR}"/..)"
# - Where to cache install artifacts
CACHE_DIR="${CACHE_DIR:-/tmp/install-cache-$(id -un)}"

if test -z "$WS_DIR" -a -d "${REPO_DIR}/../../src"; then
    # Outside of `docker build`, assume workspace dir is directory where this
    # repo is checked out into subdir `src/tormach_za_ros2_drivers`
    WS_DIR="$(readlink -f "${REPO_DIR}/../..")"
fi
test "$(pwd)" = "$WS_DIR" && IN_WS_DIR=true || IN_WS_DIR=false

# Variables to customize in preseed.cfg
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http.us.debian.org}
DEBIAN_SECURITY_MIRROR=${DEBIAN_SECURITY_MIRROR:-security.debian.org}
DEBIAN_CD_MIRROR=${DEBIAN_CD_MIRROR:-cdimage.debian.org/cdimage}
POST_INSTALL_CMD=${POST_INSTALL_CMD:-:}

# Set http proxy for wget
test -z "${HTTP_PROXY}" || export http_proxy=${HTTP_PROXY}

###########################
# Debugging variables
###########################

# Debugging
test "$DEBUG" = true || DEBUG=false

# Executables
# - sudo
if $DEBUG; then
    SUDO='echo sudo'
    SUDO_H='echo sudo -H'
    DO='echo'
    APT_GET="echo apt-get"
elif test $(id -u) != 0; then
    # If this is defined but blank, sudo will not be used
    SUDO="${SUDO-sudo}"
    SUDO_H="${SUDO_H-${SUDO} -H}"
    DO=
    APT_GET="${SUDO-env} DEBIAN_FRONTEND=noninteractive apt-get"
else
    SUDO=
    SUDO_H=
    DO=
    APT_GET="env DEBIAN_FRONTEND=noninteractive apt-get"
fi

###########################
# Utilities
###########################

in_repo_dir() {
    pushd $REPO_DIR >/dev/null
    "$@"
    rc=$?
    popd >/dev/null
    return $rc
}

###########################
# Detect CPU configuration
###########################

check_hardware() {
    # Read system identification data
    HW_SVENDOR="$(cat /sys/devices/virtual/dmi/id/sys_vendor)"
    HW_PNAME="$(cat /sys/devices/virtual/dmi/id/product_name)"
    HW_BVENDOR="$(cat /sys/devices/virtual/dmi/id/board_vendor 2>/dev/null || true)"
    HW_BNAME="$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true)"

    # Set defaults
    #
    # - On unofficial/unknown platforms, e.g. developers' systems, don't
    #   automatically do destructive things
    HW_SUPPORTED=false

    # Set parameters for known hardware; add new entries below
    case "${HW_SVENDOR}:${HW_PNAME}:${HW_BVENDOR}:${HW_BNAME}" in
    GIGABYTE:GB-BXBT-1900:*:*)
        # CPUs 0,1 and 2,3 share caches; separating them will cause
        # large latency spikes
        RT_CPUS=${RT_CPUS:-2,3}
        GRUB_CMDLINE="intel_idle.max_cstate=1 isolcpus=${RT_CPUS}"
        HW_SUPPORTED=true
        NIC=enp1s0
        ;;
    *:20HHCTO1WW:*:*) # Bas's dev box
        RT_CPUS=2,3
        ;;
    DigitalOcean:Droplet:*:*) # Tormach CI; virtualpathpilot.com
        HW_SUPPORTED=true
        ;;
    *:*:"ASUSTeK COMPUTER INC.:PRIME H310M-A R2.0") # Beta customer controller
        RT_CPUS=5
        GRUB_CMDLINE="quiet intel_idle.max_cstate=1 isolcpus=${RT_CPUS}"
        HW_SUPPORTED=true
        ;;
    *:*:"SYWZ:S200 Series") # Alex' Borunte dev box
        RT_CPUS=5,11
        GRUB_CMDLINE="quiet intel_idle.max_cstate=1 isolcpus=${RT_CPUS} usbcore.autosuspend=-1"
        HW_SUPPORTED=true
        ;;
    "YANLING:YL-KBRL2 Series:YANLING:YL-KBRL2 Series") # Yanling iWill N15
        RT_CPUS=3,7
        GRUB_CMDLINE="intel_idle.max_cstate=1 isolcpus=${RT_CPUS} usbcore.autosuspend=-1"
        NIC=enp2s0
        HW_SUPPORTED=true
        ;;
    esac

    # EtherCAT NIC variables
    if test -n "$NIC"; then
        # Configure ethercat MAC address
        MAC=$(ip link show $NIC | awk '/link\/ether/{print $2}')
    else
        echo "WARNING:  Unknown EtherCAT NIC" 1>&2
    fi

    # GPU variables
    if which glxinfo >&/dev/null; then
        glx_string() { glxinfo -display :0 | sed -n "/${1}/ s/^.*: // p"; }
        OGL_VENDOR="$(glx_string "OpenGL vendor string")"
        OGL_RENDERER="$(glx_string "OpenGL renderer string")"
    else
        echo "WARNING: glxinfo not installed, run sudo apt install mesa-utils" 1>&2
    fi
}
###########################
# Docker image version
###########################

check_workdir_clean() {
    # "Dirty" workdir means no ignored or untracked files, and no
    # unindexed changes in the `docker/` directory (indexed changes
    # are allowed so this can run in the pre-commit script)
    test -z "$IGNORE_DIRTY_WORKDIR" || return 0 # Force result
    (
        cd ${DOCKER_SCRIPTS_DIR}
        test -z "$(git status --porcelain --untracked-files --ignored -- ./ |
            grep -v '^[AMDR]  ')"
    )
    return $?
}

compute_image_minor_version() {
    # Use first 8 chars of a sha1sum of files in the docker/ directory
    (
        export LC_ALL=C.UTF-8 # Be sure sorting is consistent
        cd $DOCKER_SCRIPTS_DIR
        find . -type f -print0 |
            sort -z |
            xargs -0 sha1sum |
            sha1sum |
            sed 's/^\(........\).*/\1/'
    )
}
update_image_vars() {
    # Image version
    IMAGE_VERSION=${IMAGE_VERSION:-$IMAGE_VERSION_MAJOR+$IMAGE_VERSION_MINOR}
    IMAGE_VERSION=${IMAGE_VERSION/./+}     # Handle old format
    IMAGE_TAG_VERSION=${IMAGE_VERSION/+/.} # `+` disallowed in Docker tag
    IMAGE_TAG=${IMAGE_TAG:-${TAG}-${IMAGE_TAG_VERSION}}
    # Base image name
    IMAGE_BASE=${IMAGE_BASE:-$IMAGE_BASE_ID/$IMAGE_REPO:$IMAGE_TAG}
    # Overlay image name
    IMAGE_OVERLAY=${OVERLAY_REPO}:$IMAGE_TAG
    # "-latest" image name
    IMAGE_TAG_LATEST=${IMAGE_TAG_LATEST:-$IMAGE_BASE_ID/$IMAGE_REPO:${TAG}-latest}

    # Final image to use
    if ${USE_OVERLAY}; then
        IMAGE=${IMAGE_OVERLAY}
    else
        IMAGE=${IMAGE_BASE}
    fi
}
bump_image_version() {
    # Usage:  bump_image_version [ HASH_ONLY ]
    #     Bump image major and minor (hash) version variables
    #     If HASH_ONLY is 'true', don't bump major version
    #
    if ! check_workdir_clean; then
        echo "ERROR:  Workdir not clean; unable to compute image hash" >&2
        return 1
    fi
    # - Bump minor version (hash)
    NEW_IMAGE_VERSION_MINOR=$(compute_image_minor_version)
    if test "${FILE_IMAGE_VERSION_MINOR}" = "${NEW_IMAGE_VERSION_MINOR}"; then
        echo "Image minor version=${FILE_IMAGE_VERSION_MINOR} unchanged" >&2
        return
    fi
    OLD_IMAGE_VERSION_MINOR=${IMAGE_VERSION_MINOR:-00000000}
    IMAGE_VERSION_MINOR=${NEW_IMAGE_VERSION_MINOR}
    # - Bump major version
    if test "$1" != true; then
        OLD_IMAGE_VERSION_MAJOR=${IMAGE_VERSION_MAJOR:-0}
        IMAGE_VERSION_MAJOR=$(($OLD_IMAGE_VERSION_MAJOR + 1))
    fi
    # - Update $IMAGE_VERSION, $IMAGE, etc.
    update_image_vars
    IMAGE_VERSION_UPDATED="true"
}
save_image_version() {
    # Usage:  save_image_version [ HASH_ONLY ]
    #     Bump image version and save to file
    #     If HASH_ONLY is 'true', don't bump major version
    bump_image_version $1
    if test $? != 0; then
        return 1 # Workdir not clean or other error
    fi
    {
        echo "IMAGE_VERSION_MAJOR=$IMAGE_VERSION_MAJOR"
        echo "IMAGE_VERSION_MINOR=$IMAGE_VERSION_MINOR"
    } >"$IMAGE_VERSION_FILE"
    # Debugging
    echo "$IMAGE_VERSION_FILE:"
    cat "$IMAGE_VERSION_FILE"
}
check_image_version() {
    # Usage:  check_image_version [ -f ]
    #
    # Check if image version needs bumping; if `-f`, exit with error
    # message; otherwis, print warning
    if test "$1" = -f -a -z "$IGNORE_DIRTY_WORKDIR"; then
        local SEVERITY=ERROR
        local RC=1
    else
        local SEVERITY=WARNING
        local RC=0
    fi
    if ! check_workdir_clean; then
        echo "$SEVERITY:  Workdir not clean; unable to compute image hash" >&2
        return $RC
    fi
    if test "${FILE_IMAGE_VERSION_MINOR}" != "${IMAGE_VERSION_CURRENT_MINOR}"; then
        echo "$SEVERITY:  Image version changed: " \
            "${FILE_IMAGE_VERSION_MINOR} != ${IMAGE_VERSION_CURRENT_MINOR}" >&2
        echo "$SEVERITY:  Consider bumping saved version" \
            "and building a new image" >&2
        return $RC
    fi
}
# - Read from file
IMAGE_VERSION_FILE="$DEVEL_SCRIPTS_DIR/image-version.sh"
if test -f "$IMAGE_VERSION_FILE"; then
    source "$IMAGE_VERSION_FILE"
    FILE_IMAGE_VERSION_MINOR=${IMAGE_VERSION_MINOR}
    FILE_IMAGE_VERSION_MAJOR=${IMAGE_VERSION_MAJOR}
fi
# - Major version defaults to zero
IMAGE_VERSION_MAJOR=${IMAGE_VERSION_MAJOR:-0}
# - Minor version
IMAGE_VERSION_MINOR=${IMAGE_VERSION_MINOR:-00000000}
# - Check for changes
IMAGE_VERSION_CURRENT_MINOR="$(compute_image_minor_version)"

###########################
# Docker image tag
###########################

# Set up Docker image variables
# - image name components (not upstream's tormach/ name, so this fork's
#   images can't be mistaken for or pushed to Tormach's registry)
IMAGE_BASE_ID=${IMAGE_BASE_ID:-za6}
IMAGE_REPO=${IMAGE_REPO:-ros2}
ROS_DISTRO=${ROS_DISTRO:-${DEFAULT_ROS_DISTRO}}
IMAGE_TYPE=${IMAGE_TYPE:-devel}
TAG=${TAG:-$ROS_DISTRO-$IMAGE_TYPE-$DEBIAN_SUITE}
# - use overlay image if an overlay path or ID is set
test -z "${OVERLAY_PATH}" -a -z "${OVERLAY_REPO}" ||
    USE_OVERLAY=${USE_OVERLAY:-true}
USE_OVERLAY=${USE_OVERLAY:-false}
# - generate base and overlay image names
update_image_vars
if $DEBUG; then
    echo "IMAGE_VERSION=${IMAGE_VERSION}" >&2
    echo "IMAGE_BASE=${IMAGE_BASE}" >&2
    test -z "$USE_OVERLAY" || echo "IMAGE_OVERLAY=${IMAGE_OVERLAY}" >&2
fi
