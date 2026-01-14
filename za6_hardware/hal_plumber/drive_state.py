# Copyright (c) 2023 Tormach, Inc.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#    * Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#
#    * Neither the name of the {copyright_holder} nor the names of its
#      contributors may be used to endorse or promote products derived from
#      this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

from hal_hw_interface.ros_hal_component import RosHalComponent
from hal_hw_interface.hal_pin_attrs import HalPinDir, HalPinType
from .hw_device_mgr import ZADrives, ZASimDrives, ZAHWDeviceMgr
from std_msgs.msg import Bool
from std_srvs.srv import Trigger
from hal_hw_interface_msgs.srv import SetUInt32
from trajectory_msgs.msg import JointTrajectory, JointTrajectoryPoint
import time
import attr
import traceback
from enum import Enum
from functools import cached_property


class SvcState(Enum):
    IDLE = 0
    WAIT_LATCH = 1
    WAIT_GOAL_REACHED = 2
    MAYBE_COMPLETE = 3
    COMPLETE = 4


class StateError(RuntimeError):
    pass


@attr.s()
class DriveState(RosHalComponent):
    """HAL user component that enables/disables drives through ROS service."""

    joint_error_epsilon = 0.001  # radians

    compname = "drive_state"
    enable_svc_name = "enable_drives"
    disable_svc_name = "disable_drives"
    zero_error_svc_name = "zero_error"
    home_svc_name = "home_joint"
    enabled_topic_name = "drives_enabled"
    faulted_topic_name = "drives_faulted"

    STATE_INIT = ZAHWDeviceMgr.STATE_INIT
    STATE_STOP = ZAHWDeviceMgr.STATE_STOP
    STATE_START = ZAHWDeviceMgr.STATE_START
    STATE_FAULT = ZAHWDeviceMgr.STATE_FAULT

    _state_int_to_str_map = {
        STATE_INIT: "init",
        STATE_STOP: "stop",
        STATE_START: "start",
        STATE_FAULT: "fault",
    }
    _prev_state_fb = ZAHWDeviceMgr.STATE_INIT

    @classmethod
    def state_str(cls, state):
        return cls._state_int_to_str_map.get(state, "undefined")

    @property
    def state_cmd_str(self):
        return self.state_str(self.state_cmd.get())

    def setup_component(self):
        # Set initial values on topic
        self.update()

        # Finish HAL component init
        super().setup_component()

    def init_hal_comp(self):
        super().init_hal_comp()

        # Scan bus:  read device config, load ESI files, and scan
        device_config_path = self.get_ros_param("device_config_path", "")
        assert device_config_path  # FIXME Humble wants param default
        device_config = ZAHWDeviceMgr.load_yaml_path(device_config_path)
        sim_mode = self.get_ros_param("sim_mode", False)
        drv_cls = ZASimDrives if sim_mode else ZADrives
        drv_cls.set_device_config(device_config)
        drv_cls.add_device_sdos_from_esi()
        if sim_mode:
            sim_dev_data_path = self.get_ros_param("sim_device_data_path", "")
            sim_dev_data = ZAHWDeviceMgr.load_yaml_path(sim_dev_data_path)
            drv_cls.init_class(sim_device_data=sim_dev_data)
        self.devices = drv_cls.scan_devices()
        self.logger.info(f"Drive scan found {len(self.devices)} devices:")
        for drv in self.devices:
            self.logger.info(f"    {drv}")
        joints = list(d for d in self.devices if hasattr(d, "MODE_CSP"))
        self.num_joints = len(joints)
        assert self.num_joints, "No drives found"

        # Shorthand (this should be in hal_hw_interface)
        type_u32, type_bit = HalPinType("U32"), HalPinType("BIT")
        type_float = HalPinType("FLOAT")
        dir_in, dir_out = HalPinDir("IN"), HalPinDir("OUT")
        # Create pins for talking to hw_device_mgr
        self.state_cmd = self.hal_comp.newpin("state_cmd", type_u32, dir_out)
        self.state_fb = self.hal_comp.newpin("state_fb", type_u32, dir_in)
        self.state_set = self.hal_comp.newpin("state_set", type_bit, dir_out)
        self.goal_reached = self.hal_comp.newpin(
            "goal_reached", type_bit, dir_in
        )
        self.load = self.hal_comp.newpin("load", type_bit, dir_out)
        self.home_pins = dict()
        for drv_num in range(self.num_joints):
            self.home_pins[drv_num] = dict(
                pos_fb=self.hal_comp.newpin(
                    f"{drv_num}.pos_fb", type_float, dir_in
                ),
                pos_cmd=self.hal_comp.newpin(
                    f"{drv_num}.pos_cmd", type_float, dir_in
                ),
                home_request=self.hal_comp.newpin(
                    f"{drv_num}.home_request", type_bit, dir_out
                ),
                home_success=self.hal_comp.newpin(
                    f"{drv_num}.home_success", type_bit, dir_in
                ),
                home_error=self.hal_comp.newpin(
                    f"{drv_num}.home_error", type_bit, dir_in
                ),
            )

    def init_ros_node(self, *args, **kwargs):
        super().init_ros_node(*args, **kwargs)
        self.init_state_services()
        self.init_home_service()
        self.init_topics()

    #
    # Enable/disable services
    #

    def init_state_services(self):
        # Enable/disable services
        self.enable_svc = self.node.create_service(
            Trigger,
            self.enable_svc_name,
            self.enable_svc_cb,
            qos_profile=self.qos_profile,
        )
        self.disable_svc = self.node.create_service(
            Trigger,
            self.disable_svc_name,
            self.disable_svc_cb,
            qos_profile=self.qos_profile,
        )
        self.logger.info(f"Service '{self.enable_svc_name}' created")
        self.zero_error_svc = self.node.create_service(
            Trigger,
            self.zero_error_svc_name,
            self.zero_error_svc_cb,
            qos_profile=self.qos_profile,
        )
        self.logger.info(f"Service '{self.disable_svc_name}' created")

        # Pub/sub for resetting command to feedback before enable
        self.svc_state = SvcState.IDLE
        topic_name = "/joint_trajectory_controller/joint_trajectory"
        topic = self.get_ros_param("joint_trajectory_topic", topic_name)
        self.timeout = self.get_ros_param("timeout", 15)
        self.update_rate = self.get_ros_param("update_rate", 10)
        self.update_per = 1 / self.update_rate
        self.joint_trajectory_publisher = self.node.create_publisher(
            JointTrajectory, topic, self.qos_profile
        )
        self.logger.info("Joint states sub + pub created")

    def check_entered_fault_state(self):
        # Log state changes and respond to fault state
        state_fb = self.state_fb.get()
        if self._prev_state_fb == state_fb:
            return  # No change
        self.logger.debug(f"state_fb changed to {state_fb}")
        self._prev_state_fb = state_fb
        if state_fb != self.STATE_FAULT:
            return  # No fault
        msg = "Device mgr entered FAULT state"
        self.logger.error(msg)
        raise StateError(msg)

    def init_timeout(self):
        self.start_time = time.monotonic()

    def check_timeout(self):
        if getattr(self, "start_time", None) is None:
            raise RuntimeError("check_timeout() called before init_timeout()")
        # If not yet timed out, do nothing
        time_since_start = time.monotonic() - self.start_time
        if time_since_start <= self.timeout:
            return

        # Otherwise, clear state and raise an exception
        self.state_set.set(False)
        self.start_time = None
        self.svc_state = SvcState.IDLE
        msg = (
            f"'{self.state_cmd_str}' command timeout"
            f" after {time_since_start} s in state {self.svc_state.name}."
        )
        self.logger.error(msg)
        raise StateError(msg)

    def set_state_start(self, state):
        # Set command, clear latch
        self.state_cmd.set(state)
        self.state_set.set(False)
        self.init_timeout()
        # When starting drives, zero command error to avoid unexpected motion
        if state == self.STATE_START:
            self.zero_error()
        # Continue on to latch in command
        self.logger.info(f"Requested '{self.state_cmd_str}' state; latching")
        self.set_state_wait_latch()

    def zero_error(self):
        # Build trajectory with goal = current state
        joint_names = []
        point = JointTrajectoryPoint()
        for drv_num, drv_pins in self.home_pins.items():
            joint_names.append(f"joint_{drv_num + 1}")
            point.positions.append(drv_pins["pos_fb"].get())
            point.velocities.append(0.0)
            point.accelerations.append(0.0)
        try:
            # Set load pin and publish trajectory
            self.load.set(True)
            self.logger.info(f"Publishing zero trajectory:  {point}")
            self.joint_trajectory_publisher.publish(
                JointTrajectory(joint_names=joint_names, points=[point])
            )
            self.logger.info("Published trajectory to zero command error")
            # Wait for trajectory execution
            self.init_timeout()
            all_zeroed = False
            while not all_zeroed:
                all_zeroed = True
                for drv_num, drv_pins in self.home_pins.items():
                    err = drv_pins["pos_cmd"].get() - drv_pins["pos_fb"].get()
                    if abs(err) > self.joint_error_epsilon:
                        all_zeroed = False
                if all_zeroed:
                    break
                self.check_timeout()
            self.logger.info("Successfully zeroed command error")
        except StateError as e:
            self.logger.error(f"Zero command-feedback error:  {e.msg}")
            raise
        finally:
            self.load.set(False)

    def set_state_wait_latch(self):
        # On first call, wait one cycle for device mgr to pick up changes
        if self.svc_state is not SvcState.WAIT_LATCH:
            self.svc_state = SvcState.WAIT_LATCH
            return
        # Then latch in command and transition to waiting for command complete
        self.state_set.set(True)
        self.logger.info("Command latched; waiting for command complete")
        self.set_state_wait_goal_reached()

    def set_state_wait_goal_reached(self):
        if self.svc_state not in (
            SvcState.WAIT_GOAL_REACHED,
            SvcState.MAYBE_COMPLETE,
        ):
            self.svc_state = SvcState.WAIT_GOAL_REACHED
        # If device manager not in commanded state, keep waiting
        if (
            self.state_fb.get() != self.state_cmd.get()
            or not self.goal_reached.get()
        ):
            self.svc_state = SvcState.WAIT_GOAL_REACHED
            return
        # First time around, avoid false positive
        if self.svc_state is SvcState.WAIT_GOAL_REACHED:
            self.svc_state = SvcState.MAYBE_COMPLETE
            return
        # Second time around, success
        self.svc_state = SvcState.COMPLETE
        self.state_set.set(False)
        self.logger.info(f"State cmd {self.state_cmd_str} complete")

    @cached_property
    def dispatcher(self):
        return {
            SvcState.IDLE: None,
            SvcState.WAIT_LATCH: self.set_state_wait_latch,
            SvcState.WAIT_GOAL_REACHED: self.set_state_wait_goal_reached,
            SvcState.MAYBE_COMPLETE: self.set_state_wait_goal_reached,
            SvcState.COMPLETE: None,
        }

    def set_state(self, state):
        # Kick off new state command
        self.set_state_start(state)
        # Loop until complete or timeout, or fault
        self.init_timeout()
        while self.svc_state is not SvcState.COMPLETE:
            cb = self.dispatcher[self.svc_state]
            assert cb, f"No update cb for svc_state {self.svc_state.name}"
            cb()
            self.check_timeout()
            self.check_entered_fault_state()
            time.sleep(self.update_per)
        # Complete
        cur_state_str = self.state_str(self.state_fb.get())
        return f"New state '{cur_state_str}'"

    def enable_svc_cb(self, req, rsp):
        self.logger.info(f"/{self.enable_svc_name} service called")
        try:
            rsp.success, rsp.message = True, self.set_state(self.STATE_START)
        except StateError as e:
            rsp.success, rsp.message = False, str(e)
            self.logger.error(rsp.message)
        except Exception as e:
            rsp.success, rsp.message = False, f"Exception:  {e} ({str(e)})"
            self.logger.error(rsp.message)
        self.logger.debug(f"/{self.enable_svc_name} service completed")
        return rsp

    def disable_svc_cb(self, req, rsp):
        self.logger.info(f"/{self.disable_svc_name} service called")
        try:
            rsp.success, rsp.message = True, self.set_state(self.STATE_STOP)
        except StateError as e:
            rsp.success, rsp.message = False, str(e)
        except Exception as e:
            rsp.success, rsp.message = False, f"Exception:  {e} ({str(e)})"
            self.logger.error(rsp.message)
        self.logger.debug(f"/{self.disable_svc_name} service completed")
        return rsp

    def zero_error_svc_cb(self, req, rsp):
        self.logger.info(f"/{self.zero_error_svc_name} service called")
        try:
            self.zero_error()
            rsp.success, rsp.message = True, "OK"
        except Exception as e:
            rsp.success, rsp.message = False, f"Exception:  {e} ({str(e)})"
            self.logger.error(rsp.message)
        self.logger.info(f"/{self.zero_error_svc_name} service completed")
        return rsp

    #
    # Home service
    #

    @property
    def brake_func_sdos(self):
        if self.model_id == (0x00100000, 0x000C0108):  # IS620N
            sdos = ('2004-01h', '2004-03h')  # 2004-01h:  Rob's robot
        elif self.model_id == (0x00100000, 0x000C010D):  # SV660N
            sdos = ('2004-05h',)
        else:
            raise RuntimeError(f"Unknown model ID:  {self.model_id}")
        return (self.get_sdo(s) for s in sdos)

    brake_func_on = 0x0009  # Inovance DO brake function
    brake_func_off = 0x0000  # Inovance DO no function (off)

    def force_brakes(self, device, engage):
        self.logger.info(f"{'F' if engage else 'Unf'}orcing brake for {device}")
        val = self.brake_func_off if engage else self.brake_func_on
        if device.name == "ZA_IS620N":
            sdos = ('2004-01h', '2004-03h')  # 2004-01h:  Rob's robot
        elif device.name == "ZA_SV660":
            sdos = ('2004-05h',)
        else:
            self.logger.warning(f"Brake function unknown for {device}")
            return
        config = device.config
        for sdo in sdos:
            config.download(sdo, val)

    def home_cleanup(self, joint_idx):
        self.zero_error()
        time.sleep(self.update_per)
        self.home_pins[joint_idx - 1]["home_request"].set(False)
        self.force_brakes(self.devices[joint_idx - 1], engage=False)

    def home_joint(self, joint_idx):
        # Home **joint** service; drive index is one less than joint index
        drv_idx = joint_idx - 1
        assert drv_idx in self.home_pins
        pins = self.home_pins[drv_idx]
        # Set brake; Inovance drives stop holding position in HM mode
        self.force_brakes(self.devices[drv_idx], engage=True)
        # Hold home_request high
        self.logger.info(f"Requesting joint {joint_idx} (drive {drv_idx}) home")
        pins["home_request"].set(True)
        # Wait for success or error, or timeout
        self.init_timeout()
        while True:
            if pins["home_success"].get():
                self.home_cleanup(joint_idx)
                self.logger.info(f"Joint {joint_idx} homed successfully")
                return True
            if pins["home_error"].get():
                self.home_cleanup(joint_idx)
                self.logger.error(f"Joint {joint_idx} homing failed")
                return False
            # Still waiting; check timer and spin
            try:
                self.check_timeout()
            except StateError:
                # Timeout; cleanup
                self.home_cleanup(joint_idx)
                self.logger.error(f"Joint {joint_idx} homing timeout")
                return False
            time.sleep(self.update_per)

    def home_svc_cb(self, req, rsp):
        self.logger.info(f"/{self.home_svc_name} service called")
        joint_idx = req.data
        try:
            rsp.success = self.home_joint(req.data)
            if rsp.success:
                rsp.message = f"Joint {joint_idx} homed successfully"
            else:
                rsp.message = f"Joint {joint_idx} homing failed"
        except Exception as e:
            self.home_cleanup(joint_idx)
            self.logger.error(traceback.format_exc())
            rsp.success, rsp.message = False, f"Exception:  {e} ({str(e)})"
        self.logger.info(f"/{self.home_svc_name} service completed")
        return rsp

    def init_home_service(self):
        # Home service
        self.home_svc = self.node.create_service(
            SetUInt32,
            self.home_svc_name,
            self.home_svc_cb,
            # qos_profile=self.qos_profile
        )
        self.logger.info(f"Service '{self.home_svc_name}' created")

    #
    # Enabled/faulted topics
    #

    def init_topics(self):
        # /drives_enabled
        self.enabled_topic = self.node.create_publisher(
            Bool, self.enabled_topic_name, self.qos_profile
        )
        self.enabled_msg = Bool()
        self.logger.info(f"Publisher '{self.enabled_topic_name}' created")

        # /drives_faulted
        self.faulted_topic = self.node.create_publisher(
            Bool, self.faulted_topic_name, self.qos_profile
        )
        self.faulted_msg = Bool()
        self.topic_counter = 0
        self.logger.info(f"Publisher '{self.faulted_topic_name}' created")

    def update(self):
        state = self.state_fb.get()
        enabled = state == self.STATE_START
        faulted = state == self.STATE_FAULT
        publish = self.topic_counter % 50 == 0
        self.topic_counter += 1

        if enabled != self.enabled_msg.data:
            self.logger.info(f"Drives now {'en' if enabled else 'dis'}abled")
            publish = True
        if faulted != self.faulted_msg.data:
            self.logger.info(f"Drives now {'' if faulted else 'not '}faulted")
            publish = True

        if not publish:
            return
        self.enabled_msg.data = enabled
        self.enabled_topic.publish(self.enabled_msg)
        self.faulted_msg.data = faulted
        self.faulted_topic.publish(self.faulted_msg)
