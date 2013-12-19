#!/bin/sh
yarn_nodemanager_remote_app_log_dir="/tmp/logs"
mapreduce_jobhistory_intermediate_done_dir="/mr_history/tmp"
mapreduce_jobhistory_done_dir="/mr_history/done"
HADOOP_LOG_DIR=${HADOOP_LOG_DIR:-${2}/logs}
yarn_staging_dir=/job-staging-yarn/
task_controler=${2}/bin/container-executor
task_cfg=${2}/etc/hadoop/container-executor.cfg
HADOOP_INSTALL=${2}
#
# the rest of these seem to be outdated.
#
# YARN_LOG_DIR={YARN_LOG_DIR:-${HADOOP_LOG_DIR}}
# yarn.nodemanager.log_dirs={yarn.nodemanager.log_dirs:-$YARN_LOG_DIR}
# yarn_nodemanager_local_dirs=""



if [[ $# -lt 4 ]]
then
  echo
  echo "Usage: $0 glustermount pathToHadoopInstall superuser group"
  echo 
  echo "Example: $0 /mnt/gluster /opt/hadoop-2.0.5 yarn hadoop"
  echo
  exit
fi

setPerms(){
  Paths=("${!1}")
  Perms=("${!2}")
  Root_Path=$3
  User=$4
  Group=$5

  for (( i=0 ; i<${#Paths[@]} ; i++ ))
   do
    mkdir -p ${Root_Path}/${Paths[$i]}
    chown ${User}:${Group}  ${Root_Path}/${Paths[$i]} 
    chmod ${Perms[$i]} ${Root_Path}/${Paths[$i]} 
    echo ${Paths[$i]} ${Perms[$i]}
    done 
}

echo "Setting permissions on Gluster Volume located at ${1}"

paths=("/tmp" "/user" "/mr_history" "${yarn_nodemanager_remote_app_log_dir}" "${mapreduce_jobhistory_intermediate_done_dir}" "${mapreduce_jobhistory_done_dir}" "/mapred" "${yarn_staging_dir}");
perms=(1777 0775 0755 1777 1777 0750 0770 0770);
setPerms paths[@] perms[@] ${1} ${3} ${4}

echo "Setting local permissions, using hadoop install ${2}"
chown -R root:${4} ${HADOOP_INSTALL}
mkdir -p ${HADOOP_LOG_DIR}
chown root:$4 ${HADOOP_LOG_DIR}
chmod 0770 ${HADOOP_LOG_DIR}



echo "Setuid bit on task controller"
chown root:${4} ${task_controler} ; chmod 6050 ${task_controler}
chown root:${4} ${task_cfg}
