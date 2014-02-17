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
INSTALL_VER='0.67'   # self version
INSTALL_DIR=$PWD     # name of deployment (install-from) dir
INSTALL_FROM_IP=($(hostname -I))
INSTALL_FROM_IP=${INSTALL_FROM_IP[$(( ${#INSTALL_FROM_IP[@]}-1 ))]} # last ntry
REMOTE_INSTALL_DIR="/tmp/rhs-hadoop-install/" # on each node
# companion install script name
PREP_SH='prep_node.sh' # companion script run on each node
REMOTE_PREP_SH="$REMOTE_INSTALL_DIR$PREP_SH" # full path
NUMNODES=0           # number of nodes in hosts file (= trusted pool size)
bricks=''            # string list of node:/brick-mnts for volume create
# local logfile on each host, copied from remote host to install-from host
PREP_NODE_LOG='prep_node.log'
PREP_NODE_LOG_PATH="${REMOTE_INSTALL_DIR}$PREP_NODE_LOG"

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
           brick-dev

EOF
}

# usage: write full usage/help text to stdout.
#
function usage(){

  cat <<EOF

Usage:

Prepares a glusterfs volume for Hadoop workloads. Note that hadoop itself is not
installed by these scripts. The user is expected to install hadoop separately.
Each node in the storage cluster must be defined in the "hosts" file. The
"hosts" file is not included and must be created prior to running this script.
The "hosts" file format is:
   hostname  host-ip-address
repeated one host per line in replica pair order. See the "hosts.example"
sample hosts file for more information.
  
The required brick-dev argument names the brick device where the XFS file
system will be mounted. Examples include: /dev/<VGname>/<LVname> or /dev/vdb1,
etc. The brick-dev names a RAID6 storage partition dedicated for RHS. Optional
arguments can specify the RHS volume name and mount point, brick mount point,
etc.
EOF
  short_usage
  cat <<EOF
  brick-dev          : (required) Brick device location/directory where the
                       XFS file system is created. Eg. /dev/vgName/lvName.
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

# parse_cmd: getopt is used to do general parsing. The brick-dev arg is
# required. The remaining parms are optional. See usage function for syntax. 
# The RHS_INSTALL variable must be set prior to calling this function.
# Note: since the logfile path is an option, parsing errors may be written to
#   the default logfile rather than the user-defined logfile, depending on when
#   the error occurs.
#
function parse_cmd(){

  local OPTIONS='vhqy'
  local LONG_OPTS='brick-mnt:,vol-name:,vol-mnt:,replica:,hosts:,mgmt-node:,logfile:,verbose::,help,version,quiet,debug'

  # defaults (global variables)
  BRICK_DIR='/mnt/brick1'
  VOLNAME='HadoopVol'
  GLUSTER_MNT='/mnt/glusterfs'
  REPLICA_CNT=2
  NEW_DEPLOY=true
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
	--)  # no more args to parse
	    shift; break
	;;
      esac
  done

  eval set -- "$@" # move arg pointer so $1 points to next arg past last opt
  (( $# == 0 )) && {
        echo "Brick device parameter is required"; short_usage; exit -1; }
  (( $# > 1 )) && {
        echo "Too many parameters: $@"; short_usage; exit -1; }

  # the brick dev is the only required parameter
  BRICK_DEV="$1"

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
  local OS; local RHS

  # report_gluster_versions: sub-function to report either the common gluster
  # version across all nodes, or to list each node and its gluster version.
  #
  function report_gluster_versions(){

    local i; local vers; local node
    local node_vers=(); local uniq_vers=()

    for (( i=0; i<$NUMNODES; i++ )); do
	node="${HOSTS[$i]}"
	vers="$(ssh root@$node 'gluster --version|head -n 1')"
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

  display
  display "OS:                   $OS" $LOG_REPORT
  [[ -n "$RHS" ]] &&
    display "RHS:                  $RHS" $LOG_REPORT
  report_gluster_versions
  
  display
  display "---------- Deployment Values ----------" $LOG_REPORT
  display "  Install-from dir:   $INSTALL_DIR"      $LOG_REPORT
  display "  Install-from IP:    $INSTALL_FROM_IP"  $LOG_REPORT
  display "  Included sub-dirs:  $SUBDIRS"          $LOG_REPORT
  display "  Remote install dir: $REMOTE_INSTALL_DIR"  $LOG_REPORT
  display "  \"hosts\" file:       $HOSTS_FILE"     $LOG_REPORT
  display "  Using DNS:          $USING_DNS"        $LOG_REPORT
  display "  Number of nodes:    $NUMNODES"         $LOG_REPORT
  display "  Management node:    $MGMT_NODE"        $LOG_REPORT
  display "  Volume name:        $VOLNAME"          $LOG_REPORT
  display "  # of replicas:      $REPLICA_CNT"      $LOG_REPORT
  display "  Volume mount:       $GLUSTER_MNT"      $LOG_REPORT
  display "  XFS device file:    $BRICK_DEV"        $LOG_REPORT
  display "  XFS brick dir:      $BRICK_DIR"        $LOG_REPORT
  display "  XFS brick mount:    $BRICK_MNT"        $LOG_REPORT
  display "  M/R scratch dir:    $MAPRED_SCRATCH_DIR"  $LOG_REPORT
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
	exit 2
      fi
      # extract gid, "hadoop:x:<gid>", eg hadoop:x:500;
      gid=${out%:}   # delete trailing colon
      gid=${gid##*:} # extract gid
      gids+=($gid)
  done

  uniq_gids=($(printf '%s\n' "${gids[@]}" | sort -u))
  if (( ${#uniq_gids[@]} > 1 )) ; then
    display "ERROR: \"$grp\" group has inconsistent GIDs across the cluster. $grp GIDs: ${uniq_gids[*]}" $LOG_FORCE
    exit 3
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
	  exit 4
	fi
	uids+=($out)
     done

     uniq_uids=($(printf '%s\n' "${uids[@]}" | sort -u))
     if (( ${#uniq_uids[@]} > 1 )) ; then
       display "ERROR: \"$user\" user has inconsistent UIDs across cluster. $user UIDs: ${uniq_uids[*]}" $LOG_FORCE
       exit 5
     fi
  done
}

# verify_peer_detach: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that the number of nodes in
# the trusted pool is zero, or a predefined number of attempts have been made.
#
function verify_peer_detach(){

  local out; local i=0; local SLEEP=2; local LIMIT=$((NUMNODES * 2))

  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode \
	"gluster peer status")" # "Number of Peers: x"
      [[ $? == 0 && -n "$out" && ${out##*: } == 0 ]] && break
      sleep $SLEEP 
      ((i++))
      display "...verify peer detatch wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Trusted pool detached..." $LOG_DEBUG
  else
    display "   ERROR: Trusted pool NOT detached..." $LOG_FORCE
    exit 6
  fi
}

# verify_pool_create: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that the number of nodes in
# the trusted pool equals the expected number, or a predefined number of 
# attempts have been made.
#
function verify_pool_created(){

  local DESIRED_STATE="Peer in Cluster (Connected)"
  local out; local i=0; local SLEEP=2; local LIMIT=$((NUMNODES * 2))

  while (( i < LIMIT )) ; do # don't loop forever
      # out contains lines where the state != desired state, == problem
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode \
	   gluster peer status|grep 'State: ')"
      if [[ -n "$out" ]] ; then # have all State: lines else unexpected output
        out="$(grep -v "$DESIRED_STATE" <<<$out)"
        [[ -z "$out" ]] && break # empty -> all nodes in desired state
      fi
      sleep $SLEEP 
      ((i++))
      display "...verify pool create wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Trusted pool formed..." $LOG_DEBUG
  else
    display "   ERROR: Trusted pool NOT formed..." $LOG_FORCE
    exit 7
  fi
}

# verify_vol_created: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that $VOLNAME has been
# created, or a pre-defined number of attempts have been made.
# $1=exit return from gluster vol create command.
#
function verify_vol_created(){

  local volCreateErr=$1
  local i=0; local SLEEP=2; local LIMIT=$((NUMNODES * 5))

  while (( i < LIMIT )) ; do # don't loop forever
      ssh -oStrictHostKeyChecking=no root@$firstNode \
	"gluster volume info $VOLNAME >& /dev/null"
      (( $? == 0 )) && break
      sleep $SLEEP
      ((i++))
      display "...verify vol create wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume \"$VOLNAME\" created..." $LOG_DEBUG
  else
    display "   ERROR: Volume \"$VOLNAME\" creation failed with error $volCreateErr" $LOG_FORCE
    display "          Bricks=\"$bricks\"" $LOG_FORCE
    exit 8
  fi
}

# verify_vol_started: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that $VOLNAME has been
# started, or a pre-defined number of attempts have been made. A volume is
# considered started once all bricks are online.
# $1=exit return from gluster vol start command.
#
function verify_vol_started(){

  local volStartErr=$1
  local i=0; local rtn; local SLEEP=2; local LIMIT=$((NUMNODES * 2))
  local FILTER='^Online' # grep filter
  local ONLINE=': Y'     # grep not-match value

  while (( i < LIMIT )) ; do # don't loop forever
      # grep for Online status != Y
      rtn="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume status $VOLNAME detail 2>/dev/null |
	 	grep $FILTER |
		grep -v '$ONLINE' |
		wc -l
	")"
      (( rtn == 0 )) && break # exit loop
      sleep $SLEEP
      ((i++))
      display "...verify vol start wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume \"$VOLNAME\" started..." $LOG_DEBUG
  else
    display "   ERROR: Volume \"$VOLNAME\" start failed with error $volStartErr" $LOG_FORCE
    exit 9
  fi
}

# verify_gluster_mnt: given the passed in node, verify that the glusterfs
# mount succeeded. This mount is important for the subsequent chmod and chown
# on the gluster mount dir to work.
function verify_gluster_mnt(){

  local node=$1 # required
  local out

  out="$(ssh -oStrictHostKeyChecking=no root@$node \
	"grep $GLUSTER_MNT /proc/mounts 2>&1")"
  if (( $? != 0 )) ; then
    display "ERROR: $GLUSTER_MNT *NOT* mounted" $LOG_FORCE
    exit 10
  fi
  display "$GLUSTER_MNT mounted: $out" $LOG_DEBUG
}

# cleanup:
# 1) umount vol if mounted
# 2) stop vol if started **
# 3) delete vol if created **
# 4) detach nodes if trusted pool created
# 5) kill gluster processes and delete gluster log files
# 6) rm vol_mnt
# 7) unmount brick_mnt if xfs mounted
# 8) rm brick_mnt; rm mapred scratch dir
# ** gluster cmd only done once for entire pool; all other cmds executed on
#    each node
#
function cleanup(){

  local node=''; local out

  # 0) start glusterd service in case it's been stopped. Needed for detach
  service glusterd start >& /dev/null

  # 1) umount vol on every node, if mounted
  display "  -- un-mounting $GLUSTER_MNT on all nodes..." $LOG_INFO
  for node in "${HOSTS[@]}"; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
          if grep -qs $GLUSTER_MNT /proc/mounts ; then
            umount $GLUSTER_MNT
          fi")"
      [[ -n "$out" ]] && display "$node: umount: $out" $LOG_DEBUG
  done

  # 2) stop vol on a single node, if started
  # 3) delete vol on a single node, if created
  display "  -- from node $firstNode:"         $LOG_INFO
  display "       stopping $VOLNAME volume..." $LOG_INFO
  display "       deleting $VOLNAME volume..." $LOG_INFO
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
      gluster volume status $VOLNAME >& /dev/null
      if (( \$? == 0 )); then # assume volume started
        gluster --mode=script volume stop $VOLNAME 2>&1
      fi
      gluster volume info $VOLNAME >& /dev/null
      if (( \$? == 0 )); then # assume volume created
        gluster --mode=script volume delete $VOLNAME 2>&1
      fi
  ")"
  display "vol stop/delete: $out" $LOG_DEBUG

  # 4) detach nodes if trusted pool created, on all but first node
  display "       detach all nodes..."   $LOG_INFO
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode \
	"gluster peer status|head -n 1")"
  # detach nodes if a pool has been already been formed
  if [[ -n "$out" && ${out##* } > 0 ]] ; then # got output, last tok=# peers
    display "  -- from node $firstNode:" $LOG_INFO
    display "       detaching all other nodes from trusted pool..." $LOG_INFO
    out=''
    for (( i=1; i<$NUMNODES; i++ )); do
      out+="$(ssh -oStrictHostKeyChecking=no root@$firstNode \
	"gluster peer detach ${HOSTS[$i]} 2>&1")"
      out+="\n"
    done
    display "peer detach: $out" $LOG_DEBUG
    verify_peer_detach
  fi

  # 5) kill gluster processes and delete gluster log files
  display "Kill gluster processes..."   $LOG_INFO
  display "Delete gluster log files..." $LOG_INFO
  killall glusterd glusterfs glusterfsd 2>/dev/null # no error handling yet...
  rm -rf /var/log/glusterfs/*

  # 6) rm vol_mnt on every node
  # 7) unmount brick_mnt on every node, if xfs mounted
  # 8) rm brick_mnt and mapred scratch dir on every node
  display "  -- on all nodes:"          $LOG_INFO
  display "       rm $GLUSTER_MNT..."   $LOG_INFO
  display "       umount $BRICK_DIR..." $LOG_INFO
  display "       rm $BRICK_DIR..."     $LOG_INFO
  out=''
  for node in "${HOSTS[@]}"; do
      out+="$(ssh -oStrictHostKeyChecking=no root@$node "
          rm -rf $GLUSTER_MNT 2>&1
          if grep -qs $BRICK_DIR /proc/mounts ; then
            umount $BRICK_DIR 2>&1
          fi
          rm -rf $BRICK_DIR 2>&1
      ")"
      out+="\n"
  done
  display "rm vol_mnt, umount brick, rm brick: $out" $LOG_DEBUG
}

# create_trusted_pool: create the trusted storage pool. No error if the pool
# already exists.
#
function create_trusted_pool(){

  local out; local i

  # note: peer probe hostname cannot be self node
  out=''
  for (( i=1; i<$NUMNODES; i++ )); do # starting at 1, not 0
      out+="$(ssh -oStrictHostKeyChecking=no root@$firstNode \
	"gluster peer probe ${HOSTS[$i]} 2>&1")"
      out+="\n"
  done
  display "peer probe: $out" $LOG_DEBUG

  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode \
	'gluster peer status 2>&1')"
  display "peer status: $out" $LOG_DEBUG
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
#  10) create distributed mapred/system and mr-history/done dirs (must be done
#      after the vol mount)
#  11) create the mapred and yarn users, and the hadoop group
#  12) chmod gluster mnt, mapred/system and brick1/mapred scratch dir
#  13) chown to mapred:hadoop the above
# ** gluster cmd only done once for entire pool; all other cmds executed on
#    each node
# TODO: limit disk space usage in MapReduce scratch dir so that it does not
#       consume too much of the shared storage space.
#
function setup(){

  local i=0; local node=''; local ip; local out; local err
  local BRICK_MNT_OPTS="noatime,inode64"
  local GLUSTER_MNT_OPTS="entry-timeout=0,attribute-timeout=0,use-readdirp=no,acl,_netdev"
  local dir; local perm; local owner
  local user; local uid
  # note: all users/owners belong to the hadoop group for now
  local HADOOP_G='hadoop'
  local MAPRED_U='mapred'
  local HBASE_U='hbase'
  local YARN_U='yarn'; local YARN_UID=502
  local MR_USERS=("$MAPRED_U" "$YARN_U" "$HBASE_U")
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

  # 0) start glusterd service
  # 1) mkfs.xfs brick_dev on every node
  # 2) mkdir brick_dir and vol_mnt on every node
  # 3) append brick_dir and gluster mount entries to fstab on every node
  # 4) mount brick on every node
  # 5) mkdir mapredlocal scratch dir on every node (done after brick mount)
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode service glusterd start)"
  err=$?
  if (( err != 0 )) ; then
    display "ERROR $err: cannot start glusterd: $out" $LOG_FORCE
    exit 11
  fi

  display "  -- on all nodes:"                           $LOG_INFO
  display "       mkfs.xfs $BRICK_DEV..."                $LOG_INFO
  display "       mkdir $BRICK_DIR, $GLUSTER_MNT and $MAPRED_SCRATCH_DIR..." $LOG_INFO
  display "       append mount entries to /etc/fstab..." $LOG_INFO
  display "       mount $BRICK_DIR..."                   $LOG_INFO
  out=''
  for (( i=0; i<$NUMNODES; i++ )); do
      node="${HOSTS[$i]}"
      ip="${HOST_IPS[$i]}"

      # mkfs.xfs
      out="$(ssh -oStrictHostKeyChecking=no root@$node \
	"mkfs -t xfs -i size=512 -f $BRICK_DEV 2>&1")"
      (( $? != 0 )) && {
        display "ERROR: $node: mkfs.xfs: $out" $LOG_FORCE; exit 12; }
      display "mkfs.xfs: $out" $LOG_DEBUG

      # use volname dir under brick by convention
      out="$(ssh -oStrictHostKeyChecking=no root@$node \
	"mkdir -p $BRICK_MNT 2>&1")"
      (( $? != 0 )) && {
        display "ERROR: $node: mkdir $BRICK_MNT: $out" $LOG_FORCE; exit 13; }
      display "mkdir $BRICK_MNT: $out" $LOG_DEBUG

      # make vol mnt dir
      out="$(ssh -oStrictHostKeyChecking=no root@$node \
        "mkdir -p $GLUSTER_MNT 2>&1")"
      (( $? != 0 )) && {
        display "ERROR: $node: mkdir $GLUSTER_MNT: $out" $LOG_FORCE; exit 14; }
      display "mkdir $GLUSTER_MNT: $out" $LOG_DEBUG

      # append brick and gluster mounts to fstab
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
        if ! grep -qs $BRICK_DIR /etc/fstab ; then
          echo '$BRICK_DEV $BRICK_DIR xfs  $BRICK_MNT_OPTS  0 0' >>/etc/fstab
        fi
        if ! grep -qs $GLUSTER_MNT /etc/fstab ; then
          echo '$node:/$VOLNAME  $GLUSTER_MNT  glusterfs  $GLUSTER_MNT_OPTS \
		0 0' >>/etc/fstab
        fi")"
      (( $? != 0 )) && {
        display "ERROR: $node: append fstab: $out" $LOG_FORCE; exit 15; }
      display "append fstab: $out" $LOG_DEBUG

      # Note: mapred scratch dir must be created *after* the brick is
      # mounted; otherwise, mapred dir will be "hidden" by the mount.
      # Also, permissions and owner must be set *after* the gluster dir 
      # is mounted for the same reason -- see below.
      out="$(ssh -oStrictHostKeyChecking=no root@$node \
	"mount $BRICK_DIR 2>&1")" # mount via fstab
      (( $? != 0 )) && {
        display "ERROR: $node: mount $BRICK_DIR: $out" $LOG_FORCE; exit 16; }
      display "append fstab: $out" $LOG_DEBUG

      out="$(ssh -oStrictHostKeyChecking=no root@$node \
	"mkdir -p $MAPRED_SCRATCH_DIR 2>&1")"
      (( $? != 0 )) && {
        display "ERROR: $node: mkdir $MAPRED_SCRATCH_DIR: $out" $LOG_FORCE;
        exit 17; }
      display "mkdir $MAPRED_SCRATCH_DIR: $out" $LOG_DEBUG
  done

  # 6) create trusted pool from first node
  # 7) create vol on a single node
  # 8) start vol on a single node
  display "  -- from node $firstNode:"         $LOG_INFO
  display "       creating trusted pool..."    $LOG_INFO
  display "       creating $VOLNAME volume..." $LOG_INFO
  display "       starting $VOLNAME volume..." $LOG_INFO
  create_trusted_pool
  verify_pool_created

  # create vol
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume create $VOLNAME replica $REPLICA_CNT $bricks 2>&1")"
  err=$?
  display "vol create: $out" $LOG_DEBUG
  verify_vol_created $err

  # start vol
  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster --mode=script volume start $VOLNAME 2>&1")"
  err=$?
  display "vol start: $out" $LOG_DEBUG
  verify_vol_started $err

  # 9) mount vol on every node
  # 10) create distributed mapred/system and mr-history/done dirs on each node
  # 11) create the mapred and yarn users, and the hadoop group on each node
  # 12) chmod on the gluster mnt and the mapred scracth dir on every node
  # 13) chown on the gluster mnt and mapred scratch dir on every node
  display "  -- on all nodes:"                      $LOG_INFO
  display "       mount $GLUSTER_MNT..."            $LOG_INFO
  display "       create M/R directories..."        $LOG_INFO
  display "       create users and group as needed..." $LOG_INFO
  display "       change owner and permissions..."  $LOG_INFO
  # Note: ownership and permissions must be set *afer* the gluster vol is
  #       mounted.
  for node in "${HOSTS[@]}"; do
      display "-- $node -- mount vol and create $HADOOP_G group" $LOG_INFO

      # mount vol via fstab
      out="$(ssh -oStrictHostKeyChecking=no root@$node \
		"mount $GLUSTER_MNT 2>&1")" # from fstab
      (( $? != 0 )) && {
	display "ERROR: $node: mount $GLUSTER_MNT: $out" $LOG_FORCE;
	exit 21; }
      display "mount $GLUSTER_MNT: $out" $LOG_DEBUG
      verify_gluster_mnt $node  # important for chmod/chown below

      # create hadoop group, if needed
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
        if ! getent group $HADOOP_G >/dev/null ; then
          groupadd --system $HADOOP_G 2>&1 # note: no password
        fi")"
      (( $? != 0 )) && {
	display "ERROR: $node: groupadd $HADOOP_G: $out" $LOG_FORCE; exit 23; }
      display "groupadd $HADOOP_G: $out" $LOG_DEBUG
  done

  # validate consistent hadoop group GID across cluster
  verify_hadoop_gid "$HADOOP_G"

  for node in "${HOSTS[@]}"; do
      display "-- $node -- create users" $LOG_INFO

      # create the required M/R-YARN users, if needed
      for user in "${MR_USERS[@]}" ; do
	out="$(ssh -oStrictHostKeyChecking=no root@$node "
		if ! getent passwd $user >/dev/null ; then
 		  useradd --system -g $HADOOP_G $user 2>&1
		fi
	       ")"
	(( $? != 0 )) && {
	  display "ERROR: $node: useradd $user: $out" $LOG_FORCE;
	  exit 25; }
	display "useradd $user: $out" $LOG_DEBUG
      done
  done

  # validate consistent m/r-yarn user IDs across cluster
  verify_user_uids ${MR_USERS[@]}

  for node in "${HOSTS[@]}"; do
      display "-- $node -- create hadoop directories" $LOG_INFO

      # create all of the M/R-YARN dirs with correct perms and owner
      for (( i=0 ; i<${#MR_DIRS[@]} ; i++ )) ; do
	dir="${MR_DIRS[$i]}"
	# prepend gluster mnt unless dir name is an absolute pathname
	[[ "${dir:0:1}" != '/' ]] && dir="$GLUSTER_MNT/$dir"
	perm="${MR_PERMS[$i]}"
	owner="${MR_OWNERS[$i]}"
	out="$(ssh -oStrictHostKeyChecking=no root@$node "
		mkdir -p $dir 2>&1     && \
		chmod $perm $dir 2>&1  && \
		chown $owner:$HADOOP_G $dir 2>&1
	       ")"
	(( $? != 0 )) && {
	  display "ERROR: $node: mkdir/chmod/chown on $dir: $out" $LOG_FORCE;
	  exit 27; }
	display "mkdir/chmod/chown on $dir: $out" $LOG_DEBUG
      done
  done
}

# install_nodes: for each node in the hosts file copy the "data" sub-directory
# and invoke the companion "prep" script. Some global variables are set here:
#   bricks               = string of all bricks (ip/dir)
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

  local i; local node; local ip; local install_mgmt_node
  local LOCAL_PREP_LOG_DIR='/var/tmp/'; local out
  local FILES_TO_CP="$PREP_SH functions $SUBDIRS"
  REBOOT_NODES=() # global

  # prep_node: sub-function which copies the prep_node script and all sub-
  # directories in the tarball to the passed-in node. Then the prep_node.sh
  # script is invoked on the passed-in node to install these files. If prep.sh
  # returns the "reboot-node" error code and the node is not the "install-from"
  # node then the global reboot-needed variable is set. If an unexpected error
  # code is returned then this function exits.
  # Args: $1=hostname, $2=node's ip (can be hostname if ip is unknown),
  #       $3=flag to install storage node, $4=flag to install the mgmt node.
  #
  function prep_node(){

    local node="$1"; local ip="$2"
    local install_storage="$3"; local install_mgmt="$4"
    local err; local ssh_target
    [[ $USING_DNS == true ]] && ssh_target=$node || ssh_target=$ip

    ssh -oStrictHostKeyChecking=no root@$ssh_target "
	rm -rf $REMOTE_INSTALL_DIR
	mkdir -p $REMOTE_INSTALL_DIR"
    display "-- Copying rhs-hadoop install files..." $LOG_INFO
    out="$(scp -r $FILES_TO_CP root@$ssh_target:$REMOTE_INSTALL_DIR)"
    err=$?
    display "copy install files: $out" $LOG_DEBUG
    if (( err != 0 )) ; then
      display "ERROR: scp install files error $err" $LOG_FORCE
      exit 35
    fi

    # delcare local associative args array, rather than passing separate args
    # note: it's tricky passing an assoc array to a script or function. The
    #  declaration is passed as a string, and the receiving script or function
    #  eval's the arg, but omits the "declare -A name=" substring. The 2 arrays
    #  are also a bit tricky to pass and receive. And remember values in an
    #  associative array cannot be arrays or other structures.
    # note: prep_node.sh may apply patches which require $node to be rebooted
    declare -A PREP_ARGS=([BRICK_DEV]="$BRICK_DEV" [NODE]="$node" \
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
      exit 37
    fi
  }

  # main #
  #      #
  for (( i=0; i<$NUMNODES; i++ )); do
      node=${HOSTS[$i]}; ip=${HOST_IPS[$i]}
      echo
      display
      display '--------------------------------------------' $LOG_SUMMARY
      display "-- Installing on $node ($ip)"                 $LOG_SUMMARY
      display '--------------------------------------------' $LOG_SUMMARY
      display

      # Append to bricks string. Convention to use a subdir under the XFS
      # brick, and to name this subdir the same as the volname.
      bricks+=" $node:$BRICK_MNT"

      install_mgmt_node=false
      [[ -n "$MGMT_NODE_IN_POOL" && "$node" == "$MGMT_NODE" ]] && \
	install_mgmt_node=true
      prep_node $node $ip true $install_mgmt_node

      display '-------------------------------------------------' $LOG_SUMMARY
      display "-- Done installing on $node ($ip)"                 $LOG_SUMMARY
      display '-------------------------------------------------' $LOG_SUMMARY
  done

  # if the mgmt node is not in the storage pool (not in hosts file) then
  # we  need to copy the management rpm to the mgmt node and install the
  # management server
  if [[ -z "$MGMT_NODE_IN_POOL" ]] ; then
    echo
    display 'Management node is not a datanode thus mgmt code needs to be installed...' $LOG_INFO
    display "-- Starting install of management node \"$MGMT_NODE\"" $LOG_DEBUG
    prep_node $MGMT_NODE $MGMT_NODE false true
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

parse_cmd $@

display "$(date). Begin: $SCRIPT -- version $INSTALL_VER ***" $LOG_REPORT

# define global variables based on --options and defaults
# convention is to use the volname as the subdir under the brick as the mnt
BRICK_MNT=$BRICK_DIR/$VOLNAME
MAPRED_SCRATCH_DIR="$BRICK_DIR/mapredlocal" # xfs but not distributed

# capture all sub-directories that are related to the install
SUBDIRS="$(find ./* -type d -not -path "*/devutils")" # exclude devutils/
SUBDIRS=${SUBDIRS//$'\n'/ } # replace newline with space

echo
display "-- Verifying the deploy environment, including the \"hosts\" file format:" $LOG_INFO
verify_local_deploy_setup
firstNode=${HOSTS[0]}

report_deploy_values

# per-node install and config...
install_nodes

echo
display '----------------------------------------' $LOG_SUMMARY
display '--    Begin cluster configuration     --' $LOG_SUMMARY
display '----------------------------------------' $LOG_SUMMARY

# clean up mounts and volume from previous run, if any...
if [[ $NEW_DEPLOY == true ]] ; then
  echo
  display "-- Cleaning up (un-mounting, deleting volume, etc.)" $LOG_SUMMARY
  cleanup
fi

# set up mounts and create volume
echo
display "-- Setting up brick and volume mounts, creating and starting volume" \
	$LOG_SUMMARY
setup

echo
display "-- Performance config..." $LOG_SUMMARY
perf_config

# reboot nodes if needed
reboot_nodes

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
