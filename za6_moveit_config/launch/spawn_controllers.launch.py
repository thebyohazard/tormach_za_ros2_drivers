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

from launch import LaunchDescription

from launch_ros.actions import Node

from moveit_configs_utils import MoveItConfigsBuilder

# This launch file duplicates
# moveit_configs_utils.launches.generate_spawn_controllers_launch()


def generate_launch_description():
    builder = MoveItConfigsBuilder("za6", package_name="za6_moveit_config")
    moveit_config = builder.to_moveit_configs()

    controller_mgr_config = moveit_config.trajectory_execution.get(
        "moveit_simple_controller_manager", {}
    )
    controller_names = controller_mgr_config.get("controller_names", [])
    controller_args = controller_mgr_config.get("controller_args", dict())

    # In Jazzy, controllers use use_global_arguments=false, so they don't
    # inherit parameters from controller_manager. Pass params file explicitly.
    ros2_controllers_yaml = (
        moveit_config.package_path / "config" / "ros2_controllers.yaml"
    )

    ld = LaunchDescription()

    for controller in controller_names + ["joint_state_broadcaster"]:
        arguments = list(controller_args.get(controller, list()))
        arguments.extend(["-p", str(ros2_controllers_yaml)])
        arguments.append(controller)
        ld.add_action(
            Node(
                package="controller_manager",
                executable="spawner",
                arguments=arguments,
                output="screen",
            )
        )
    return ld
