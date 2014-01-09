# Copyright (c) 2013 Red Hat, Inc.
# License: Apache License v2.0
# Author: Jeff Vance <jvance@redhat.com>
#
# Please read the README file.
#
# THIS SCRIPT IS NOT MEANT TO BE RUN STAND-ALONE. It is automatically executed
# as an initial step by ../prep_node.sh.
#
# This script does the following on the host (this) node:
#  - installs xfs if needed
#  - installs or update glusterfs if needed
#  - installs openjdf if needed
#  - installs and starts glusterfs 
#
# Arguments (all positional):
#   $1=associative array, passed by *declaration*, containing many individual
#      arg values. Note: special care needed when passing and receiving
#      associative arrays,
#   $2=HOSTS(array),
#   $3=HOST IP-addrs(array).
#
# Note on passing arrays: the caller needs to surround the array values with
#   embedded double quotes, eg. "\"${ARRAY[@]}\""
# Note on passing associative arrays: the caller needs to pass the declare -A
#   command line which initializes the array. The receiver then evals this
#   string in order to set its own assoc array.

# constants and args
# note, delete the "declare -A name=" portion of arg
VERSION='1.01'
eval 'declare -A _ARGS='${1#*=}
BRICK_DEV="${_ARGS[BRICK_DEV]}"
STORAGE_INSTALL="${_ARGS[INST_STORAGE]}" # true or false
MGMT_INSTALL="${_ARGS[INST_MGMT]}"       # true or false
VERBOSE="${_ARGS[VERBOSE]}"  # needed be display()
LOGFILE="${_ARGS[PREP_LOG]}" # needed be display()
DEPLOY_DIR="${_ARGS[REMOTE_DIR]}"
HOSTS=($2)
HOST_IPS=($3)
#echo -e "*** $(basename $0) 1=$1\n1=$(declare -p _ARGS),\n2=${HOSTS[@]},\n3=${HOST_IPS[@]}, BRICK_DEV=$BRICK_DEV"

# source common constants and functions
source ${DEPLOY_DIR}functions


# get_plugin: wget the most recent gluster-hadoop plug-in from s3 and copy it
# to PWD. This is done by wget'ng the metadata file and extracting the latest
# version string, then wget'ng this version of the jar file.
#
function get_plugin(){

  local URL_PREFIX='http://rhbd.s3.amazonaws.com/maven/repositories/internal/org/apache/hadoop/fs/glusterfs/glusterfs-hadoop'
  local METADATA_URL="$URL_PREFIX/maven-metadata.xml"
  local JAR_PREFIX='glusterfs-hadoop-'; local JAR_SUFFIX='.jar'
  local JAR_URL="$URL_PREFIX/<VERSION>/$JAR_PREFIX<VERSION>$JAR_SUFFIX"
  local JARXML='jarxml'
  local jar=''; local jar_ver; local out; local err

  # get xml metadata and extract latest version of jar: <latest>1.2.3</latest>
  wget -q -O $JARXML $METADATA_URL
  if [[ $? != 0 || ! -f $JARXML ]] ; then
    display "ERROR: cannot wget glusterfs-hadoop plugin metadata" $LOG_FORCE
    exit 3
  fi
  jar_ver="$(grep -oPm1 "(?<=<latest>)[^<]+" $JARXML)" # 1.2.3

  # wget latest plugin jar
  jar="${JAR_PREFIX}${jar_ver}$JAR_SUFFIX"
  out="$(wget ${JAR_URL//<VERSION>/$jar_ver} 2>&1)"
  err=$?
  display "wget plugin: $out" $LOG_DEBUG
  if [[ $err != 0 || ! -f $jar ]] ; then
    display "ERROR: cannot wget $jar plugin" $LOG_FORCE
    exit 6
  fi

  display "   $jar plugin copied to $PWD" $LOG_SUMMARY
}

# install_openjdk: 
#
function install_openjdk(){

  local err; local out

  out="$(yum -y install java-1.7.0-openjdk-devel)"
  err=$?
  display "install openjdk: $out"
  (( err == 0 )) || {
	display "ERROR: openjdk not installed: $err" $LOG_FORCE; exit 8; }
}

# verify_install_openjdk: 
#
function verify_install_openjdk(){

  rpm -q java-1.7.0-openjdk-devel >& /dev/null || install_openjdk
}

# install_xfs: 
#
function install_xfs(){

  local err; local out

  out="$(yum -y install xfsprogs xfsdump)"
  err=$?
  display "install xfsprogs: $out"
  (( err == 0 )) || {
	display "ERROR: XFS not installed: $err" $LOG_FORCE; exit 10; }
}

# verify_install_xfs: 
#
function verify_install_xfs(){

  rpm -q xfsprogs >& /dev/null || install_xfs
}

# install_glusterfs:
#
function install_glusterfs(){

  local err; local out

  out="$(yum -y install glusterfs glusterfs-server glusterfs-fuse attr psmisc)"
  err=$?
  display "install glusterfs: $out"
  (( err == 0 )) || {
	display "ERROR: glusterfs not installed: $err" $LOG_FORCE; exit 13; }
}

# start_glusterd:
#
function start_glusterd(){

  local err; local out

  # persist glusterd across reboots
  out=$(systemctl enable glusterd.service)
  err=$?
  display "systemctl enable: $out" $LOG_DEBUG
  (( err != 0 )) && display "WARN: systemctl enable error $err" $LOG_FORCE 

  # start glusterd
  out=$(systemctl start glusterd.service 2>&1)
  err=$?
  display "glusterd start: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: glusterd start error $err" $LOG_FORCE
    exit 15
  fi

  # verify glusterd started
  ps -C glusterd >& /dev/null
  if (( $? != 0 )) ; then
    display "ERROR: glusterd not started" $LOG_FORCE
    exit 17
  fi

  display "   Gluster version: $(gluster --version | head -n 1) started" \
        $LOG_SUMMARY
}

# install_storage: perform the installation steps needed when the node is a
# storage/data node.
#
function install_storage(){

  echo
  display "-- Verify / install XFS" $LOG_SUMMARY
  verify_install_xfs

  echo
  display "-- Verify / install openjdk" $LOG_SUMMARY
  verify_install_openjdk

  echo
  display "-- Install glusterfs" $LOG_SUMMARY
  install_glusterfs

  echo
  display "-- Start glusterd" $LOG_SUMMARY
  start_glusterd

  echo
  display "-- Get glusterfs-hadoop plugin" $LOG_SUMMARY
  get_plugin
}

# install_mgmt: perform the installations steps needed when the node is the
# management node.
#
function install_mgmt(){

  local err;

  # nothing to do here (yet)...
}


# ** main ** #
#            #
echo
echo "$(basename $0), version: $VERSION"

[[ $STORAGE_INSTALL == true ]] && install_storage
[[ $MGMT_INSTALL    == true ]] && install_mgmt

echo
# end of script
