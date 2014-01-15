#!/bin/sh

process_user=yarn
process_group=hadoop
task_controller=/usr/lib/hadoop-yarn/bin/container-executor
task_cfg=/etc/hadoop/conf/container-executor.cfg

echo "Configuring the Linux Container Executor for Hadoop"
chown root:${process_group} ${task_controller} ; chmod 6050 ${task_controller}
chown root:${process_group} ${task_cfg}
