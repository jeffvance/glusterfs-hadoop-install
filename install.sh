#!/bin/bash
#
# Copyright (c) 2013 Red Hat, Inc.
# License: Apache License v2.0
# Author: Jeff Vance <jvance@redhat.com>
#
# Please read the README.txt file.
#
# This script helps to set up Glusterfs for Hadoop workloads. All tasks common
# to both fedora and Red Hat Storage (RHS) are done here and in the companion
# prep_node.sh script, which is executed once per node. prep_node.sh will
# automatically execute pre_install.sh and post_install.sh scripts in all
# directories the deploy-from dir. Also, all files in sub-directories under the
# deploy-from dir are copied to each host defined in the local "hosts" file.
#
# Assumptions:
#  - passwordless SSH is setup between the installation node and each storage
#    node,
#  - a data partition has been created for the storage brick,
#  - the order of the nodes in the "hosts" file is in replica order.
#
# See the usage() function for arguments and their definitions.

# set global variables
SCRIPT=$(basename $0)
INSTALL_VER='0.77'   # self version
INSTALL_DIR=$PWD     # name of deployment (install-from) dir
INSTALL_FROM_IP=($(hostname -I))
INSTALL_FROM_IP=${INSTALL_FROM_IP[$(( ${#INSTALL_FROM_IP[@]}-1 ))]} # last ntry
REMOTE_INSTALL_DIR="/tmp/rhs-hadoop-install/" # on each node
# companion install script name
PREP_SH='prep_node.sh' # companion script run on each node
REMOTE_PREP_SH="$REMOTE_INSTALL_DIR$PREP_SH" # full path
NUMNODES=0           # number of nodes in hosts file (= trusted pool size)
# local logfile on each host, copied from remote host to install-from host
PREP_NODE_LOG='prep_node.log'
PREP_NODE_LOG_PATH="${REMOTE_INSTALL_DIR}$PREP_NODE_LOG"

# DO_BITS globaltask mask: bit set means to do the task associated with it
DO_BIT=0xff # default is to do all tasks

# define bits in the DO_BITS global for the various perpare tasks
# note: right-most bit is 0, value is the shift amount
REPORT_BIT=0
INSTALL_BIT=1
CLEAN_BIT=2
SETUP_BIT=3
SETUP_XFS_BIT=4
SETUP_VOL_BIT=5
SETUP_USERS_BIT=6
SETUP_DIRS_BIT=7
PERF_BIT=8

# source common constants and functions
source $INSTALL_DIR/functions


# short_usage: write short usage to stdout.
#
function short_usage(){

  cat <<EOF

Syntax:

$SCRIPT [-v|--version] | [-h|--help]

$SCRIPT [--brick-mnt <path>] [--vol-name <name>]  [--vol-mnt <path>]
           [--replica <num>]    [--hosts <path>]     [--mgmt-node <node>]
           [--logfile <path>]   [-y]
           [--verbose [num] ]   [-q|--quiet]         [--debug]
           [brick-dev]

EOF
}

# usage: write full usage/help text to stdout.
# Note: the --mkdirs, --users, --clean, --setup  options are not ydocumented.
#
function usage(){

  cat <<EOF

Usage:

Prepares a glusterfs volume for Hadoop workloads. Note that hadoop itself is not
installed by these scripts. The user is expected to install hadoop separately.
Each node in the storage cluster must be defined in the local "hosts" file. The
"hosts" file must be created prior to running this script. The "hosts" file
format is described in the included hosts.example file.
  
The brick-dev argument names the brick device where the XFS file system will be
mounted. Examples include: /dev/<VGname>/<LVname> or /dev/vdb1, etc. The brick-
dev names a RAID6 storage partition. If the brick-dev is omitted then each line
in the local "hosts" file must include a brick-dev-path.
EOF
  short_usage
  cat <<EOF
  brick-dev          : Brick device path where the XFS file system is created.
                       Eg. /dev/vgName/lvName.
  --brick_mnt <path> : Brick directory. Default: "/mnt/brick1/<volname>".
  --vol-name  <name> : Gluster volume name. Default: "HadoopVol".
  --vol-mnt   <path> : Gluster mount point. Default: "/mnt/glusterfs".
  --replica   <num>  : Volume replication count. The number of storage nodes
                       must be a multiple of the replica count. Default: 2.
  --hosts     <path> : path to \"hosts\" file. This file contains a list of
                       "IP-addr hostname" pairs for each node in the cluster.
                       Default: "./hosts".
  --mgmt-node <node> : hostname of the node to be used as the management node.
                       Default: the first node appearing in the "hosts" file.
  --logfile   <path> : logfile name. Default is /var/log/rhs-hadoo-install.log.
  -y                 : suppress prompts and auto-answer "yes". Default is to
                       prompt the user.
  --verbose   [=num] : set the verbosity level to a value of 0, 1, 2, 3. If
                       --verbose is omitted the default value is 2(summary). If
                       --verbose is supplied with no value verbosity is set to
                       1(info).  0=debug, 1=info, 2=summary, 3=report-only.
                       Note: all output is still written to the logfile.
  --debug            : maximum output. Internally sets verbose=0.
  -q|--quiet         : suppress all output including the final summary report.
                       Internally sets verbose=9. Note: all output is still
                       written to the logfile.
  -v|--version       : current version string.
  -h|--help          : help text (this).

EOF
}

# parse_cmd: getopt is used to do general parsing. See the usage() function for
# syntax.  The RHS_INSTALL variable must be set prior to calling this function.
# Note: since the logfile path is an option, parsing errors may be written to
#   the default logfile rather than the user-defined logfile, depending on when
#   the error occurs.
#
function parse_cmd(){

  local OPTIONS='vhqy'
  local LONG_OPTS='brick-mnt:,vol-name:,vol-mnt:,replica:,hosts:,mgmt-node:,logfile:,verbose::,help,version,quiet,debug,clean,setup,mkdirs,users'

  # defaults (global variables)
  BRICK_DIR='/mnt/brick1'
  VOLNAME='HadoopVol'
  GLUSTER_MNT='/mnt/glusterfs'
  REPLICA_CNT=2
  # "hosts" file concontains hostname ip-addr for all nodes in cluster
  HOSTS_FILE="$INSTALL_DIR/hosts"
  MGMT_NODE=''
  [[ "$RHS_INSTALL" == true ]] && LOGFILE='/var/log/rhs-hadoop-install.log' ||
	LOGFILE='/var/log/glusterfs-hadoop-install.log' 
  VERBOSE=$LOG_SUMMARY
  ANS_YES='n'

  # note: $? *not* set for invalid option errors!
  local args=$(getopt -n "$SCRIPT" -o $OPTIONS --long $LONG_OPTS -- $@)

  eval set -- "$args" # set up $1... positional args

  while true ; do
      case "$1" in
	-h|--help)
	    usage; exit 0
	;;
	-v|--version)
	    echo "$SCRIPT version: $INSTALL_VER"; exit 0
	;;
	--brick-mnt)
	    BRICK_DIR=$2; shift 2; continue
	;;
	--vol-name)
	    VOLNAME=$2; shift 2; continue
	;;
	--vol-mnt)
	    GLUSTER_MNT=$2; shift 2; continue
	;;
	--replica)
	    REPLICA_CNT=$2; shift 2; continue
	;;
	--hosts)
	    HOSTS_FILE=$2; shift 2; continue
	;;
	--mgmt-node)
	    MGMT_NODE=$2; shift 2; continue
	;;
	--logfile)
	    LOGFILE=$2; shift 2; continue
	;;
	--verbose) # optional verbosity level
	    VERBOSE=$2 # may be "" if not supplied
            [[ -z "$VERBOSE" ]] && VERBOSE=$LOG_INFO # default
	    shift 2; continue
	;;
	-y)
	    ANS_YES='y'; shift; continue
	;;
	-q|--quiet)
	    VERBOSE=$LOG_QUIET; shift; continue
	;;
	--debug)
	    VERBOSE=$LOG_DEBUG; shift; continue
	;;
	--clean)
	    let "DO_BITS=((1<<CLEAN_BIT))" # all zeros but clean bit
	    shift; continue
	;;
	--setup)
	    let "DO_BITS=((1<<SETUP_BIT))" # all zeros but setup bit
            # set all of the setup bits
            let "DO_BITS=((DO_BITS | (1<<SETUP_XFS_BIT)))"
            let "DO_BITS=((DO_BITS | (1<<SETUP_VOL_BIT)))"
            let "DO_BITS=((DO_BITS | (1<<SETUP_USERS_BIT)))"
            let "DO_BITS=((DO_BITS | (1<<SETUP_DIRS_BIT)))" 
echo "****DO_BITS=$DO_BITS"
	    shift; continue
	;;
	--mkdirs)
	    let "DO_BITS=((1<<SETUP_BIT))" # all zeros but setup bit
            let "DO_BITS=((DO_BITS | (1<<SETUP_DIRS_BIT)))" # set dir bit
	    shift; continue
	;;
	--users)
	    let "DO_BITS=((1<<SETUP_BIT))" # all zeros but setup bit
            let "DO_BITS=((DO_BITS | (1<<SETUP_USERS_BIT)))" # set users bit
	    shift; continue
	;;
	--)  # no more args to parse
	    shift; break
	;;
      esac
  done

  eval set -- "$@" # move arg pointer so $1 points to next arg past last opt
  (( $# > 1 )) && {
        echo "Too many parameters: $@"; short_usage; exit -1; }

  # the brick dev is the only non-option parameter and is required unless 
  # provided in the local hosts file
  (( $# == 1 )) && BRICK_DEV="$1"

  # validate replica cnt for RHS
  (( REPLICA_CNT != 2 )) && {
	echo "replica = 2 is the only supported value"; exit -1; } 

  # --logfile, if relative pathname make absolute
  # note: needed if scripts change cwd
  if [[ $(dirname "$LOGFILE") == '.' ]] ; then
    LOGFILE="$PWD/$LOGFILE"
  fi
}

# report_deploy_values: write out args and default values to be used in this
# deploy/installation. Prompts to continue the script.
#
function report_deploy_values(){

  local ans='y'
  local OS_RELEASE='/etc/redhat-release'
  local RHS_RELEASE='/etc/redhat-storage-release'
  local OS; local RHS; local report_brick

  # report_gluster_versions: sub-function to report either the common gluster
  # version across all nodes, or to list each node and its gluster version.
  #
  function report_gluster_versions(){

    local i; local vers; local node
    local node_vers=(); local uniq_vers=()

    for (( i=0; i<$NUMNODES; i++ )); do
	node="${HOSTS[$i]}"
	vers="$(ssh root@$node 'gluster --version | head -n 1')"
	vers=${vers#glusterfs } # strip glusterfs from beginning
	vers=${vers%% built*}   # strip trailing chars from end to " built"
	node_vers[$i]=$vers
    done

    uniq_vers=($(printf '%s\n' "${node_vers[@]}" | sort -u))

    case ${#uniq_vers[@]} in
      0)
	display "No nodes in this cluster have gluster installed" $LOG_REPORT
      ;;
      1)
	display "GlusterFS:            $vers (same on all nodes)" $LOG_REPORT
      ;;
      *) 
	display "WARNING! There are ${#uniq_vers[*]} versions of gluster in this cluster" $LOG_REPORT
	for (( i=0; i<$NUMNODES; i++ )); do
	    node="${HOSTS[$i]}"
	    vers="${node_vers[$i]}"
	    display "  $node: $vers" $LOG_REPORT
	done
      ;;
    esac
  }

  # main #
  #      #
  # assume 1st node is representative of OS version for cluster
  OS="$(ssh -oStrictHostKeyChecking=no root@$firstNode cat $OS_RELEASE)"
  if [[ "$RHS_INSTALL" == true ]] ; then
    RHS="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	if [[ -f $RHS_RELEASE ]] ; then
	  cat $RHS_RELEASE
	else
	  echo '2.0.x'
	fi")"
  fi

  # report brick-dev
  if [[ -n "$BRICK_DEV" ]] ; then # passed as cmdline arg
    report_brick="$BRICK_DEV"
  else
    report_brick="${BRICKS[@]}"
  fi

  display
  display "OS:                   $OS" $LOG_REPORT
  [[ -n "$RHS" ]] &&
    display "RHS:                  $RHS" $LOG_REPORT
  report_gluster_versions
  
  display
  display "---------- Deployment Values ----------" $LOG_REPORT
  display "  Install-from dir:   $INSTALL_DIR"      $LOG_REPORT
  display "  Install-from IP:    $INSTALL_FROM_IP"  $LOG_REPORT
  display "  Remote install dir: $REMOTE_INSTALL_DIR"  $LOG_REPORT
  display "  \"hosts\" file:       $HOSTS_FILE"     $LOG_REPORT
  display "  Using DNS:          $USING_DNS"        $LOG_REPORT
  display "  Number of nodes:    $NUMNODES"         $LOG_REPORT
  display "  Management node:    $MGMT_NODE"        $LOG_REPORT
  display "  Volume name:        $VOLNAME"          $LOG_REPORT
  display "  # of replicas:      $REPLICA_CNT"      $LOG_REPORT
  display "  Volume mount:       $GLUSTER_MNT"      $LOG_REPORT
  display "  XFS device path(s)  $report_brick"     $LOG_REPORT
  display "  XFS brick dir:      $BRICK_DIR"        $LOG_REPORT
  display "  XFS brick mount:    $BRICK_MNT"        $LOG_REPORT
  display "  Verbose:            $VERBOSE"          $LOG_REPORT
  display "  Log file:           $LOGFILE"          $LOG_REPORT
  display    "_______________________________________" $LOG_REPORT

  [[ $VERBOSE < $LOG_QUIET && "$ANS_YES" == 'n' ]] && {
	read -p "Continue? [y|N] " ans; }
  case $ans in
    y|yes|Y|YES|Yes) # ok, do nothing
    ;;
    *) exit 0
  esac
}

# function kill_gluster: make sure glusterd and related processes are killed.
# Optional $1 arg is applied to killall, typically -9.
function kill_gluster(){

  local kill_arg="$1"
  local node; local out
  local GLUSTER_PROCESSES='glusterd glusterfs glusterfsd'

  # kill gluster processes on all nodes
  display "Stopping gluster processes on all nodes..." $LOG_INFO
  for node in "${HOSTS[@]}"; do
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    killall $kill_arg $GLUSTER_PROCESSES" 2>&1)"
      sleep 2
      if ps -C ${GLUSTER_PROCESSES// /,} >& /dev/null ; then
	display "ERROR on node $node: 1 or more gluster processes not killed" \
		$LOG_FORCE
	display "  service: $(service glusterd status)" $LOG_FORCE
	display "       ps: $(ps -ef|grep gluster|grep -v grep)" $LOG_FORCE
	exit 2
      fi
  done
}

# function start_gluster: make sure glusterd is started on all nodes.
function start_gluster(){

  local node; local out; local err

  display "Starting gluster processes on all nodes..." $LOG_INFO
  for node in "${HOSTS[@]}" ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	  service glusterd start
	  sleep 1
	  ps -C glusterd 2>&1")"
      err=$?
      if (( err != 0 )) ; then
	display "ERROR on node $node: glusterd not started" $LOG_FORCE
	display "  service: $(service glusterd status)" $LOG_FORCE
	display "       ps: $(ps -ef|grep gluster|grep -v grep)" $LOG_FORCE
	exit 3
      fi
  done
}

# function verify_hadoop_gid: check that the gid for the passed-in group is
# the same on all nodes. Args: $1=group name
#
function verify_hadoop_gid(){

  local grp="$1"
  local node; local out; local gid
  local gids=(); local uniq_gids=()

  for node in "${HOSTS[@]}" ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "getent group $grp")"
      if (( $? != 0 )) || [[ -z "$out" ]] ; then
	display "ERROR: group $grp not created on $node" $LOG_FORCE
	exit 4
      fi
      # extract gid, "hadoop:x:<gid>", eg hadoop:x:500;
      gid=${out%:}   # delete trailing colon
      gid=${gid##*:} # extract gid
      gids+=($gid)
  done

  uniq_gids=($(printf '%s\n' "${gids[@]}" | sort -u))
  if (( ${#uniq_gids[@]} > 1 )) ; then
    display "ERROR: \"$grp\" group has inconsistent GIDs across the cluster. $grp GIDs: ${uniq_gids[*]}" $LOG_FORCE
    exit 6
  fi
}

# function verify_user_uids: check that the uid for the passed-in user(s) is
# the same on all nodes. Args: $@=user names
#
function verify_user_uids(){

  local users=($@)
  local node; local out; local user
  local uids; local uniq_uids

  for user in "${users[@]}" ; do
     uids=()
     for node in "${HOSTS[@]}" ; do
	out="$(ssh -oStrictHostKeyChecking=no root@$node "id -u $user")"
	if (( $? != 0 )) || [[ -z "$out" ]] ; then
	  display "ERROR: user $user not created on $node" $LOG_FORCE
	  exit 9
	fi
	uids+=($out)
     done

     uniq_uids=($(printf '%s\n' "${uids[@]}" | sort -u))
     if (( ${#uniq_uids[@]} > 1 )) ; then
       display "ERROR: \"$user\" user has inconsistent UIDs across cluster. $user UIDs: ${uniq_uids[*]}" $LOG_FORCE
       exit 12
     fi
  done
}

# fix_vol_stop_delete: re-kill gluster using -9, rm current state in /var/lib/
# glusterd/*, and use the force option to re-attempt to stop/delete the volume.
# Note: glusterfs log files not deleted.
#
function fix_vol_stop_delete(){

  local out; local node
  local GLUSTERD_FILES='/var/lib/glusterd/*'

  display "attempting to fix vol stop/delete error..." $LOG_DEBUG

  # delete current gluster state using sledge hammer approach
  display "   re-starting gluster, deleting current state..." $LOG_DEBUG
  for node in "${HOSTS[@]}"; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	rm -rf $GLUSTERD_FILES 2>&1
	killall -9 -r gluster 2>&1
 	sleep 1
	service glusterd start 2>&1")"
  done
  
  display "   re-trying vol stop/delete..." $LOG_DEBUG
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster --mode=script volume stop $VOLNAME force 2>&1
        sleep 2
	gluster --mode=script volume delete $VOLNAME 2>&1")"
  sleep 2
}

# verify_vol_stop_delete: there are timing windows when using ssh and the
# gluster cli. This function returns once it has confirmed that the volume has
# been stopped and deleted successfully, or a predefined number of attempts
# have been made. An attempt is made to correct a stop/delete failure.
# Args: 1=exit code from gluster stop/delete commands, 2=output from gluster
#
function verify_vol_stop_delete(){

  local stop_del_err=$1; local errmsg="$2"
  local out; local i=0; local SLEEP=2; local LIMIT=$((NUMNODES * 2))
  local EXPCT_VOL_STATUS_ERR="Volume $VOLNAME does not exist"
  local VOL_ERR_STR='Staging failed on '

  if (( stop_del_err != 0 )) && \
      grep -qs "$VOL_ERR_STR" <<<$errmsg ; then
    # unexpected vol stop/del output so kill gluster processes, restart
    # glusterd, and re-try the vol stop/delete
    fix_vol_stop_delete
  fi

  # verify stop/delete
  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume status $VOLNAME" 2>&1)"
      [[ $? == 1 && "$out" == "$EXPCT_VOL_STATUS_ERR" ]] && break
      sleep $SLEEP 
      ((i++))
      display "...verify vol stop/delete wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume stopped/deleted..." $LOG_INFO
  else
    display "   ERROR: Volume not stopped/deleted..." $LOG_FORCE
    exit 13
  fi
}

# verify_peer_detach: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that the number of nodes in
# the trusted pool is zero, or a predefined number of attempts have been made.
# $1=peer detach iteration (0 == 1st attempt)
# Note: this function returns 0 if the peer detach is confirmed, else 1. Also,
#   if the pool has not detached on the 2nd attempt this function exists.
#
function verify_peer_detach(){

  local first=$1 # first time verifying?
  local out; local i=0; local SLEEP=2; local LIMIT=$((NUMNODES * 1))
  local err_warn='WARN'; local rtn=0

  (( first != 0 )) && err_warn='ERROR'

  while (( i < LIMIT )) ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster peer status | head -n 1")" # 'Number of Peers: x'
      [[ $? == 0 && -n "$out" && ${out##*: } == 0 ]] && break
      sleep $SLEEP 
      ((i++))
      display "...verify peer detatch wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Trusted pool detached..." $LOG_INFO
  else
    display "   $err_warn: Trusted pool NOT detached..." $LOG_FORCE
    (( first != 0 )) && exit 15
    rtn=1
  fi
  return $rtn
}

# verify_pool_create: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that the number of nodes in
# the trusted pool equals the expected number, or a predefined number of 
# attempts have been made.
#
function verify_pool_created(){

  local DESIRED_STATE='Peer in Cluster'
  local out; local i=0; local SLEEP=2; local LIMIT=$((NUMNODES * 2))

  # out contains lines where the state != desired state, which is a problem
  # note: need to use scratch file rather than a variable since the
  #  variable's content gets flattened (no newlines) and thus the grep -v
  #  won't find a node with the wrong state, unless they're all wrong.
  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster peer status >peer_status.out
	    if (( \$? == 0 )) ; then
	      grep 'State: ' <peer_status.out | grep -v '$DESIRED_STATE' 
	    else
	      echo 'All messed up!'
            fi")"
      [[ -z "$out" ]] && break # empty -> all nodes in desired state
      sleep $SLEEP 
      ((i++))
      display "...verify pool create wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Trusted pool formed..." $LOG_INFO
  else
    display "   ERROR: Trusted pool NOT formed..." $LOG_FORCE
    out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
          gluster peer status")"
    display "$out" $LOG_FORCE
    exit 18
  fi
}

# verify_vol_created: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that $VOLNAME has been
# created, or a pre-defined number of attempts have been made.
# $1=exit return from gluster vol create command.
# $2=string of all bricks
#
function verify_vol_created(){

  local volCreateErr=$1; local bricks="$2"
  local i=0; local out; local SLEEP=2; local LIMIT=$((NUMNODES * 5))

  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume info $VOLNAME >/dev/null")"
      (( $? == 0 )) && break
      sleep $SLEEP
      ((i++))
      display "...verify vol create wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume \"$VOLNAME\" created..." $LOG_INFO
  else
    display "   ERROR: Volume \"$VOLNAME\" creation failed with error $volCreateErr" $LOG_FORCE
    display "          Bricks=\"$bricks\"" $LOG_FORCE
    exit 21
  fi
}

# verify_vol_started: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that $VOLNAME has been
# started, or a pre-defined number of attempts have been made. A volume is
# considered started once all bricks are online.
# $1=vol start iteration (0 == 1st attempt)
# $2=exit return from gluster vol start command.
# Note: this function returns 0 if the vol start is confirmed, else 1. Also,
#   if the vol has not started on the 2nd attempt this function exists.
#
function verify_vol_started(){

  local first=$1; local volStartErr=$2
  local err_warn='WARN'; local rtn=0
  local i=0; local out; local SLEEP=4; local LIMIT=$((NUMNODES * 5))
  local FILTER='^Online' # grep filter
  local ONLINE=': Y'     # grep not-match value

  (( first != 0 )) && err_warn='ERROR'

  while (( i < LIMIT )) ; do # don't loop forever
      # grep for Online status != Y
      # note: need to use scratch file rather than a variable since the
      #  variable's content gets flattened (no newlines) and thus the grep -v
      #  won't find a node not online, unless they're all offline.
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume status $VOLNAME detail >vol_status.out
	    if (( \$? == 0 )) ; then
	      grep $FILTER <vol_status.out | grep -v '$ONLINE' | wc -l
            else
              echo 'vol status error'
 	    fi")"
      [[ "$out" == 0 ]] && break # exit loop
      sleep $SLEEP
      ((i++))
      display "...verify vol start wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume \"$VOLNAME\" started..." $LOG_INFO
  else
    display "   $err_warn: Volume \"$VOLNAME\" start failed with error $volStartErr" $LOG_FORCE
    (( first != 0 )) && exit 24
    rtn=1
  fi
  return $rtn
}

# verify_umounts: given the passed in node, verify that the glusterfs and
# brick umounts succeeded. 
#
function verify_umounts(){

  local node=$1 # required
  local out; local errcnt=0

  ssh -oStrictHostKeyChecking=no root@$node "
      grep -qs $GLUSTER_MNT /proc/mounts"
  if (( $? == 0 )) ; then
    display "ERROR on $node: $GLUSTER_MNT still mounted" $LOG_FORCE
    ((errcnt++))
  fi
  ssh -oStrictHostKeyChecking=no root@$node "
      grep -qs $BRICK_DIR /proc/mounts"
  if (( $? == 0 )) ; then
    display "ERROR on $node: $BRICK_MNT still mounted" $LOG_FORCE
    ((errcnt++))
  fi
  (( errcnt > 0 )) && exit 26
}

# verify_gluster_mnt: given the passed in node, verify that the glusterfs
# mount succeeded. This mount is important for the subsequent chmod and chown
# on the gluster mount dir to work.
function verify_gluster_mnt(){

  local node=$1 # required
  local out

  out="$(ssh -oStrictHostKeyChecking=no root@$node "
	grep -qs $GLUSTER_MNT /proc/mounts")"
  if (( $? != 0 )) ; then
    display "ERROR on $node: $GLUSTER_MNT *NOT* mounted" $LOG_FORCE
    exit 27
  fi
}

# cleanup: do the following steps (order matters), but prompt for confirmation
# before removing files under the gluster mount.
# 1) delete all files/dirs under volume mount **
# 2) stop vol **
# 3) delete vol **
# 4) detach nodes
# 5) umount vol if mounted
# 6) unmount brick_mnt if xfs mounted
# ** gluster cmd only done once for entire pool; all other cmds executed on
#    each node
#
function cleanup(){

  local node=''; local out; local err; local ans='y'
  local force=''; local loglev # log fence value

  if [[ "$ANS_YES" == 'n' ]] ; then
    echo
    echo "The next step is to delete all files under $GLUSTER_MNT/ across the"
    echo "cluster, and to delete the gluster volume."
    echo "Answering yes will remove ALL files in the $VOLNAME volume!" 
    read -p "Continue? [y|N] " ans
    echo
  fi
  case $ans in
    y|yes|Y|YES|Yes) # ok, continue
    ;;
    *) exit 0
  esac

  display "**Note: gluster \"cleanup\" errors below may be ignored if the $VOLNAME volume" $LOG_INFO
  display "  has not been created or started, etc." $LOG_INFO

  # 0) kill gluster in case there are various gluster processes hangs, then
  #    re-start gluster
  kill_gluster
  start_gluster

  # 1) delete all files/dirs under volume mount (distributed) 
  #    before tearing down the trusted pool
  # 2) stop vol (distributed)
  # 3) delete vol (distributed)
  display "  -- on node $firstNode (distributed):" $LOG_INFO
  display "       rm $GLUSTER_MNT/*..."            $LOG_INFO
  display "       stopping $VOLNAME volume..."     $LOG_INFO
  display "       deleting $VOLNAME volume..."     $LOG_INFO
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	rm -rf $GLUSTER_MNT/* 2>&1
	gluster --mode=script volume stop $VOLNAME 2>&1
	gluster --mode=script volume delete $VOLNAME 2>&1")"
  err=$?
  display "gluster results: $out" $LOG_DEBUG
  verify_vol_stop_delete $err "$out"

  # 4) detach nodes on all but firstNode
  display "  -- from node $firstNode:" $LOG_INFO
  display "       detaching all other nodes from trusted pool..." $LOG_INFO
  for x in {0,1}; do  # 2nd time through use force option
      out=''
      (( x != 0 )) && force='force'
      for (( i=1; i<$NUMNODES; i++ )); do # starting at 1 not 0
	  out+="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	  gluster peer detach ${HOSTS[$i]} $force 2>&1")"
	  out+="\n"
      done
      display "peer detach: $out" $LOG_DEBUG
      verify_peer_detach $x
      (( $? == 0 )) && break # detached on 1st try
  done

  # 5) umount vol on every node, if mounted
  # 6) unmount brick_mnt on every node, if xfs mounted
  display "  -- on all nodes:"            $LOG_INFO
  display "       umount $GLUSTER_MNT..." $LOG_INFO
  display "       umount $BRICK_DIR..."   $LOG_INFO
  for node in "${HOSTS[@]}"; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
          if grep -qs $GLUSTER_MNT /proc/mounts ; then
            umount $GLUSTER_MNT 2>&1
          fi
          if grep -qs $BRICK_DIR /proc/mounts ; then
            umount $BRICK_DIR 2>&1
          fi")"
      display "umounts node $node: $out" $LOG_DEBUG
      verify_umounts $node
  done
}

# create_trusted_pool: create the trusted storage pool. No error if the pool
# already exists.
#
function create_trusted_pool(){

  local out; local i

  # note: peer probe hostname cannot be firstNode
  out=''
  for (( i=1; i<$NUMNODES; i++ )); do # starting at 1, not 0
      out+="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster peer probe ${HOSTS[$i]} 2>&1")"
      out+="\n"
  done
  display "peer probe: $out" $LOG_DEBUG
}

# xfs_brick_dirs_mnt: invoked by setup(). For each hosts do:
#   mkfs.xfs brick_dev on every node
#   mkdir brick_dir and vol_mnt on every node
#   append brick_dir and gluster mount entries to fstab on every node
#   mount brick on every node
#   mkdir mapredlocal scratch dir on every node (done after brick mount)
# Args: $1=node (hostname)
#
function xfs_brick_dirs_mnt(){

  local out; local i; local node; local brick
  local BRICK_MNT_OPTS="noatime,inode64"
  local GLUSTER_MNT_OPTS="entry-timeout=0,attribute-timeout=0,use-readdirp=no,acl,_netdev"

  for (( i=0 ; i<$NUMNODES ; i++ )) ; do
      node=${HOSTS[$i]}
      display "On $node:" $LOG_DEBUG
      [[ -n "$BRICK_DEV" ]] && brick="$BRICK_DEV" || brick="${BRICKS[$i]}"
      # mkfs.xfs
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mkfs -t xfs -i size=512 -f "$brick" 2>&1")"
      if (( $? != 0 )) ; then
	display "ERROR: $node: mkfs.xfs on brick $brick: $out" $LOG_FORCE
	exit 33
      fi
      display " * mkfs.xfs on $brick: $out" $LOG_DEBUG

      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mkdir -p $BRICK_MNT 2>&1
            if [[ \$? == 0 && -d $BRICK_MNT ]] ; then
              echo ok
            else
              echo 'directory not created'
              exit 1
            fi ")"
      (( $? != 0 )) && {
	display "ERROR: $node: mkdir $BRICK_MNT: $out" $LOG_FORCE; exit 36; }
      display " * mkdir $BRICK_MNT: $out" $LOG_DEBUG

      # make vol mnt dir
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mkdir -p $GLUSTER_MNT 2>&1
            if [[ \$? == 0 && -d $GLUSTER_MNT ]] ; then
              echo ok
            else
              echo 'directory not created'
              exit 1
            fi ")"
      (( $? != 0 )) && {
	display "ERROR: $node: mkdir $GLUSTER_MNT: $out" $LOG_FORCE; exit 39; }
      display " * mkdir $GLUSTER_MNT: $out" $LOG_DEBUG

      # append brick and gluster mounts to fstab
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	     if ! grep -qs $BRICK_DIR /etc/fstab ; then
	       echo '$brick $BRICK_DIR xfs  $BRICK_MNT_OPTS  0 0' >>/etc/fstab
	     fi
	     if ! grep -qs $GLUSTER_MNT /etc/fstab ; then
	       echo '$node:/$VOLNAME  $GLUSTER_MNT  glusterfs \
		 $GLUSTER_MNT_OPTS 0 0' >>/etc/fstab
	     fi")"
      (( $? != 0 )) && {
	display "ERROR: $node: append fstab: $out" $LOG_FORCE; exit 42; }
      display " * append fstab: $out" $LOG_DEBUG

      # Note: mapred scratch dir must be created *after* the brick is
      # mounted; otherwise, mapred dir will be "hidden" by the mount.
      # Also, permissions and owner must be set *after* the gluster dir 
      # is mounted for the same reason.
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mount $brick 2>&1")" # mount via fstab
      (( $? != 0 )) && {
	display "ERROR: $node: mount $brick as $BRICK_DIR: $out" $LOG_FORCE;
	exit 45; }
      display " * brick mount: $out" $LOG_DEBUG

      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mkdir -p $MAPRED_SCRATCH_DIR 2>&1
            if [[ \$? == 0 && -d $MAPRED_SCRATCH_DIR ]] ; then
              echo ok
            else
              echo 'directory not created'
              exit 1
            fi")"
      (( $? != 0 )) && {
        display "ERROR: $node: mkdir $MAPRED_SCRATCH_DIR: $out" $LOG_FORCE;
        exit 48; }
      display " * mkdir $MAPRED_SCRATCH_DIR: $out" $LOG_DEBUG
  done
}

# mount_volume: on the passed-in node, mount the hadoop volume and verify that
# the mount worked. $1=node (hostname)
#
function mount_volume(){

  local node="$1"; local out

  # mount vol via fstab
  out="$(ssh -oStrictHostKeyChecking=no root@$node "mount $GLUSTER_MNT 2>&1")"
  (( $? != 0 )) && {
    display "ERROR on $node: mount $GLUSTER_MNT: $out" $LOG_FORCE;
    exit 52; }

  display "mount $GLUSTER_MNT: $out" $LOG_DEBUG
  verify_gluster_mnt "$node"  # important for later chmod/chown
}

# create_hadoop_group: on the passed-in node, create the haddop group if it
# does not already exist.
# Args: $1=node (hostname), $2=hadoop group name
#
function create_hadoop_group(){

  local node="$1"; local grp="$2"; local out

  # create hadoop group, if needed
  out="$(ssh -oStrictHostKeyChecking=no root@$node "
	if ! getent group $grp >/dev/null ; then
	  groupadd --system $grp 2>&1 # note: no password
	fi")"
  (( $? != 0 )) && {
    display "ERROR: $node: groupadd $grp: $out" $LOG_FORCE; exit 55; }

  display "groupadd $grp: $out" $LOG_DEBUG
}

# create_hadoop_users: for the passed-in node, create the users needed for
# typical hadoop jobs, if they do not already exist.
# Args: $1=node (hostname), $2=hadoop group name,
#       $3 *name* of array of YARN/MR users
#
function create_hadoop_users(){

  local node="$1"; local grp="$2"; local user_names="$3"
  users=("${!user_names}") # array of user names
  local out; local user

  # create the required M/R-YARN users, if needed
  for user in "${users[@]}" ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	     if ! getent passwd $user >/dev/null ; then
 		useradd --system -g $HADOOP_G $user 2>&1
	     fi")"
      (( $? != 0 )) && {
	display "ERROR: $node: useradd $user: $out" $LOG_FORCE;
	exit 58; }
      display "useradd $user: $out" $LOG_DEBUG
  done
}

# create_hadoop_dirs: from the firstNode, create all the distributed
# directories needed for typical hadoop jobs. Also, assign the correct owners
# and permissions to each directory.
#
function create_hadoop_dirs(){

  local i; local out; local dir; local owner; local perm

  local YARN_NM_REMOTE_APP_LOG_DIR='tmp/logs'
  local MR_JOB_HIST_INTERMEDIATE_DONE='mr-history/tmp'
  local MR_JOB_HIST_DONE='mr-history/done'
  local YARN_STAGE='job-staging-yarn'
  local MR_JOB_HIST_APPS_LOGS='app-logs'

  # the next 3 arrays are all paired
  # note: if a dirname is relative (doesn't start with '/') then the gluster
  #  mount is prepended to it
  local MR_DIRS=("$GLUSTER_MNT" 'mapred' 'mapred/system' 'tmp' 'user' 'mr-history' "$YARN_NM_REMOTE_APP_LOG_DIR" "$MR_JOB_HIST_INTERMEDIATE_DONE" "$MR_JOB_HIST_DONE" "$YARN_STAGE" "$MR_JOB_HIST_APPS_LOGS" 'hbase')
  local MR_PERMS=(0775 0770 0755 1777 0775 0755 1777 1777 0770 0770 1777 0770)
  local MR_OWNERS=("$YARN_U" "$MAPRED_U" "$MAPRED_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$HBASE_U")

  # create all of the M/R-YARN dirs with correct perms and owner
  for (( i=0 ; i<${#MR_DIRS[@]} ; i++ )) ; do
      dir="${MR_DIRS[$i]}"
      # prepend gluster mnt unless dir name is an absolute pathname
      [[ "${dir:0:1}" != '/' ]] && dir="$GLUSTER_MNT/$dir"
      perm="${MR_PERMS[$i]}"
      owner="${MR_OWNERS[$i]}"
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	     mkdir -p $dir 2>&1 \
	     && chmod $perm $dir 2>&1 \
	     && chown $owner:$HADOOP_G $dir 2>&1")"
      (( $? != 0 )) && {
	display "ERROR: $firstNode: mkdir/chmod/chown on $dir: $out" $LOG_FORCE;
	exit 61; }
      display "mkdir/chmod/chown on $dir: $out" $LOG_DEBUG
  done
}

# setup: create a directory, owner, permissions, mounts environment for Hadoop
# jobs. Note that the order below is very important, particualarly creating DFS
# directories and their permissions *after* the mount.
#  1) mkfs.xfs brick_dev
#  2) mkdir brick_dir; mkdir vol_mnt
#  3) append mount entries to fstab
#  4) mount brick
#  5) mkdir mapredlocal scratch dir (must be done after brick mount!)
#  6) create trusted pool
#  7) create vol **
#  8) start vol **
#  9) mount vol
#  10) create the mapred and yarn users, and the hadoop group
#  11) create distributed mapred/system and mr-history/done dirs (must be done
#      after the vol mount) **
#  12) chmod gluster mnt, mapred/system and brick1/mapred scratch dir **
#  13) chown to mapred:hadoop the above **
# ** gluster cmd only done once for entire pool; all other cmds executed on
#    each node
# NOTE: the DO_BITS variable controls which features of setup() are done.
# TODO: limit disk space usage in MapReduce scratch dir so that it does not
#       consume too much of the shared storage space.
#
function setup(){

  local i=0; local node=''; local out; local err; local force=''
  local bricks=''
  local dir; local perm; local owner; local uid
  local HBASE_U='hbase'
  local YARN_U='yarn'; local YARN_UID=502
  # note: all users/owners belong to the hadoop group for now
  local HADOOP_G='hadoop'
  local MAPRED_U='mapred'
  local MR_USERS=("$MAPRED_U" "$YARN_U" "$HBASE_U")

  if (( DO_SETUP_XFS )) ; then
    # 1) mkfs.xfs brick_dev on every node
    # 2) mkdir brick_dir and vol_mnt on every node
    # 3) append brick_dir and gluster mount entries to fstab on every node
    # 4) mount brick on every node
    # 5) mkdir mapredlocal scratch dir on every node (done after brick mount)
    display "  -- on all nodes:"                           $LOG_INFO
    display "       mkfs.xfs on brick-device"              $LOG_INFO
    display "       mkdir $BRICK_DIR, $GLUSTER_MNT and $MAPRED_SCRATCH_DIR..." $LOG_INFO
    display "       append mount entries to /etc/fstab..." $LOG_INFO
    display "       mount $BRICK_DIR..."                   $LOG_INFO
    xfs_brick_dirs_mnt
  fi

  if (( DO_SETUP_VOL )) ;then
    # 6) create trusted pool from first node
    # 7) create vol on a single node
    # 8) start vol on a single node
    # 9) mount vol on every node
    display "  -- on $firstNode node (distributed):"  $LOG_INFO
    display "       creating trusted pool..."         $LOG_INFO
    display "       creating $VOLNAME volume..."      $LOG_INFO
    display "       starting $VOLNAME volume..."      $LOG_INFO
    display "  -- mount $GLUSTER_MNT on all nodes..." $LOG_INFO
    create_trusted_pool
    verify_pool_created

    # create vol
    # first set up bricks string
    for node in "${HOSTS[@]}"; do
        bricks+=" $node:$BRICK_MNT"
    done
    out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume create $VOLNAME replica $REPLICA_CNT $bricks 2>&1")"
    err=$?
    display "vol create: $out" $LOG_DEBUG
    verify_vol_created $err "$bricks"

    # start vol
    for x in {0,1}; do  # 2nd time through use force option
 	(( x != 0 )) && force='force'
	out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
  	      gluster --mode=script volume start $VOLNAME $force 2>&1")"
	err=$?
	display "vol start: $out" $LOG_DEBUG
	verify_vol_started $x $err
	(( $? == 0 )) && break # started on 1st try
    done

    # ownership and permissions must be set *after* the gluster vol is mounted
    for node in "${HOSTS[@]}"; do
	display "-- $node -- mount volume" $LOG_INFO
	mount_volume "$node"
    done
  fi

  if (( DO_SETUP_USERS )) ; then
    # 10) create the mapred and yarn users, and the hadoop group on each node
    display "  -- on all nodes:"                         $LOG_INFO
    display "       create users and group as needed..." $LOG_INFO
    for node in "${HOSTS[@]}"; do
	display "-- $node -- create $HADOOP_G group" $LOG_INFO
	create_hadoop_group "$node" "$HADOOP_G"
    done
    # validate consistent hadoop group GID across cluster
    verify_hadoop_gid "$HADOOP_G"
    # create users
    for node in "${HOSTS[@]}"; do
	display "-- $node -- create users" $LOG_INFO
	create_hadoop_users "$node" "$HADOOP_G" MR_USERS[@] # last arg is *name*
    done
    # validate consistent m/r-yarn user IDs across cluster
    verify_user_uids ${MR_USERS[@]}
  fi

  if (( DO_SETUP_DIRS )) ; then
    # 11) create distributed mapred/system and mr-history/done dirs
    # 12) chmod on the gluster mnt and the mapred scracth dir
    # 13) chown on the gluster mnt and mapred scratch dir
    display "  -- on $firstNode node (distributed):" $LOG_INFO
    display "       create hadoop directories..."    $LOG_INFO
    display "       change owner and permissions..." $LOG_INFO
    create_hadoop_dirs
  fi
}

# install_nodes: for each node in the hosts file copy the "data" sub-directory
# and invoke the companion "prep" script. Some global variables are set here:
#   DEFERRED_REBOOT_NODE = install-from hostname if install-from node needs
#     to be rebooted, else not defined
#   REBOOT_NODES         = array of IPs for all nodes needing to be rebooted,
#     except the install-from node which is handled by DEFERRED_REBOOT_NODE
#
# A node needs may need to be rebooted if a kernel patch is installed. However,
# the node running the install script is not rebooted unless the users says yes.
# 
# Since the server(mgmt) node is known all other nodes are assumed to be 
# storage(agent) nodes. However the management node can also be a storage node.
# Note: in distro-agnostic installs, the prep_node script is passed but may
#   ignore the management node information.
#
function install_nodes(){

  REBOOT_NODES=() # global
  local out; local i; local node; local ip
  local install_mgmt_node; local brick
  local LOCAL_PREP_LOG_DIR='/var/tmp/'
  # list of files to copy to node, exclude devutils/
  local FILES_TO_CP="$(find ./* -path ./devutils -prune -o -print)"


  # prep_node: sub-function which copies the prep_node script and all sub-
  # directories in the tarball to the passed-in node. Then the prep_node.sh
  # script is invoked on the passed-in node to install these files. If prep.sh
  # returns the "reboot-node" error code and the node is not the "install-from"
  # node then the global reboot-needed variable is set. If an unexpected error
  # code is returned then this function exits.
  # Args: $1=hostname, $2=node's ip (can be hostname if ip is unknown),
  #       $3=flag to install storage node, $4=flag to install the mgmt node.
  #       $5=brick-dev (or null)
  #
  function prep_node(){

    local node="$1"; local ip="$2" local install_storage="$3"
    local install_mgmt="$4"; local brick="$5"
    local err
    local ssh_target
    [[ $USING_DNS == true ]] && ssh_target=$node || ssh_target=$ip

    # start with an empty remote install dir
    ssh -oStrictHostKeyChecking=no root@$ssh_target "
	rm -rf $REMOTE_INSTALL_DIR
	mkdir -p $REMOTE_INSTALL_DIR"

    # copy files and dirs to remote install dir via tar and ssh
    # note: scp flattens all files into single target dir, even using -r
    display "-- Copying rhs-hadoop install files to $ssh_target..." $LOG_INFO
    out="$(echo $FILES_TO_CP | xargs tar cf - | \
	   ssh root@$ssh_target tar xf - -C $REMOTE_INSTALL_DIR)"
    err=$?
    display "copy install files: $out" $LOG_DEBUG
    if (( err != 0 )) ; then
      display "ERROR $err: scp install files" $LOG_FORCE
      exit 64
    fi

    # delcare local associative args array, rather than passing separate args
    # note: it's tricky passing an assoc array to a script or function. The
    #   declaration is passed as a string, and the receiving script or function
    #   eval's the arg, but omits the "declare -A name=" substring. Values in
    #   an associative array cannot be arrays or other structures.
    # note: arrays must be escape-quoted.
    # note: prep_node.sh may apply patches which require $node to be rebooted
    declare -A PREP_ARGS=([BRICK_DEV]="$brick" [NODE]="$node" \
	[INST_STORAGE]="$install_storage" [INST_MGMT]="$install_mgmt" \
	[MGMT_NODE]="$MGMT_NODE" [VERBOSE]="$VERBOSE" \
	[PREP_LOG]="$PREP_NODE_LOG_PATH" [REMOTE_DIR]="$REMOTE_INSTALL_DIR" \
	[USING_DNS]=$USING_DNS)
    out="$(ssh -oStrictHostKeyChecking=no root@$ssh_target $REMOTE_PREP_SH \
        "\"$(declare -p PREP_ARGS)\"" "\"${HOSTS[@]}\"" \ "\"${HOST_IPS[@]}\""
	)"
    err=$?
    # prep_node writes all messages to the PREP_NODE_LOG logfile regardless of
    # the verbose setting. However, it outputs (and is captured above) only
    # messages that honor the verbose setting. We can't call display() next
    # because we don't want to double log, so instead, append the entire
    # PREP_NODE_LOG file to LOGFILE and echo the contents of $out.
    scp -q root@$ssh_target:$PREP_NODE_LOG_PATH $LOCAL_PREP_LOG_DIR
    cat ${LOCAL_PREP_LOG_DIR}$PREP_NODE_LOG >> $LOGFILE
    echo "$out" # prep_node.sh has honored the verbose setting

    if (( err == 99 )) ; then # this node needs to be rebooted
      # don't reboot if node is the install-from node!
      if [[ "$ip" == "$INSTALL_FROM_IP" ]] ; then
        DEFERRED_REBOOT_NODE="$node"
      else
	REBOOT_NODES+=("$node")
      fi
    elif (( err != 0 )) ; then # fatal error in install.sh so quit now
      display " *** ERROR! prep_node script exited with error: $err ***" \
	$LOG_FORCE
      exit 67
    fi
  }

  # main #
  #      #
  for (( i=0; i<$NUMNODES; i++ )); do
      node=${HOSTS[$i]}; ip=${HOST_IPS[$i]}
      [[ -n "$BRICK_DEV" ]] && brick="$BRICK_DEV" || brick="${BRICKS[$i]}"
      echo
      display
      display '--------------------------------------------' $LOG_SUMMARY
      display "-- Installing on $node ($ip)"                 $LOG_SUMMARY
      display '--------------------------------------------' $LOG_SUMMARY
      display
      install_mgmt_node=false
      [[ -n "$MGMT_NODE_IN_POOL" && "$node" == "$MGMT_NODE" ]] && \
	install_mgmt_node=true
      prep_node $node $ip true $install_mgmt_node $brick

      display '-------------------------------------------------' $LOG_SUMMARY
      display "-- Done installing on $node ($ip)"                 $LOG_SUMMARY
      display '-------------------------------------------------' $LOG_SUMMARY
  done

  # if the mgmt node is not in the storage pool (not in hosts file) then
  # execute prep_node again in case there are management specific tasks.
  if [[ -z "$MGMT_NODE_IN_POOL" ]] ; then
    echo
    display 'Management node is not a datanode thus mgmt code needs to be installed...' $LOG_INFO
    display "-- Starting install of management node \"$MGMT_NODE\"" $LOG_DEBUG
    prep_node $MGMT_NODE $MGMT_NODE false true null # (no brick)
  fi
}

# reboot_nodes: if one or more nodes needs to be rebooted, perhaps due to
# installing a kernel level patch, then they are rebooted here. Note: if the
# "install-from" node also needs to be rebooted that node does not exist in the
# REBOOT_NODES array, and is handled separately (see the DEFERRED_REBOOT_NODE
# global variable).
#
function reboot_nodes(){

  local node; local i; local msg
  local num=${#REBOOT_NODES[@]} # number of nodes to reboot

  (( num <= 0 )) && return # no nodes to reboot

  echo
  msg='node'
  (( num != 1 )) && msg+='s'
  display "-- $num $msg will be rebooted..." $LOG_SUMMARY
  for node in "${REBOOT_NODES[@]}"; do
      display "   * rebooting node: $node..." $LOG_INFO
      ssh -oStrictHostKeyChecking=no root@$node "reboot && exit"
  done

  # makes sure all rebooted nodes are back up before returning
  while true ; do
      for i in "${!REBOOT_NODES[@]}"; do # array of non-null element indices
	  node=${REBOOT_NODES[$i]}       # unset leaves sparse array
	  # if possible to ssh to node then unset that array entry
	  ssh -q -oBatchMode=yes -oStrictHostKeyChecking=no root@$node exit
	  if (( $? == 0 )) ; then
	    display "   * node $node sucessfully rebooted" $LOG_DEBUG
	    unset REBOOT_NODES[$i] # null entry in array
	  fi
      done
      (( ${#REBOOT_NODES[@]} == 0 )) && break # exit loop
      sleep 10
  done
}

# perf_config: assign the non-default gluster volume attributes below.
#
function perf_config(){

  local out; local err

  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume set $VOLNAME quick-read off 2>&1
	gluster volume set $VOLNAME cluster.eager-lock on 2>&1
	gluster volume set $VOLNAME performance.stat-prefetch off 2>&1")"
  err=$?
  display "gluster perf: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "WARN: gluster performance config error $err" $LOG_FORCE
  fi
}

# reboot_self: invoked when the install-from node (self) is also one of the
# storage nodes. In this case the reboot of the storage node (needed to 
# complete kernel patch installation) has been deferred -- until now.
# The user may be prompted to confirm the reboot of their node.
#
function reboot_self(){

  local ans='y'

  echo "*** Your system ($(hostname -s)) needs to be rebooted to complete the"
  echo "    installation of one or more kernel patches."
  [[ "$ANS_YES" == 'n' ]] && read -p "    Reboot now? [y|N] " ans
  case $ans in
    y|yes|Y|YES|Yes)
	display "*** REBOOTING self..." $LOG_INFO
	reboot
    ;;
    *)  exit 0
  esac
  echo "No reboot! You must reboot your system prior to running Hadoop jobs."
}


## ** main ** ##
##            ##
echo

# flag if we're doing an rhs related install, set before parsing args
[[ -d glusterfs ]] && RHS_INSTALL=false || RHS_INSTALL=true

# global bit mask indicating which steps to do, default is all
DO_BITS=0xffff

parse_cmd $@

display "$(date). Begin: $SCRIPT -- version $INSTALL_VER ***" $LOG_REPORT

echo
display "-- Verifying deployment environment, including the \"hosts\" file format:" $LOG_INFO
verify_local_deploy_setup

# since a brick-dev is optional in the local hosts file, verify that we either
# have a brick-dev cmdline arg, or we have bricks in the hosts file, but not
# both
if [[ -z "$BRICK_DEV" && ${#BRICKS} == 0 ]] ; then
  display "ERROR: a brick device path is required either as an arg to $SCRIPT or in\nthe local $HOSTS_FILE hosts file" $LOG_FORCE
  exit -1
elif [[ -n "$BRICK_DEV" && ${#BRICKS}>0 ]] ; then
  display "ERROR: a brick device path can be provided either as an arg to $SCRIPT or\nin the local $HOSTS_FILE hosts file, but not in both" $LOG_FORCE
  exit -1
fi

# convention is to use the volname as the subdir under the brick as the mnt
BRICK_MNT=$BRICK_DIR/$VOLNAME
MAPRED_SCRATCH_DIR="$BRICK_DIR/mapredlocal" # xfs but not distributed
firstNode=${HOSTS[0]}

# set DO_xxx globals based on DO_BITS
let "DO_REPORT=(((DO_BITS>>REPORT_BIT) % 2))" # 1 --> do it
let "DO_INSTALL=(((DO_BITS>>INSTALL_BIT) % 2))"
let "DO_CLEAN=(((DO_BITS>>CLEAN_BIT) % 2))"
let "DO_SETUP=(((DO_BITS>>SETUP_BIT) % 2))" # 0 --> defeats all setup tasks
let "DO_SETUP_XFS=(((DO_BITS>>SETUP_XFS_BIT) % 2))"
let "DO_SETUP_VOL=(((DO_BITS>>SETUP_VOL_BIT) % 2))"
let "DO_SETUP_USERS=(((DO_BITS>>SETUP_USERS_BIT) % 2))"
let "DO_SETUP_DIRS=(((DO_BITS>>SETUP_DIRS_BIT) % 2))"
let "DO_PERF=(((DO_BITS>>PERF_BIT) % 2))"

(( DO_REPORT )) && report_deploy_values

# per-node install and config...
(( DO_INSTALL )) && install_nodes

echo
display '----------------------------------------' $LOG_SUMMARY
display '--    Begin cluster configuration     --' $LOG_SUMMARY
display '----------------------------------------' $LOG_SUMMARY
echo

# clean up mounts and volume from previous run, if any...
if (( DO_CLEAN )) ; then
  display "-- Cleaning up (un-mounting, deleting volume, etc.)" $LOG_SUMMARY
  cleanup
fi

# set up mounts and create volume
echo
if (( DO_SETUP )) ; then
  display "-- Setting up brick and volume mounts, creating and starting volume" $LOG_SUMMARY
  setup
fi

echo
if (( DO_PERF )) ; then
  display "-- Performance config..." $LOG_SUMMARY
  perf_config
fi

# reboot nodes if needed
(( DO_INSTALL )) && reboot_nodes

echo
display "**** This script can be re-run anytime! ****" $LOG_REPORT
echo
display "$(date). End: $SCRIPT" $LOG_REPORT
echo

# if install-from node is one of the data nodes and a kernel patch was
# installed on that data node, then the reboot of the node was deferred but
# can be done now.
[[ -n "$DEFERRED_REBOOT_NODE" ]] && reboot_self
exit 0
#
# end of script
