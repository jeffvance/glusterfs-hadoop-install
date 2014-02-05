#!/bin/bash
#
# Copyright (c) 2013 Red Hat, Inc.
# License: Apache License v2.0
# Author: Jeff Vance <jvance@redhat.com>
#
# THIS SCRIPT IS NOT MEANT TO BE RUN STAND-ALONE.
#
# This script is a companion script to install.sh and runs on a remote node. It
# prepares the hosting node for hadoop workloads ontop of red hat storage, aka
# glusterfs. 
#
# This script does the following on each host node:
#  - modifes /etc/hosts to include all hosts ip/hostname for the cluster,
#  - ensures that ntp is running correctly,
#  - disables the firewall,
#  - install the gluster-hadoop plugin, if present in any of the subdirectories
#    from which install.sh is run.
#
# Lastly, if there are specific shell scripts within any sub-directories found
# under the deployment dir, they are executed and passed the same args as
# prep_node. Scripts named "pre_install.sh" are invoked before prep_node starts
# any of its tasks, and scripts named "post_install.sh" are invoked just prior
# to prep_node exiting. The order of execution for all pre_ and post_ install
# scripts is alphabetic based on sub-directory name.
#
# Please read the README file.
#
# Arguments (positional):
#   $1=associative array, passed by *declaration*, containing many individual
#      arg values. Note: special care is needed when passing and receiving
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
eval 'declare -A _ARGS='${1#*=} # delete the "declare -A name=" portion of arg
NODE="${_ARGS[NODE]}"
STORAGE_INSTALL="${_ARGS[INST_STORAGE]}" # true or false
MGMT_INSTALL="${_ARGS[INST_MGMT]}"       # true or false
VERBOSE="${_ARGS[VERBOSE]}"  # needed by display()
LOGFILE="${_ARGS[PREP_LOG]}" # needed by display()
DEPLOY_DIR="${_ARGS[REMOTE_DIR]}"
USING_DNS=${_ARGS[USING_DNS]} # true|false
HOSTS=($2)
HOST_IPS=($3)
#echo -e "*** $(basename $0) 1=$1\n1=$(declare -p _ARGS),\n2=${HOSTS[@]},\n3=${HOST_IPS[@]}"

NUMNODES=${#HOSTS[@]}

# source common constants and functions
source ${DEPLOY_DIR}functions


# install_plugin: copy the glusterfs-hadoop plugin from a deploy directory to
# the appropriate directory and create a symlink in the hadoop directory.
#
function install_plugin(){

  local PLUGIN_JAR='glusterfs-hadoop-.*.jar' # note: regexp, not glob
  local USR_JAVA_DIR='/usr/share/java'
  local HADOOP_JAVA_DIR='/usr/lib/hadoop/lib/'
  local jar=''; local out; local err

  # set MATCH_DIR and MATCH_FILE vars if match
  match_dir "$PLUGIN_JAR" "$SUBDIR_FILES"
  [[ -z "$MATCH_DIR" ]] && {
	display "INFO: gluster-hadoop plugin not supplied" $LOG_INFO;
	return; }

  cd $MATCH_DIR
  jar="$MATCH_FILE"

  display "-- Installing Gluster-Hadoop plug-in ($jar)..." $LOG_INFO
  # create target dirs if they does not exist
  [[ -d $USR_JAVA_DIR ]]    || mkdir -p $USR_JAVA_DIR
  [[ -d $HADOOP_JAVA_DIR ]] || mkdir -p $HADOOP_JAVA_DIR

  # copy jar and create symlink
  out="$(cp -uf $jar $USR_JAVA_DIR 2>&1)"
  err=$?
  display "plugin cp: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: plugin copy error $err" $LOG_FORCE
    exit 5
  fi

  rm -f $HADOOP_JAVA_DIR/$jar
  out="$(ln -s $USR_JAVA_DIR/$jar $HADOOP_JAVA_DIR/$jar 2>&1)"
  err=$?
  display "plugin symlink: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: plugin symlink error $err" $LOG_FORCE
    exit 7
  fi

  display "   ... Gluster-Hadoop plug-in install successful" $LOG_SUMMARY
  cd -
}
 
# validate_ntp_conf: validate the ntp config file by ensuring there is at least
# one time-server suitable for ntp use.
#
function validate_ntp_conf(){

  local timeserver; local i=1
  local NTP_CONF='/etc/ntp.conf'
  local servers=(); local numServers

  servers=($(grep "^ *server " $NTP_CONF|awk '{print $2}')) # time-servers 
  numServers=${#servers[@]}

  if (( numServers == 0 )) ; then
    display "ERROR: no server entries in $NTP_CONF" $LOG_FORCE
    exit 9
  fi

  for timeserver in "${servers[@]}" ; do
      ntpdate -q $timeserver >& /dev/null
      (( $? == 0 )) && break # exit loop, found valid time-server
      ((i+=1))
  done

  if (( i > numServers )) ; then
    display "ERROR: no suitable time-servers found in $NTP_CONF" $LOG_FORCE
    exit 11
  fi

  display "   NTP time-server $timeserver is acceptable" $LOG_INFO
}

# verify_ntp: verify that ntp is running and the config file has 1 or more
# suitable server records.
#
function verify_ntp(){

  local err; local out

  # run ntpd on reboot
  out="$(chkconfig ntpd on 2>&1)"
  err=$?
  display "chkconfig ntpd on: $out" $LOG_DEBUG
  (( err != 0 )) &&  display "WARN: chkconfig ntpd on error $err" $LOG_FORCE

  validate_ntp_conf # exits if error found

  # stop ntpd so that ntpd -qg can potentially do a large time change
  ps -C ntpd >& /dev/null
  if (( $? == 0 )) ; then
    out="$(service ntpd stop 2>&1)"
    display "ntpd stop: $out" $LOG_DEBUG
    sleep 1
    ps -C ntpd >& /dev/null # see if ntpd is stopped now...
    (( $? == 0 )) && display "WARN: ntpd did NOT stop" $LOG_FORCE
  fi

  # set time to ntp clock time now (ntpdate is being deprecated)
  # note: ntpd can't be running...
  out="$(ntpd -qg 2>&1)"
  err=$?
  display "ntpd -qg: $out" $LOG_DEBUG
  (( err != 0 )) && display "WARN: ntpd -qg (aka ntpdate) error $err" \
	$LOG_FORCE

  # start ntpd
  out="$(service ntpd start 2>&1)"
  err=$?
  display "ntpd start: $out" $LOG_DEBUG
  (( err != 0 )) && display "WARN: ntpd start error $err" $LOG_FORCE
}

# sudoers: copy the packaged sudoers file to /etc/sudoers.d/ and set its
# permissions. Note: it is ok if the sudoers file is not included in the
# install package.
# NOTE: this function is no longer invoked and should be removed at some point.
#
function sudoers(){

  local SUDOER_DIR='/etc/sudoers.d'
  local SUDOER_GLOB='*sudoer*'
  local sudoer_file="$(ls $SUDOER_GLOB 2>/dev/null)" # except 0 or 1 only!
  local SUDOER_PATH="$SUDOER_DIR/$sudoer_file"
  local SUDOER_PERM='440'
  local out; local err

  echo
  display "-- Installing sudoers file..." $LOG_SUMMARY

  [[ -z "$sudoer_file" ]] && {
	display "INFO: sudoers file not supplied in package" $LOG_INFO;
	return; }

  [[ -d "$SUDOER_DIR" ]] || {
    display "   Creating $SUDOER_DIR..." $LOG_DEBUG;
    mkdir -p $SUDOER_DIR; }

  # copy packaged sudoers file to correct location
  cp $sudoer_file $SUDOER_PATH
  if [[ ! -f $SUDOER_PATH ]] ; then
    display "ERROR: sudoers copy to $SUDOER_PATH failed" $LOG_FORCE
    exit 20
  fi

  out="$(chmod $SUDOER_PERM $SUDOER_PATH 2>&1)"
  err=$?
  display "sudoer chmod: $out" $LOG_DEBUG
  (( err != 0 )) && display "WARN: sudoers chmod error $err" $LOG_FORCE
}

# disable_firewall: turn off iptables and make the change permanent on reboot.
#
function disable_firewall(){

  local out; local err

  out="$(service iptables stop 2>&1)"
  err=$?
  display "service iptables: $out" $LOG_DEBUG
  (( err != 0 )) && display "WARN $err: iptables" $LOG_FORCE

  out="$(iptables -S 2>&1)" # expect to see no rules
  display "iptables rules: $out" $LOG_DEBUG
  
  out="$(chkconfig iptables off 2>&1)" # keep disabled after reboots
  display "chkconfig off: $out" $LOG_DEBUG
}

# install_common: perform node installation steps independent of whether or not
# the node is to be the management server or a storage/data node. Note: a node
# can be both.
#
function install_common(){

  # disable firewall
  echo
  display "-- Disable firewall" $LOG_SUMMARY
  disable_firewall

  # potentially append local hosts file entries to /etc/hosts, if not using dns
  if [[ $USING_DNS == false ]] ; then # ok to update /etc/hosts
    echo
    display "-- Setting up IP -> hostname mapping" $LOG_SUMMARY
    fixup_etc_hosts_file
  fi

  # set hostname, if not set
  [[ -z "$(hostname)" ]] && hostname $NODE

  # set up sudoers file for mapred and yarn users
  # Note: sudoers is handled in the rhs-hadoop (plugin) pgk now...
  #sudoers

  # verify NTP setup and sync clock
  echo
  display "-- Verifying NTP is running" $LOG_SUMMARY
  verify_ntp
}

# install_storage: perform the installation steps needed when the node is a
# storage/data node.
#
function install_storage(){

  local out

  # set up /etc/hosts to map ip -> hostname
  # install Gluster-Hadoop plug-in on agent nodes
  echo
  display "-- Verifying GlusterFS installation:" $LOG_SUMMARY
  install_plugin
}

# install_mgmt: perform the installations steps needed when the node is the
# management node.
#
function install_mgmt(){

  local err
 
  # nothing to do here (yet)...
}

# execute_scripts: if there are pre_ or post_ scripts in any of the extra sub-
# dirs then execute them. All prep_node args are passed to the script; however,
# unfortunately, $@ cannot be used since the arrays are lost. Therefore, each
# arg is passed individually.
#
# $1 is required and is the prefix flag for "pre" or "post" processing of
# target scripts. Only scripts named "pre_install.sh" or "post_install.sh" are
# automatically executed.
#
# Note: script errors are ignored and do not stop the next script from
#    executing. However, an exit status of 99 indicates the executed script
#    has determined that this node needs to be rebooted, so a variable is set.
# Note: for an unknown reason, the 2 arrays need to be converted to strings
#   then passed to the script. This is not necessary when passing the same
#   arrays from install.sh to prep_node.sh but seems to be required here...
#
function execute_scripts(){

  local prefix="$1" # required, "pre" or "post"
  local dir; local f; local err
  local tmp1="${HOSTS[@]}" # convert array -> string
  local tmp2="${HOST_IPS[@]}"

  echo
  [[ -z "$DIRS" ]] && return # no extra dirs so no extra scripts

  display "-- $prefix execution (if any)..." $LOG_SUMMARY

  for dir in $DIRS ; do
      f="$dir/${prefix}_install.sh"
      [[ -x "$f" ]] || continue
      display "Begin executing: $f ..." $LOG_INFO
      cd $dir
      ./$(basename $f) "$(declare -p _ARGS)" "$tmp1" "$tmp2"
      err=$?
      cd -
      (( err == 99 )) && { REBOOT_REQUIRED=true; err=0; }
      (( err != 0  )) && display "$f error: $err" $LOG_INFO
      display "Done executing: $f" $LOG_INFO
      display '-----------------------' $LOG_INFO
      echo
  done
}


# ** main ** #
#            #
echo
display "$(date). Begin: $0" $LOG_REPORT

if [[ ! -d $DEPLOY_DIR ]] ; then
  display "$NODE: Directory '$DEPLOY_DIR' missing on $(hostname)" $LOG_FORCE
  exit -1
fi

cd $DEPLOY_DIR

if (( $(ls | wc -l) == 0 )) ; then
  display "$NODE: No files found in $DEPLOY_DIR" $LOG_FORCE 
  exit -1
fi

# create SUBDIR_FILES variable which contains all files in all sub-dirs. There 
# can be 0 or more sub-dirs. Note: devutils/ is not copied to each node.
DIRS="$(find ./* -type d)"
# format for SUBDIR_FILES:  "dir1/file1 dir1/dir2/file2...dir2/fileN ..."
[[ -n "$DIRS" ]] &&
	SUBDIR_FILES="$(find $DIRS -type f -not -executable)"

# remove special logfile, start "clean" each time script is invoked
rm -f $LOGFILE

# execute pre_install.sh scripts within each sub-dir, if any
execute_scripts 'pre'

install_common

[[ $STORAGE_INSTALL == true ]] && install_storage
[[ $MGMT_INSTALL    == true ]] && install_mgmt

# execute post_install.sh scripts within each sub-dir, if any
execute_scripts 'post'

echo
display "$(date). End: $0" $LOG_REPORT

[[ -n "$REBOOT_REQUIRED" ]] && exit 99 # tell install.sh a reboot is needed
exit 0
#
# end of script
