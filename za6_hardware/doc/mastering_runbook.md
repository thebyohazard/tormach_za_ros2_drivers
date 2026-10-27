# ZA6 Mastering Runbook

Step-by-step for re-mastering one joint of the ZA6 via `/home_joint`.
Applies to any branch with the `MASTERING_ENABLED` gate.

On SV660N drives, homing method 35 resets the absolute encoder's
multi-turn counter. It does not write `607Ch` or `2005-2Fh`/`2005-31h`;
those stay at zero.

## Scope and warnings

- **Each call is forward-only** — you can't un-call a homing. But if you
  have a pre-mastering `dump_params` snapshot, you *can* recover the old
  zero by computing the `6064h` shift between coordinate systems, jogging
  to drive-position `shift` in the new frame, and re-homing. See
  "Reverting a mastering call" below. Without a pre-dump, the old zero
  is genuinely lost.
- **One joint at a time.** The service takes one joint index per call.
  Don't loop.
- **The joint index is 1-based** (J1 = `data: 1`, … J6 = `data: 6`).
  Drive index is one less internally.
- Drives must be in `OPERATION ENABLED` for the service to proceed.
  "Power off" alone is not enough — the first attempt we made failed
  because drives were only powered-on, not enabled.

## Before you start

- Position the joint physically at the pose you want to define as zero.
  Brakes on arm power-off are sufficient to hold the pose during the
  procedure; the service internally engages brakes before toggling the
  home request, so the joint won't move while homing.
- Have the git working tree clean on the branch you want to commit the
  snapshots to.

## Runbook

### 1. Launch with the gate open

    ros2 launch za6_hardware hal_hardware.launch.py MASTERING_ENABLED:=true

Confirm the service exists:

    ros2 service list | grep home_joint

Expected: `/home_joint`. If absent, the launch didn't pick up the param —
stop and fix before continuing.

### 2. Pre-mastering snapshot

In the ros2-devel container, with the stack up:

    mkdir -p <path>/pre
    for i in 0 1 2 3 4 5; do
      ros2 run za6_hardware dump_params $i \
        > <path>/pre/drive${i}_$(date +%Y-%m-%dT%H-%M-%S).txt
    done

`git add`, commit, **push**. If the laptop dies, the snapshot dies with it
unless it's off-machine.

### 3. Enable drives

    ros2 service call /enable_drives std_srvs/srv/Trigger

Wait for `drives_enabled` to go true:

    ros2 topic echo --once /drives_enabled

If this step is skipped, `/home_joint` will return `success: false` with
the drive manager logging "Home request while drive not enabled" and
entering FAULT state. Recovery is just `/zero_error` (or `/enable_drives`
again depending on state) — no harm done — but it's the gotcha that
burned us the first time through.

### 4. Confirm the joint is still at the desired pose

Brakes should have held it, but double-check in RViz or by eye.

### 5. Call the service — **one joint only**

    ros2 service call /home_joint hal_hw_interface_msgs/srv/SetUInt32 "{data: 6}"

Expected response: `success: true`. Logs will show the drive going to
`MODE_HM`, homing-start, and completing. If it fails, read the logs
before retrying — most likely cause is drives-not-enabled (see step 3).

### 6. Post-mastering snapshot

    mkdir -p <path>/post
    for i in 0 1 2 3 4 5; do
      ros2 run za6_hardware dump_params $i \
        > <path>/post/drive${i}_$(date +%Y-%m-%dT%H-%M-%S).txt
    done

Commit, push.

### 7. Diff and sanity-check

    diff <path>/pre/drive${DRV}_*.txt <path>/post/drive${DRV}_*.txt

For the mastered drive, expect:
- `200B-47h` *Number of turns* to have changed (typically → `0x0000`).
- `200B-08h / 200B-4Eh / 200B-50h` absolute encoder feedback values to
  reflect the multi-turn reset.
- `6064h` position actual to be in the single-turn range near zero.
- Plus live-state noise (torques, bus voltage, temperatures, sync
  counters, control/status words). These change continuously; not
  calibration.
- `607Ch`, `2005-2Fh`, `2005-31h`, `2005-25h`: **unchanged**. If any of
  these change, that's unexpected — stop and investigate before
  closing the gate.

For the *other* drives, expect only live-state noise. No persistent
parameter changes.

### 8. Verify in the application layer

    ros2 topic echo /joint_states --once

Confirm the mastered joint reads ≈ 0 at the target pose (within a few
milliradians). RViz gives the same information visually.

### 9. Close the gate

Stop the stack. Relaunch without `MASTERING_ENABLED` (or with it
`false`):

    ros2 launch za6_hardware hal_hardware.launch.py

Confirm:

    ros2 service list | grep home_joint

Expected: no output. The service is gone from the graph until the next
deliberate mastering session.

## If something goes wrong

- **`/home_joint` returns `success: false`, drives faulted.** First
  attempt: drives probably not enabled (step 3). Clear the fault via
  `/zero_error` or cycle `/disable_drives` + `/enable_drives`, then
  retry. No persistent state was written if `control_word` never went
  to `OPERATION ENABLED` during the attempt — confirm by diffing dumps.
- **Mastered the wrong joint or at the wrong pose.** Use the recovery
  procedure below. Each call is destructive of the *current* zero,
  but with a pre-dump you can always navigate back.

## Reverting a mastering call

Possible when you have a pre-mastering `dump_params` snapshot for the
affected drive. The single-turn encoder disc is physical and doesn't
move; what changed is the multi-turn count, which shifts `6064h` by a
known integer. You compute that shift, drive to the old zero pose in
the new coordinate system, and re-home.

**Steps:**

1. From the pre- and post-mastering dumps of the affected drive, read
   `6064h` (*Position actual value*).
2. Compute `shift = pre_6064h − post_6064h`. That is a count, positive
   or negative.
3. Cross-check `200B-48h` (*Single feedback position of absolute
   encoder*) in both dumps — they should be within a few hundred
   counts at most. If they differ by something close to a full turn,
   the joint physically moved between the two dumps and the shift
   calculation will be off by integer turns. Don't proceed in that
   case.
4. Enable drives (step 3 of the main runbook).
5. Command the joint to drive-position `shift` in the new coordinate
   system. Exactly how you do this depends on the controller; any
   mechanism that moves the joint to a specific target (MoveIt
   `/move_group`, direct `/joint_trajectory_controller` command,
   manual jog while watching `6064h`) works.
6. Verify you're there: read `6064h` — should match `shift` within
   servo-positioning tolerance. Read `200B-48h` — should match the
   pre-mastering dump within a few counts. If both are good, you are
   physically at the old pre-mastering zero pose.
7. Launch with `MASTERING_ENABLED:=true` if the gate is currently
   closed.
8. Call `/home_joint` on the affected joint.
9. Post-dump and verify the drive is back to a clean
   near-zero `6064h`.

**Example from the 2026-04-23 J6 mastering** (if we ever wanted to
walk it back):

- `pre_6064h = -13400025`
- `post_6064h = -5977`
- `shift = -13400025 - (-5977) = -13394048`

Jog J6 to drive-position `-13394048` (in the new frame), verify
`200B-48h` matches the pre-dump (~`0x1B8488`), and call `/home_joint`.
J6's drive zero would then be restored to the factory pose.

**Caveats:**

- Without a pre-mastering snapshot, this doesn't work — the shift
  can't be computed. This is why snapshots matter.
- Positioning accuracy is bounded by servo tuning (typically tens of
  counts). At J6's reduction that's sub-milliradian; imperceptible.
- The cross-check in step 3 is what catches the one silent-error
  failure mode: physical multi-turn drift between dumps. For a joint
  held by brakes over minutes, this is not a real risk. For a joint
  left unpowered for weeks, be careful.
- Recovery itself consumes another `/home_joint` call. That's fine in
  practice — EEPROM wear is negligible at any reasonable usage rate —
  but it's worth knowing you're adding a homing event to the drive's
  history, not canceling one.

## Where to keep the snapshots

Keep each arm's pre- and post-mastering dumps together somewhere
versioned and off-machine. The dumps also serve as drive-replacement
recovery targets: if a drive is replaced, download the `dump_params`
values back via SDO (with `200E-02h = 3` briefly enabled for
persistence) to restore tuning.
