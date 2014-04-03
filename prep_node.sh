#!/bin/bash
#
# Copyright (c) 2013 Red Hat, Inc.
# License: Apache License v2.0
# Author: Jeff Vance <jvance@redhat.com>
#
# THIS SCRIPT IS NOT MEANT TO BE RUN STAND-ALONE.
#
# This script is a companion script to install.sh and runs on a remote node. It
# prepares the hosting node for hadoop workloads ontop of glusterfs. 
#
# This script does the following on each host node:
#  - (optionally) modifes /etc/hosts to include all hosts ip/hostname for the 
#    cluster. This assumes ip addresses appear in the local deploy "hosts" file,
#    otherwise, dns is assumed and /etc/hosts is not modified.
#  - ensures that ntp is running correctly,
#  - disables the firewall,
#  - (optionally) creates a PV, VG, LV based on the brick-dev and LV/VG-names,
#  - installs the gluster-hadoop plugin, if present in any of the sub-
#    directories from which install.sh is run.
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
# Note on passing associative arrays: the caller needs to pass the declare -A
#   command line which initializes the array. The receiver then evals this
#   string in order to set its own assoc array.
#
# Note on passing arrays: the caller needs to surround the array values with
#   embedded double quotes, eg. "\"${ARRAY[@]}\""


# constants and args
eval 'declare -A _ARGS='${1#*=} # delete the "declare -A name=" portion of arg
NODE="${_ARGS[NODE]}"
BRICK_DEV="${_ARGS[BRICK_DEV]}"
LV_BRICK="${_ARGS[LV_BRICK]}"
VG_NAME="${_ARGS[VG_NAME]}"
LV_NAME="${_ARGS[LV_NAME]}"
STORAGE_INSTALL="${_ARGS[INST_STORAGE]}" # true or false
MGMT_INSTALL="${_ARGS[INST_MGMT]}"       # true or false
VERBOSE="${_ARGS[VERBOSE]}"  # needed by display()
LOGFILE="${_ARGS[PREP_LOG]}" # needed by display()
DEPLOY_DIR="${_ARGS[REMOTE_DIR]}"
USING_DNS=${_ARGS[USING_DNS]} # true|false
LVM=${_ARGS[LVM]} # true|false
HOSTS=($2)
HOST_IPS=($3)
NUMNODES=${#HOSTS[@]}
#echo -e "*** $(basename $0) 1=$1\n1=$(declare -p _ARGS),\n2=${HOSTS[@]},\n3=${HOST_IPS[@]}"

# source common constants and functions
source ${DEPLOY_DIR}functions


# install_plugin: if a plugin jar is found in any of the sub-directories under
# the deploy-from dir, then copy the glusterfs-hadoop plugin from a deploy dir
# to the appropriate location and create a symlink in the hadoop directory. If
# no plugin jar is included then simply return since this is not a problem.
#
function install_plugin(){

  local PLUGIN_JAR='glusterfs-hadoop-.*.jar' # note: regexp, not glob
  local USR_JAVA_DIR='/usr/share/java'
  local HADOOP_JAVA_DIR='/usr/lib/hadoop/lib/'
  local jar=''; local out; local err

  # set MATCH_DIR and MATCH_FILE vars if match
  match_dir "$PLUGIN_JAR" "$SUBDIR_FILES"
  [[ -z "$MATCH_DIR" ]] && return # nothing to do, which is fine...

  # found plugin jar
  cd $MATCH_DIR
  jar="$MATCH_FILE"

  echo
  display "-- Installing glusterfs-hadoop plugin ($jar)..." $LOG_INFO

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
  cd - >/dev/null
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
      display "   attempting ntpdate on $timeserver..." $LOG_DEBUG
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

# create_pv: initialize a physical volume for use by LVM based on the passed-in
# device path. Arg: 1=physical volume
#
function create_pv(){

  local pv="$1"
  local err; local out; local DATA_ALIGN='2560k'

  if pv_present $pv ; then
    display "INFO: private volume \"$pv\" already exists" $LOG_DEBUG
    return
  fi

  if [[ ! -e $pv || ! -b $pv || -L $pv ]] ; then
    if [[ ! -e $pv ]] ; then
      display "ERROR: \"$pv\" does not exist, can't create PV" $LOG_FORCE
    elif [[ ! -b $pv ]] ; then
      display "ERROR: \"$pv\" is not a raw block device, can't create PV" \
	$LOG_FORCE
    else
      display "ERROR: \"$pv\" is a link, can't create PV" $LOG_FORCE
    fi
    exit 15
  fi

  display "   pvcreate of $pv:" $LOG_INFO
  out="$(pvcreate --dataalignment $DATA_ALIGN -y $pv 2>&1)"
  err=$?
  display "   pvcreate out: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR $err: pvcreate on $pv failed" $LOG_FORCE
    exit 17
  fi
}

# create_vg: create a volume group based on the args passed.
# Args: 1=vgname, 2=physical device path (single dev for now)
#
function create_vg(){

  local vg="$1"; local dev="$2"
  local err; local out

  if vg_present $vg ; then
    display "INFO: volume group \"$vg\" already exists" $LOG_DEBUG
    return
  fi

  display "   vgcreate of $vg containing $dev:" $LOG_INFO
  out="$(vgcreate $vg "$dev" 2>&1)"
  err=$?
  display "   vgcreate out: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR $err: vgcreate of $vg failed" $LOG_FORCE
    exit 19
  fi
}

# create_lv: create a logical volume in the passed-in volume group.
# Args: 1=logical volume name, 2=volume group name
#
function create_lv(){

  local lv="$1"; local vg="$2"
  local err; local out; local EXT_FREE='100%FREE'

  if lv_present $LV_BRICK ; then
    display "INFO: logical volume \"$lv\" already exists" $LOG_DEBUG
    return
  fi

  display "   lvcreate of $lv from $vg:" $LOG_INFO
  out="$(lvcreate --extents $EXT_FREE --name $lv "$vg" 2>&1)"
  err=$?
  display "   lvcreate out: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR $err: lvcreate of $lv from $vg failed" $LOG_FORCE
    exit 21
  fi
}

# install_common: perform common installation steps for all nodes, regardless
# of whether the node is to be a management server or a storage/data node.
# Note: a node can be both.
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

  # verify NTP setup and sync clock
  echo
  display "-- Verifying NTP is running" $LOG_SUMMARY
  verify_ntp
}

# install_storage: perform the installation steps needed when the node is a
# storage/data node.
# NOTE: LVM setup commented out of "normal" workflow.
#
function install_storage(){

  if [[ "$LVM" == true ]] ; then
    display "-- LVM setup:" $LOG_INFO
    create_pv $BRICK_DEV
    create_vg $VG_NAME $BRICK_DEV
    create_lv $LV_NAME $VG_NAME
  fi

  # ensure that the brick-dev is a LV, in cases where --lvm not specified
  if ! lv_present $LV_BRICK ; then
    if [[ -b $BRICK_DEV && ! -L $BRICK_DEV ]] ; then
      display "ERROR: $BRICK_DEV must be a logical volume but appears to be a raw block\n  device. Expecting: /dev/VGname/LVname" $LOG_FORCE
    else
      display "ERROR: logical volume path $BRICK_DEV does not exist" \
	$LOG_FORCE
    fi
    exit 23
  fi

  # install glusterfs-hadoop plugin, if provided in the package.
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
# unfortunately, $@ cannot be used.
#
# $1 is required and is the prefix flag for "pre" or "post" processing of
# target scripts. Only scripts named "pre_install.sh" or "post_install.sh" are
# automatically executed.
#
# Note: script errors are ignored and do not stop the next script from
#    executing. However, an exit status of 99 indicates the executed script
#    has determined that this node needs to be rebooted, so a variable is set.
#
function execute_scripts(){

  local prefix="$1" # required, "pre" or "post"
  local dir; local f; local err

  echo
  [[ -z "$DIRS" ]] && return # no extra dirs so no extra scripts

  display "-- $prefix execution (if any)..." $LOG_SUMMARY

  for dir in $DIRS ; do
      f="$dir/${prefix}_install.sh"
      [[ -x "$f" ]] || continue
      display "Begin executing: $f ..." $LOG_INFO
      cd $dir
      ./$(basename $f) "$(declare -p _ARGS)"
      err=$?
      cd - >/dev/null
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
