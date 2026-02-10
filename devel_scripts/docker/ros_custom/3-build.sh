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

# Copy machinekit-hal and linuxcnc-ethercat installations to EXPORT_DIR
# These were installed by 2.5-build-machinekit-hal.sh to system paths
# and need to be exported for subsequent Docker stages (mirrors what apt would install)
echo "Exporting machinekit-hal and linuxcnc-ethercat installations..."

# Export entire directories
MACHINEKIT_EXPORT_DIRS=(
    /usr/include/machinekit
    /usr/lib/machinekit
    /usr/libexec/machinekit
    /usr/share/machinekit
    /etc/machinekit
    /etc/rsyslog.d
    /etc/security/limits.d
)
for src in "${MACHINEKIT_EXPORT_DIRS[@]}"; do
    if [ -d "$src" ]; then
        mkdir -p "$DESTDIR/$src"
        cp -a "$src"/* "$DESTDIR/$src/" 2>/dev/null || true
        echo "  Exported dir: $src"
    fi
done

# Export individual binaries from /usr/bin
MACHINEKIT_BINARIES=(
    instcomp comp halcompile halcmd halrun halsampler halstreamer halscope
    halmeter halreport haltcl mank realtime runtests
    hal_input hal_gpio_mcp23017 hal_pwm_pca9685 hal_storage
    hal_temp_ads7828 hal_temp_bbb hal_temp_atlas
    mkwrapper mklauncher configserver videoserver
    lcec_conf
)
mkdir -p "$DESTDIR/usr/bin"
for bin in "${MACHINEKIT_BINARIES[@]}"; do
    if [ -f "/usr/bin/$bin" ]; then
        cp -a "/usr/bin/$bin" "$DESTDIR/usr/bin/"
        echo "  Exported bin: $bin"
    fi
done

# Export libraries from /usr/lib (shared objects and static libs)
# Include all machinekit-hal library patterns
mkdir -p "$DESTDIR/usr/lib"
MACHINEKIT_LIB_PATTERNS=(
    "/usr/lib/libmtalk*.so*"
    "/usr/lib/libmachinetalk*.so*"
    "/usr/lib/libhal*.so*"
    "/usr/lib/librtapi*.so*"
    "/usr/lib/libmk*.so*"
    "/usr/lib/libmk*.a"
    "/usr/lib/liblinuxcnc*.so*"
)
for pattern in "${MACHINEKIT_LIB_PATTERNS[@]}"; do
    for lib in $pattern; do
        if [ -e "$lib" ]; then
            cp -a "$lib" "$DESTDIR/usr/lib/"
            echo "  Exported lib: $(basename $lib)"
        fi
    done
done

# Export pkg-config file
mkdir -p "$DESTDIR/usr/share/pkgconfig"
if [ -f /usr/share/pkgconfig/machinekit-hal.pc ]; then
    cp -a /usr/share/pkgconfig/machinekit-hal.pc "$DESTDIR/usr/share/pkgconfig/"
    echo "  Exported: machinekit-hal.pc"
fi

# Export Python packages
PY_SITEPKG="/usr/lib/python3/dist-packages"
for pkg in machinekit machinetalk fdm drivers; do
    if [ -d "$PY_SITEPKG/$pkg" ]; then
        mkdir -p "$DESTDIR/$PY_SITEPKG"
        cp -a "$PY_SITEPKG/$pkg" "$DESTDIR/$PY_SITEPKG/"
        echo "  Exported Python: $pkg"
    fi
done
# Also export any .py/.so files directly in site-packages from machinekit
# Include _hal.so, _rtapi.so and similar C extension modules
for f in "$PY_SITEPKG"/hal*.py "$PY_SITEPKG"/hal*.so "$PY_SITEPKG"/_hal*.so "$PY_SITEPKG"/_rtapi*.so "$PY_SITEPKG"/rtapi*.py "$PY_SITEPKG"/rtapi*.so; do
    if [ -f "$f" ]; then
        mkdir -p "$DESTDIR/$PY_SITEPKG"
        cp -a "$f" "$DESTDIR/$PY_SITEPKG/"
        echo "  Exported Python: $(basename $f)"
    fi
done

echo "Machinekit-hal export complete."
