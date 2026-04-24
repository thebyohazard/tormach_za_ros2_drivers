# `za6_hardware`:  ZA robot HAL hardware configuration

This package contains the configuration and launch for the ZA robots
HAL hardware.  It configures and launches these things:

- The HAL realtime environment
- Hardware drivers, either EtherCAT (`lcec` HAL component) or sim
- `hw_device_mgr`, ROS2 node for controlling EtherCAT drive state in HAL
  - See the [upstream project][hw_device_mgr]
- `hal_hw_interface`, `ros2_control` controller manager in HAL
  - From `hal_ros_control`; see the [upstream project][hal_ros_control]
- `hal_io`, ROS2 node for connecting IO & other HAL pins to ROS topics
  - Also from `hal_ros_control`

[hw_device_mgr]:  https://github.com/tormach/hw_device_mgr
[hal_ros_control]:  https://github.com/tormach/hal_ros_control


## Bring up hardware

To launch the hardware (no UI):

    ros2 launch za6_hardware hal_hardware.launch.py

Add optional args:  (for complete list, see `launch/hal_hardware.launch.py`)

    sim_mode:=true  # Run sim HAL hardware
    hal_debug_output:=true hal_debug_level:=5  # HAL verbose logging to console


## Command drive state

The `hw_device_mgr` controls drive state.  A ROS node, `/drive_state`,
presents services to enable or disable drives and to query state.

Check current drive state:  enabled or faulted.

    ros2 topic echo --once /drives_enabled std_msgs/msg/Bool
    ros2 topic echo --once /drives_faulted std_msgs/msg/Bool

Zero command - feedback error.

    ros2 service call /zero_error std_srvs/srv/Trigger

Enable or disable drives.

    # Enable drives (also zeros error)
    ros2 service call /enable_drives std_srvs/srv/Trigger
    # Disable drives
    ros2 service call /disable_drives std_srvs/srv/Trigger

The `hw_device_mgr` will also log detailed diagnostic messages to the
console.

## Dump drive params

A complete list of a particular drive's params can be dumped with the
following command.  The `<drive_pos>` argument is 0-5, corresponding
to joints 1-6, respectively.

    ros2 run za6_hardware dump_params <drive_pos>

## Mastering (`/home_joint`)

> ⚠️  **Each call is forward-only — you can't un-call a homing.**  But
> if you have a pre-mastering `dump_params` snapshot, the old zero is
> recoverable: compute `shift = pre_6064h − post_6064h`, jog the joint
> to drive-position `shift` in the new coordinate system, and call
> `/home_joint` again. Empirically on SV660N hardware (2026-04-23,
> J6), method 35's persistent effect is **resetting the encoder's
> multi-turn counter** — *not* a write to object 607Ch as the YAML
> comments and the ROS1 wrapper implied. The multi-turn counter is
> encoder-internal state and cannot be restored via SDO, but the
> single-turn encoder disc is physical and invariant, so the
> coordinate-system shift is a known integer and the recovery is
> arithmetic. Without a pre-mastering snapshot the old zero is
> genuinely lost. See `src/jlp_documentation/za6_mastering_runbook.md`
> §"Reverting a mastering call" for the procedure.

**The service is gated behind `MASTERING_ENABLED`.** At default
(false), `/home_joint` is not created on the ROS graph at all — you
can't accidentally call it. Enable it only for a deliberate
mastering session:

    ros2 launch za6_hardware hal_hardware.launch.py MASTERING_ENABLED:=true

Procedure (mastering a single joint; J6 shown):

1. Jog the joint to the pose you want to call "zero." Verify visually.
2. Launch with `MASTERING_ENABLED:=true`. Confirm the service now exists:

       ros2 service list | grep home_joint

3. Snapshot all six drives and commit the dumps to git:

       for i in 0 1 2 3 4 5; do
         ros2 run za6_hardware dump_params $i \
           > <path>/pre/drive${i}_$(date +%Y-%m-%dT%H-%M-%S).txt
       done

4. Enable drives (required — the service fails if drives are in
   `SWITCH ON DISABLED`):

       ros2 service call /enable_drives std_srvs/srv/Trigger

5. Call the service with the **1-based joint index** (J6 → `data: 6`,
   drive index is 5 internally):

       ros2 service call /home_joint hal_hw_interface_msgs/srv/SetUInt32 "{data: 6}"

6. Snapshot again (post/); commit and push.
7. Verify in `/joint_states` or RViz that the joint reads ≈ 0 at the
   target pose.
8. Relaunch without `MASTERING_ENABLED` (or with it false). Confirm
   the service is gone.

See `src/jlp_documentation/za6_mastering_runbook.md` for the full
runbook with gotchas, and `src/jlp_documentation/za6_mastering_chain.md`
for the underlying analysis and the 2026-04-23 empirical result.
