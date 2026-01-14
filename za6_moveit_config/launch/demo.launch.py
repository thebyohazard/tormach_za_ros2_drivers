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
from launch.actions import IncludeLaunchDescription, DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution

from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare
from launch_ros.descriptions import ParameterValue

from moveit_configs_utils.launch_utils import DeclareBooleanLaunchArg
from moveit_configs_utils import MoveItConfigsBuilder

# Replicate the following:
# from moveit_configs_utils.launches import generate_demo_launch


def generate_launch_description():
    """
    Launch a self contained demo.

    Includes
     * static_virtual_joint_tfs
     * robot_state_publisher
     * move_group
     * moveit_rviz
     * warehouse_db (optional)
     * ros2_control_node + controller spawners
    """
    builder = MoveItConfigsBuilder("za6", package_name="za6_moveit_config")
    moveit_config = builder.to_moveit_configs()

    ld = LaunchDescription()
    ld.add_action(
        DeclareLaunchArgument(
            "description_package",
            default_value="za6_description",
            description="Description package with robot URDF/XACRO files",
        )
    )

    # Load URDF content via robot_description.launch.py
    # Configure robot_description with fake hardware by default
    description_package_share = FindPackageShare(
        LaunchConfiguration("description_package")
    )
    ld.add_action(
        DeclareLaunchArgument(
            "include_ros2_control",
            default_value="true",
            description=("If true, include the HAL hardware ros2_control URDF"),
        )
    )
    ld.add_action(
        DeclareLaunchArgument(
            "ros2_control_name",
            default_value="FakeSystem",
            description=("ros2_control hardware name"),
        )
    )
    ld.add_action(
        DeclareLaunchArgument(
            "ros2_control_plugin",
            default_value="mock_components/GenericSystem",
            description=("ros2_control plugin; default HAL hw interface"),
        )
    )
    ld.add_action(
        DeclareLaunchArgument(
            "initial_positions_file",
            default_value=PathJoinSubstitution(
                [
                    description_package_share,
                    "config",
                    "initial_positions.yaml",
                ]
            ),
            description=("Path to initial positions YAML (for fake hardware)"),
        )
    )
    ld.add_action(
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                PathJoinSubstitution(
                    [
                        description_package_share,
                        "launch",
                        "robot_description.launch.py",
                    ]
                )
            ),
            launch_arguments=dict(
                include_ros2_control=LaunchConfiguration(
                    "include_ros2_control"
                ),
                ros2_control_name=LaunchConfiguration("ros2_control_name"),
                ros2_control_plugin=LaunchConfiguration("ros2_control_plugin"),
                initial_positions_file=LaunchConfiguration(
                    "initial_positions_file"
                ),
            ).items(),
        )
    )
    moveit_config.robot_description["robot_description"] = ParameterValue(
        value=LaunchConfiguration("robot_description_content"), value_type=str
    )

    ld.add_action(
        DeclareBooleanLaunchArg(
            "db",
            default_value=False,
            description="Start database; default False (may be large)",
        )
    )
    ld.add_action(
        DeclareBooleanLaunchArg(
            "debug",
            default_value=False,
            description="Debug mode; default False",
        )
    )
    ld.add_action(DeclareBooleanLaunchArg("use_rviz", default_value=True))

    launch_path = moveit_config.package_path / "launch"
    config_path = moveit_config.package_path / "config"

    # If there are virtual joints, broadcast static tf by including
    # virtual_joints launch
    virtual_joints_launch = launch_path / "static_virtual_joint_tfs.launch.py"
    if virtual_joints_launch.exists():
        ld.add_action(
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(str(virtual_joints_launch)),
            )
        )

    # Given the published joint states, publish tf for the robot links
    ld.add_action(
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(str(launch_path / "rsp.launch.py")),
            launch_arguments={
                'robot_description': LaunchConfiguration("robot_description_content")
            }.items(),
        )
    )

    ld.add_action(
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                str(launch_path / "move_group.launch.py")
            ),
            launch_arguments={
                'robot_description': LaunchConfiguration("robot_description_content")
            }.items(),
        )
    )

    # Run Rviz and load the default config to see the state of the move_group node
    ld.add_action(
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                str(launch_path / "moveit_rviz.launch.py")
            ),
            condition=IfCondition(LaunchConfiguration("use_rviz")),
        )
    )

    # If database loading was enabled, start warehouse as well
    ld.add_action(
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                str(launch_path / "warehouse_db.launch.py")
            ),
            condition=IfCondition(LaunchConfiguration("db")),
        )
    )

    # Fake joint driver
    ld.add_action(
        Node(
            package="controller_manager",
            executable="ros2_control_node",
            parameters=[
                str(config_path / "ros2_controllers.yaml"),
            ],
            remappings=[
                ("/controller_manager/robot_description", "/robot_description"),
            ],
        )
    )

    ld.add_action(
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                str(launch_path / "spawn_controllers.launch.py")
            ),
        )
    )

    return ld
