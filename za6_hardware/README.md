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

## ⚠️ DANGER: `/home_joint` service (mastering)

**DO NOT CALL `/home_joint` UNDER ANY CIRCUMSTANCES unless you are
performing a deliberate, supervised mastering procedure with the
factory mastering fixture in hand.**

The `/home_joint` service triggers the drive's CiA 402 homing
procedure (`6098h = 35`: "current position is home").  On a fresh
ZA6, the drive-side zero-offset registers (`607Ch`, `2005-2Fh`,
`2005-31h`, `2005-25h`) are all zero — the drive's concept of
"zero" is the encoder's absolute zero, and physical zero is
maintained mechanically by the URDF and the arm's physical
assembly.  Calling `/home_joint` will write a **non-zero offset**
into those drive-EEPROM registers, based on whatever pose the
joint happens to be in at the moment of the call, redefining the
drive's reported zero to that pose.  Until the offset is restored
(via SDO write from a snapshot, or by re-mastering with the
fixture), all subsequent `joint_states` for that joint will be
wrong by the offset amount.  Recovery without the fixture is only
possible if a pre-event snapshot exists.

Protections in place:

1. The `/home_joint` service is **not created by default**.  It only
   appears on the ROS graph when the launch argument
   `MASTERING_ENABLED:=true` is set explicitly.  With the default
   launch, `ros2 service call /home_joint ...` fails with "service not
   available" because the service does not exist.
2. The launch arg is intentionally **ALL CAPS** (`MASTERING_ENABLED`)
   to stand out as non-routine.
3. Calling the service emits a `WARN`-level log before doing anything.
4. **Every `/home_joint` call writes a pre-mastering snapshot** (YAML)
   of the target drive's complete parameter set — including the zero-
   reference SDOs (`607Ch`, `2005-25h`, `2005-2Fh`, `2005-31h`, etc.)
   and the current `pos_fb` — BEFORE asserting the drive's
   `home_request` pin.  If the snapshot cannot be written, the
   mastering operation aborts with no change to the drive.  Files are
   timestamped, never overwritten, and the full path is included in
   the service response message.
   - Default snapshot directory: `~/.ros/za6_mastering_snapshots/`
   - Filename format: `<YYYY-MM-DDTHH-MM-SS>_joint<N>.yaml`
   - Override with launch arg `MASTERING_SNAPSHOT_DIR:=<path>`.

Restoring from a snapshot is currently a **manual SDO-write
procedure** using the values in the snapshot's `mastering_registers:`
and `full_parameter_dump:` sections.  A companion "restore from
snapshot" service is not yet implemented.

**Why power-cycling does not recover:** in absolute position linear
mode (`2002-02h = 1`, the ZA6 configuration), the homing procedure
itself *automatically stores* the new position offset (`2005-2Fh` /
`2005-31h`) to EEPROM — it bypasses the `200E-02h = 0` ("don't
persist comm writes") setting with its own internal write.  See the
SV660N series user guide (`doc/sv660n_series.pdf`, section 7.11.2,
p. 280).  Snapshot-based restore is the only recovery path.

### If a joint is reading off by a few degrees

**Do not assume the drive's zero reference is the cause.**  On this
arm, historically, joint-position problems have originated in the
ROS stack rather than in the drive (drive parameters overwritten
with wrong values due to init-order bugs, EtherCAT master version
mismatch, YAML drift between ROS 1 and ROS 2 versions, mechanical
shifts, etc.).  See
`jlp_documentation/za6_drive_eeprom_init_order.md` for a writeup of
one such bug.

Rule out the drive-side zero offset first:

    ros2 run za6_hardware dump_params <drive_pos>

and check that `607Ch`, `2005-25h`, `2005-2Fh`, and `2005-31h` all
equal `0`.  If they do, the drive's zero reference is untouched and
the problem is elsewhere (ROS YAML, URDF, HAL, or mechanical).

#### Secondary hypothesis: encoder battery

The 23-bit multi-turn absolute encoder is backed by an external
**S6-C36 battery box (3.6 V / 2600 mAh)**.  Inovance recommends
replacing the battery every two years (`doc/sv660n_series.pdf` §3,
p. 52–53).  A dead battery while the drive is powered off resets
the multi-turn counter, and the joint can read off by an integer
number of motor revolutions — with the 100:1 reducer on joint 2,
that's ~3.6° per lost revolution; with 80:1 on joint 3, ~4.5°.
The drive reports this condition as fault **E735.0** (Encoder
multi-turn counting overflow) in `603Fh`.  If `603Fh = 0x0000` on
all drives, multi-turn loss is not the cause.

#### If mastering is genuinely needed

This robot has **no home switch** (`hal_device_config.yaml` assigns
`FunIN.31` to no DI) and the configured homing method is
`6098h = 35` (present position is mechanical home).  There is no
automated home-switch-based homing available.  Re-establishing
true joint zero requires the operator to physically position the
joint at the factory-calibrated zero pose using a mastering
fixture, then call `/home_joint`.

Recovery options in order of preference:

1. **If a pre-event snapshot exists**: restore `607Ch`,
   `2005-2Fh`, `2005-31h` via manual SDO writes, power-cycle.  No
   fixture required.
2. **Acquire the mastering fixture**, physically align the joint,
   launch with `MASTERING_ENABLED:=true`, then call `/home_joint`.

### Preventive snapshot (recommended)

Because the automatic snapshot only runs as part of `/home_joint`, a
healthy robot has no snapshot on disk.  To create one preventively,
run `ros2 run za6_hardware dump_params <drive_pos>` for each of the
six drives (0–5) and archive the output off-robot (git, shared
drive).  This is the insurance policy against a future mistaken
`/home_joint` call, drive replacement, or unexpected EEPROM
corruption.

If you genuinely need to re-master a joint (you have the mastering
sensor, you have authorization, you know what you are doing):

    ros2 launch za6_hardware hal_hardware.launch.py MASTERING_ENABLED:=true
    # then, from a separate terminal, with the joint physically in its
    # mastering fixture:
    ros2 service call /home_joint jlp_msgs/srv/SetUInt32 "{data: <joint_idx>}"
    # Verify the snapshot was written (path will be in the response).
    ls -lt ~/.ros/za6_mastering_snapshots/ | head

Otherwise, leave `MASTERING_ENABLED` at its default (`false`).

## Dump drive params

A complete list of a particular drive's params can be dumped with the
following command.  The `<drive_pos>` argument is 0-5, corresponding
to joints 1-6, respectively.

    ros2 run za6_hardware dump_params <drive_pos>
