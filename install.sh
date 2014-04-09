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


# initialize_globals: set all globals vars to their initial/default value.
#
initialize_globals(){

  SCRIPT=$(basename $0)
  INSTALL_VER='0.86' # self version

  # flag if we're doing an rhs related install, set before parsing args
  [[ -d glusterfs ]] && RHS_INSTALL=false || RHS_INSTALL=true

  INSTALL_DIR=$PWD # name of deployment (install-from) dir
  INSTALL_FROM_IP=($(hostname -I))
  INSTALL_FROM_IP=${INSTALL_FROM_IP[$(( ${#INSTALL_FROM_IP[@]}-1 ))]} #last ntry
  REMOTE_INSTALL_DIR="/tmp/rhs-hadoop-install/" # on each node

  # companion install script name
  PREP_SH='prep_node.sh' # companion script run on each node
  REMOTE_PREP_SH="$REMOTE_INSTALL_DIR$PREP_SH" # full path
 
  # logfiles
  [[ "$RHS_INSTALL" == true ]] && LOGFILE='/var/log/rhs-hadoop-install.log' ||
	LOGFILE='/var/log/glusterfs-hadoop-install.log' 

  # local logfile on each host, copied from remote host to install-from host
  PREP_NODE_LOG='prep_node.log'
  PREP_NODE_LOG_PATH="${REMOTE_INSTALL_DIR}$PREP_NODE_LOG"
  
  # DO_BITS global task mask: bit set means to do the task associated with it
  DO_BITS=0xffff # default is to do all tasks
  
  # define bits in the DO_BITS global for the various perpare tasks
  # note: right-most bit is 0, value is the shift amount
  REPORT_BIT=0
  PREP_BIT=1
  CLEAN_BIT=2
  SETUP_BIT=3
  SETUP_BRICKS_BIT=4
  SETUP_VOL_BIT=5
  SETUP_USERS_BIT=6
  SETUP_HDIRS_BIT=7
  PERF_BIT=8
  VALIDATE_BIT=9

  # clear bits whose default is to not do the task
  ((DO_BITS&=~(1<<CLEAN_BIT))) # cleanup is no longer done by default
  ((DO_BITS&=~(1<<VALIDATE_BIT)))

  # brick/vol defaults
  VG_DEFAULT='RHS_vg1'
  LV_DEFAULT='RHS_lv1'
  VG_NAME="$VG_DEFAULT" # option can override
  LV_NAME="$LV_DEFAULT" # option can override
  LVM=false
  BRICK_DIR='/mnt/brick1'
  VOLNAME='HadoopVol'
  GLUSTER_MNT='/mnt/glusterfs'
  REPLICA_CNT=2

  # "hosts" file concontains hostname ip-addr for all nodes in cluster
  HOSTS_FILE="$INSTALL_DIR/hosts"
  # number of nodes in hosts file (= trusted pool size)
  NUMNODES=0

  # hadoop users and group(s)
  HBASE_U='hbase'
  HCAT_U='hcat'
  HIVE_U='hive'
  MAPRED_U='mapred'
  YARN_U='yarn'
  # note: all users/owners belong to the hadoop group for now
  HADOOP_G='hadoop'

  # misc
  MGMT_NODE=''
  YARN_NODE=''
  REBOOT_NODES=()
  VERBOSE=$LOG_SUMMARY
  ANS_YES='n' # for -y option

  # source constants and functions common to other scripts
  source $INSTALL_DIR/functions
}

# init_dynamic_globals: after the command line and the local hosts file have
# been parsed and validate, set global variables that are a function of the
# command args and the hosts file content.
#
function init_dynamic_globals(){

  # set vg/lv names and lv-brick to raw-dev components, based on args
  # note: vg/lv names and lv-brick can change per node in where the hosts file
  #  contains different brick-dev names per node
  if [[ -n "$BRICK_DEV" ]] ; then # brick-dev is static (not in hosts file)
    setup_vg_lv_brick "$BRICK_DEV"
  else # brick-devs (lv or raw) come from hosts file
    LV_BRICK="/dev/$VG_NAME/$LV_NAME" # may be set later...
  fi

  # convention is to use the volname as the subdir under the brick as the mnt
  BRICK_MNT=$BRICK_DIR/$VOLNAME
  MAPRED_SCRATCH_DIR="$BRICK_DIR/mapredlocal" # xfs but not distributed
  firstNode=${HOSTS[0]}

  # set DO_xxx globals based on DO_BITS
  ((DO_REPORT=(DO_BITS>>REPORT_BIT) % 2)) # 1 --> do it
  ((DO_PREP=(DO_BITS>>PREP_BIT) % 2))
  ((DO_CLEAN=(DO_BITS>>CLEAN_BIT) % 2))
  ((DO_SETUP=(DO_BITS>>SETUP_BIT) % 2)) # 0 --> defeats all setup tasks
  ((DO_SETUP_BRICKS=(DO_BITS>>SETUP_BRICKS_BIT) % 2))
  ((DO_SETUP_VOL=(DO_BITS>>SETUP_VOL_BIT) % 2))
  ((DO_SETUP_USERS=(DO_BITS>>SETUP_USERS_BIT) % 2))
  ((DO_SETUP_HDIRS=(DO_BITS>>SETUP_HDIRS_BIT) % 2))
  ((DO_PERF=(DO_BITS>>PERF_BIT) % 2))
  ((DO_VALIDATE=(DO_BITS>>VALIDATE_BIT) % 2))
}

# yesno: prompts $1 to stdin and returns 0 if user answers yes, else returns 1.
# The default (just hitting <enter>) is specified by $2.
# $1=prompt (required),
# $2=default (optional): 'y' or 'n' with 'n' being the default default.
#
function yesno(){

  local prompt="$1"; local default="${2:-n}" # default is no
  local yn

   while true ; do
       read -p "$prompt" yn
       case $yn in
	 [Yy])         return 0;;
	 [Yy][Ee][Ss]) return 0;;
	 [Nn])         return 1;;
	 [Nn][Oo])     return 1;;
	 '') # default
	   [[ "$default" != 'y' ]] && return 1 || return 0
         ;;
	 *) # unexpected...
	   echo "Expecting a yes/no response, not \"$yn\""
	 ;;
       esac
   done
}


# short_usage: write short usage to stdout.
#
function short_usage(){

  cat <<EOF

Syntax:

$SCRIPT [-v|--version] | [-h|--help]

$SCRIPT --mgmt-node <node>   --yarn-master <node>
           [--brick-mnt <path>] [--vol-name <name>]  [--vol-mnt <path>]
           [--replica <num>]    [--hosts <path>]
           [--vg-name <name>]   [--lv-name <name>]   [--lvm]
           [--logfile <path>]   [-y]
           [--verbose [num] ]   [-q|--quiet]         [--debug]
           [brick-dev]

EOF
}

# usage: write full usage/help text to stdout.
# Note: the --_prep, --_users, --_clean, --_setup, etc options are not yet
#   documented.
#
function usage(){

  cat <<EOF

Usage:

Prepares a glusterfs volume for Hadoop workloads. Note that hadoop itself is not
installed by this script. The user is expected to install hadoop separately.
Each node in the storage cluster must be defined in the local "hosts" file. The
"hosts" file must be created prior to running this script. The "hosts" file
format is described in the included hosts.example file.
  
The brick-dev names the brick device where the XFS file system will be mounted, 
and is the name of the physical volume which is part of (or will be made part
of) a volume group.  Examples include: /dev/<VGname>/<LVname>, /dev/sda,
/dev/vdb. The brick-dev names a RAID6 storage partition. If the brick-dev is
omitted then each line in the local "hosts" file must include a brick-dev-path.
EOF
  short_usage
  cat <<EOF
  brick-dev          : Optional. Device path where the XFS file system is
                       created, eg. /dev/volgrp/lv or /dev/sda. If a raw block
                       device is supplied then --lvm must be specified in order
                       to create an LVM setup for the device. In all cases the
                       storage bricks must be in LVM on top of XFS. brick-dev
                       may be included in the local "hosts" file, per node. If 
                       specified on the command line then the same brick-dev
                       applies to all nodes.
  --mgmt-node <node> : Required. hostname of the node to be used as the
                       hadoop management node. Recommended to be a server
                       outside of the storage pool.
  --yarn-master <node>: Required. hostname of the node to be used as the yarn
                       master node. Recommended to be a server outside of the
                       storage pool.
  --brick-mnt <path> : Brick directory. Default: "/mnt/brick1/". Note: the
                       vol-name is appended to the brick-mnt when forming the
                       volume's brick name.
  --vol-name  <name> : Gluster volume name. Default: "HadoopVol".
  --vol-mnt   <path> : Gluster mount point. Default: "/mnt/glusterfs".
  --replica   <num>  : Volume replication count. The number of storage nodes
                       must be a multiple of the replica count. Default: 2.
  --hosts     <path> : path to \"hosts\" file. This file contains a list of
                       "IP-addr hostname" pairs for each node in the cluster.
                       Default: "./hosts".
  --lvm              : create a simple LVM setup based on the raw brick-dev, and
                       the passed-in or default VG and LV names. Default is to
                       not create a logical volume from the brick-dev, in which
                       case the --vg-name and --lv-name options are ignored.
  --vg-name   <name> : Ignored unless --lvm specified. Volume group name where
                       the raw block brick-dev will be added. Can be an existing
                       VG or a new VG will be created. Default: "RHS_vg1".
  --lv-name   <name> : Ignored unless --lvm specified. Logical Volume name. Can
                       be an existing LV created from the VG, or a new LV will
                       be created. Default: "RHS_lv1".
  --logfile   <path> : logfile name. Default is /var/log/rhs-hadoo-install.log.
                       brick-dev. Default: no logical volume is created.
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
  local LONG_OPTS='vg-name:,lv-name:,brick-mnt:,vol-name:,vol-mnt:,replica:,hosts:,mgmt-node:,yarn-master:,logfile:,verbose::,help,version,quiet,debug,_prep,_clean,_setup,_brick-dirs,lvm,_vol,_hadoop-dirs,_users,_perf,_validate'
  local task_opt_seen=false

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
	--vg-name)
	    VG_NAME=$2; shift 2; continue
	;;
	--lv-name)
	    LV_NAME=$2; shift 2; continue
	;;
        --lvm)
            LVM=true
	    shift; continue
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
	--yarn-master)
	    YARN_NODE=$2; shift 2; continue
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
        # undocumented options follow:
	--_prep)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<PREP_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
	--_clean)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<CLEAN_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
	--_setup)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<SETUP_BIT)))
            # set all of the setup sub-task bits
            ((DO_BITS|=(1<<SETUP_BRICKS_BIT)))
            ((DO_BITS|=(1<<SETUP_VOL_BIT)))
            ((DO_BITS|=(1<<SETUP_USERS_BIT)))
            ((DO_BITS|=(1<<SETUP_HDIRS_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
        --_brick-dirs)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<SETUP_BIT)))
	    ((DO_BITS|=(1<<SETUP_BRICKS_BIT)))
	    task_opt_seen=true
	    shift; continue
        ;;
	--_vol)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<SETUP_BIT)))
            ((DO_BITS|=(1<<SETUP_VOL_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
	--_hadoop-dirs)
	    # note: vol must be mounted and created
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<SETUP_BIT)))
            ((DO_BITS|=(1<<SETUP_HDIRS_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
	--_users)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<SETUP_BIT)))
            ((DO_BITS|=(1<<SETUP_USERS_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
	--_perf)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<PERF_BIT)))
            task_opt_seen=true
	    shift; continue
	;;
	--_validate)
	    [[ $task_opt_seen == false ]] && DO_BITS=0 # clear all bits
	    ((DO_BITS|=(1<<VALIDATE_BIT)))
	    ((DO_BITS|=(1<<REPORT_BIT))) # show report summary too
            task_opt_seen=true
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

  # --logfile, if relative pathname make absolute
  # note: needed if scripts change cwd
  [[ $(dirname "$LOGFILE") == '.' ]] && LOGFILE="$PWD/$LOGFILE"
}

# check_cmdline: check for missing or conflicting command line options/args.
# Accumulate errors and if any then exit -1.
#
function check_cmdline(){

  local RAW_BLOCK_DEV_RE='/dev/[msv]d[a-z]*[0-9]*$'
  local errcnt=0

  # validate replica cnt for RHS
  if (( REPLICA_CNT != 2 )) ; then
    echo "ERROR: replica = 2 is the only supported value"
    ((errcnt++))
  fi

  # since a brick-dev is optional in the local hosts file, verify that we
  # either have a brick-dev cmdline arg, or we have bricks in the hosts file,
  # but not both
  if [[ -z "$BRICK_DEV" && ${#BRICKS} == 0 ]] ; then
    echo -e "ERROR: a brick device path is required either as an arg to $SCRIPT or in\nthe local $HOSTS_FILE hosts file"
    ((errcnt++))
  elif [[ -n "$BRICK_DEV" && ${#BRICKS}>0 ]] ; then
    echo -e "ERROR: a brick device path can be provided either as an arg to $SCRIPT or\nin the local $HOSTS_FILE hosts file, but not in both"
    ((errcnt++))
  fi

  # require that --mgmt-node and --yarn-master are specified
  if [[ -z "$MGMT_NODE" ]] ; then
    echo "ERROR: the management node (--mgmt-node) is required"
    ((errcnt++))
  fi
  if [[ -z "$YARN_NODE" ]] ; then
    echo "ERROR: the yarn-master node (--yarn-master) is required"
    ((errcnt++))
  fi

  # lvm checks
  # note: when the brick-dev is supplied in the hosts file then each brick-dev
  #   is validated separately in prep_node.sh.
  if [[ -n "$BRICK_DEV" ]] ; then # brick-dev supplied as cmdline arg
    if [[ $LVM == false ]] ; then # brick-dev is expected to be /dev/vg/lv
      if [[ "$VG_NAME" != "$VG_DEFAULT" || "$LV_NAME" != "$LV_DEFAULT" ]]; then
	echo "ERROR: cannot use --vg-name and/or --lv-name without also specifying --lvm"
	((errcnt++))
      fi
      if [[ "$BRICK_DEV" =~ $RAW_BLOCK_DEV_RE ]] ; then
	echo "ERROR: expect a logical volume (LV) brick path, e.g. /dev/VG/LV"
	((errcnt++))
      fi
    elif [[ ! "$BRICK_DEV" =~ $RAW_BLOCK_DEV_RE ]] ; then # LVM==true
      echo "ERROR: expect a raw block brick device path, e.g. /dev/sdb"
      ((errcnt++))
    fi
  fi

  (( errcnt > 0 )) && exit -1
}

# report_deploy_values: write out args and default values to be used in this
# deploy/installation. Prompts to continue the script.
#
function report_deploy_values(){

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
  display "  Yarn master node:   $YARN_NODE"        $LOG_REPORT
  display "  Volume name:        $VOLNAME"          $LOG_REPORT
  display "  Number of replicas: $REPLICA_CNT"      $LOG_REPORT
  display "  Volume mount:       $GLUSTER_MNT"      $LOG_REPORT
  display "  XFS device path(s)  $report_brick"     $LOG_REPORT
  display "  XFS brick dir:      $BRICK_DIR"        $LOG_REPORT
  display "  XFS brick mount:    $BRICK_MNT"        $LOG_REPORT
  if [[ "$LVM" == true ]] ; then
    display "  Vol Group name:     $VG_NAME"        $LOG_REPORT
    display "  Logical Vol name:   $LV_NAME"        $LOG_REPORT
  fi
  display "  Verbose:            $VERBOSE"          $LOG_REPORT
  display "  Log file:           $LOGFILE"          $LOG_REPORT
  display    "_______________________________________" $LOG_REPORT

  if [[ $VERBOSE < $LOG_QUIET && "$ANS_YES" == 'n' ]] && \
     ! yesno "Continue? [y|N] "; then
    exit 0
  fi
}

# validate_nodes: NOT DONE. DO NOT USE!
#
function validate_nodes(){

  #local str; local str1; local len

  echo
  display "Validate of current environment for Hadoop tasks:" $LOG_REPORT
  echo

  #for node in "${HOSTS[@]}"; do
      #str="**** Node: $node ****"
      #len=${#str}
      #str1="$(printf '_%.0s' $(seq $len))"
      #display "$str1" $LOG_REPORT
      #display "$str"  $LOG_REPORT

      verify_mounts
      echo
      #verify_vol $node
      #echo
      #verify_users $node
      #echo
      #verify_dirs $node
      #echo
      #verify_ntp $node
  #done
  echo
exit
}

# verify_mounts: NOT DONE. DO NOT USE!
#
function verify_mounts(){

  local node
  local err; local errcnt=0; local out; local mnt_opts

  display "- Mount validation..." $LOG_REPORT
  display "  * Brick $BRICK_DIR:" $LOG_SUMMARY
  for node in "${HOSTS[@]}"; do
  ssh -oStrictHostKeyChecking=no root@$node "ls $BRICK_DIR >& /dev/null"
  if (( $? == 0 )) ; then # brick exists...
    out="$(ssh -oStrictHostKeyChecking=no root@$node "
	  grep $BRICK_DIR /proc/mounts")"
    if (( $? == 0 )) ; then # brick mounted...
      mnt_opts=$(cut -d ' ' -f 3-4 <<<$out)
      display "    - mounted as: $mnt_opts" $LOG_INFO
      if [[ ${mnt_opts%% *} != 'xfs' ]] ; then # mount type
	display "$node: ISSUE: must be XFS" $LOG_FORCE
	((errcnt++))
      fi
      if grep -qs -v noatime <<<$mnt_opts; then
	display "$node: ISSUE: missing \"noatime\" mount option" $LOG_INFO
	((errcnt++))
      fi
      if grep -qs -v inode64 <<<$mnt_opts; then
	display "$node: ISSUE: missing \"inode64\" mount option" $LOG_INFO
	((errcnt++))
      fi
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    xfs_info $BRICK_DIR")"
      if (( $? == 0 )) ; then # brick is xfs...
	out="$(cut -d' ' -f2 <<<$out | cut -d'=' -f2)" # isize value
	if (( out == 512 )) ; then
	  display "      xfs size=512 -- correct" $LOG_INFO
	else
	  display "$node: ISSUE: expect xfs size=512" $LOG_INFO
	  ((errcnt++))
	fi
      fi
    else
      display "$node: ISSUE: Brick is not mounted" $LOG_INFO
      ((errcnt++))
    fi
  else # brick not there...
    display "$node: ISSUE: Brick not found" $LOG_FORCE
    ((errcnt++))
  fi
  done

  echo
  display "  * Volume $GLUSTER_MNT:" $LOG_REPORT
  for node in "${HOSTS[@]}"; do
  ssh -oStrictHostKeyChecking=no root@$node "ls $GLUSTER_MNT >& /dev/null"
  if (( $? == 0 )) ; then # vol mnt exists...
    out="$(ssh -oStrictHostKeyChecking=no root@$node"
	  grep $GLUSTER_MNT /proc/mounts")"
    if (( $? == 0 )) ; then # vol mounted...
      mnt_opts=$(cut -d ' ' -f 3-4 <<<$out)
      display "    - mounted as: $mnt_opts" $LOG_REPORT
      if [[ ${mnt_opts%% *} != 'fuse.glusterfs' ]] ; then # mount type
	display "      ISSUE: must be fuse.glusterfs" $LOG_REPORT
	((errcnt++))
      fi
      # Note: cannot see entry-timeout,attribute-timeout, etc in mount
    else
      display "      ISSUE: Volume is not mounted" $LOG_FORCE
      ((errcnt++))
    fi
  else # vol mnt not there...
    display "      ISSUE: Volume not found" $LOG_FORCE
    ((errcnt++))
  fi
  done

  (( errcnt == 0 )) && display "...No mount errors" $LOG_REPORT || \
	display "...$errcnt MOUNT RELATED ERRORS" $LOG_FORCE
}

# kill_gluster: make sure glusterd and related processes are killed.
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

# start_gluster: make sure glusterd is started on all nodes.
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

# glusterd_busy: return 0 is there is a transaction in progress or staging 
# failed, else return 1. Args 1=error msg from previous gluster cmd.
#
function glusterd_busy(){

  local msg="$1"
  local TRANS_IN_PROGRESS='Another transaction is in progress'
  local STAGING_FAILED='Staging failed on'

  grep -qs -E "$TRANS_IN_PROGRESS|$STAGING_FAILED" <<<"$msg"
}

# wait_for_glusterd: execute gluster vol status on the first node and check
# the command status. If there is a transaction in progress or the staging
# failed then sleep some and try again. The loop stops when glusterd has
# processed the previous transaction.
# Returns the number of times -1 that the loop was executed, 0..n, with 0
# meaning there was not a stalled transaction.
#
function wait_for_glusterd(){

  local i=1; local err; local out; local SLEEP=10

  while true ; do # until an earlier transaction has completed...
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume status $VOLNAME 2>&1")"
      err=$?
      if ! glusterd_busy "$out" ; then
	break # not "busy" error so exit loop
      fi
      sleep $SLEEP
      display "...cluster slow(volstatus=$err), wait $((i*SLEEP)) seconds" \
	$LOG_DEBUG
      ((i++))
  done

  ((i--))
  return $i
}

# setup_vg_lv_brick: set the global vars VG_NAME, LV_NAME, and LV_BRICK, if the
# --lvm option was not specified (which is the default). This is needed when
# the brick-devs are vg/lv names coming from the local hosts file, rather than
# being provided as the brick-dev arg to the script.
# Args: $1=brick-dev-path, expected to be /dev/VG/LV.
#
function setup_vg_lv_brick(){

  local lv_dev="$1"

  if [[ $LVM == false ]] ; then  # brick-dev contains /dev/vg/lv
    LV_NAME="${lv_dev##*/}"
    VG_NAME="${lv_dev#*dev/}" # "vg/lv"
    VG_NAME="${VG_NAME%/*}"
  fi
  LV_BRICK="/dev/$VG_NAME/$LV_NAME"
}

# verify_hadoop_gid: check that the gid for the passed-in group is the same on
# all nodes. Note: the mgmt- and yarn-master nodes, if outside of the storage
# pool, need to be included in the consistency test.
# Args: $1=group name
#
function verify_hadoop_gid(){

  local grp="$1"
  local node; local i; local out; local gid; local extra_node=''
  local gids=(); local uniq_gids=(); local nodes=()

  [[ -z "$MGMT_NODE_IN_POOL" ]] && extra_node+="$MGMT_NODE "
  [[ -z "$YARN_NODE_IN_POOL" ]] && extra_node+="$YARN_NODE "

  for node in ${HOSTS[@]} $extra_node ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$node "getent group $grp")"
      if (( $? != 0 )) || [[ -z "$out" ]] ; then
	display "ERROR: group $grp not created on $node" $LOG_FORCE
	exit 4
      fi
      # extract gid, "hadoop:x:<gid>", eg hadoop:x:500:users
      gid=${out%:*}  # delete ":users"
      gid=${gid##*:} # extract gid
      gids+=($gid)   # in node order
      nodes+=($node) # to include mgmt-node if needed
  done

  uniq_gids=($(printf '%s\n' "${gids[@]}" | sort -u))
  if (( ${#uniq_gids[@]} > 1 )) ; then
    display "ERROR: \"$grp\" group has inconsistent GIDs across the cluster. GIDs: ${uniq_gids[*]} -- see $LOGFILE" $LOG_FORCE
    for (( i=0; i<${#nodes[@]}; i++ )); do
	display "  node: ${nodes[$i]} has $grp GID: ${gids[$i]}" $LOG_DEBUG
    done
    exit 6
  fi
}

# verify_user_uids: check that the uid for the passed-in user(s) is the same
# on all nodes. Note: the mgmt- and yarn-master nodes, if outside the trusted 
# pool, need to be included in the consistency check.
# Args: $@=user names
#
function verify_user_uids(){

  local users=($@)
  local node; local i; local out; local errcnt=0
  local user; local extra_node=''
  local uids; local uniq_uids; local nodes

  [[ -z "$MGMT_NODE_IN_POOL" ]] && extra_node+="$MGMT_NODE "
  [[ -z "$YARN_NODE_IN_POOL" ]] && extra_node+="$YARN_NODE "

  for user in "${users[@]}" ; do
     uids=(); nodes=()
     for node in ${HOSTS[@]} $extra_node ; do
	out="$(ssh -oStrictHostKeyChecking=no root@$node "id -u $user")"
	if (( $? != 0 )) || [[ -z "$out" ]] ; then
	  display "ERROR: user $user not created on $node" $LOG_FORCE
	  exit 9
	fi
	uids+=($out)   # in node order
	nodes+=($node) # to include mgmt-node if needed
     done

     uniq_uids=($(printf '%s\n' "${uids[@]}" | sort -u))
     if (( ${#uniq_uids[@]} > 1 )) ; then
       display "ERROR: \"$user\" user has inconsistent UIDs across cluster. UIDs: ${uniq_uids[*]}" $LOG_FORCE
       for (( i=0; i<${#nodes[@]}; i++ )); do
	   display "  node: ${nodes[$i]} has $user UID: ${uids[$i]}" $LOG_DEBUG
       done
       ((errcnt++))
     fi
  done

  (( errcnt > 0 )) &&  { 
	display "See $LOGFILE for more info on above error(s)"  $LOG_FORCE;
	exit 11; }
}

# verify_vol_stopped: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that the volume has been
# stopped, or a predefined number of attempts have been made.
#
function verify_vol_stopped(){

  local out; local i=0; local SLEEP=5; local LIMIT=$((NUMNODES * 2))
  local EXPCT_VOL_STATUS_ERR="Volume $VOLNAME is not started"
  local EXPCT_VOL_DEL_ERR="Volume $VOLNAME does not exist"

  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume status $VOLNAME" 2>&1)"
      if grep -qs -E "$EXPCT_VOL_STATUS_ERR|$EXPCT_VOL_DEL_ERR" <<<$out; then
	break
      fi
      sleep $SLEEP 
      ((i++))
      display "...verify vol stop wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume stopped..." $LOG_INFO
  else
    display "   ERROR: Volume not stopped..." $LOG_FORCE
    exit 12
  fi
}

# verify_vol_deleted: there are timing windows when using ssh and the
# gluster cli. This function returns once it has confirmed that the volume has
# been deleted, or a predefined number of attempts have been made.
#
function verify_vol_deleted(){

  local out; local i=0; local SLEEP=5; local LIMIT=$((NUMNODES * 2))
  local EXPCT_VOL_STATUS_ERR="Volume $VOLNAME does not exist"

  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume status $VOLNAME" 2>&1)"
      [[ $? == 1 && "$out" == "$EXPCT_VOL_STATUS_ERR" ]] && break
      sleep $SLEEP 
      ((i++))
      display "...verify vol delete wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume deleted..." $LOG_INFO
  else
    display "   ERROR: Volume not deleted..." $LOG_FORCE
    exit 13
  fi
}

# verify_peer_detach: there are timing windows when using ssh and the gluster
# cli. This function returns once it has confirmed that the number of nodes in
# the trusted pool is zero, or a predefined number of attempts have been made.
# $1=peer detach iteration (0 == 1st attempt)
# Note: this function returns 0 if the peer detach is confirmed, else 1. Also,
#   if the pool has not detached on the 2nd attempt this function exits.
#
function verify_peer_detach(){

  local first=$1 # first time verifying?
  local out; local i=0; local SLEEP=5; local LIMIT=$((NUMNODES * 1))
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
  local out; local i=0; local SLEEP=5; local LIMIT=$((NUMNODES * 2))

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
  local err; local i=0; local out; local SLEEP=5; local LIMIT=$((NUMNODES * 3))
  local VOL_CREATED='Created'; local VOL_STARTED='Started'

  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume info $VOLNAME >volinfo.out 2>&1
	if (( \$? == 0 )) ; then
	  grep Status: volinfo.out; exit 0
	else
	  exit 1
	fi")"
	err=$?
      if (( err == 0 )) && grep -qs -E "$VOL_CREATED|$VOL_STARTED" <<<$out; then
 	break
      fi
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
# cli. This function returns once it has confirmed that the volume has started,
# or a predefined number of attempts have been made.
#
function verify_vol_started(){

  local out; local i=0; local SLEEP=5; local LIMIT=$((NUMNODES * 2))

  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume status $VOLNAME" 2>&1)"
      (( $? == 0 )) && break
      sleep $SLEEP 
      ((i++))
      display "...verify vol start wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   Volume started..." $LOG_INFO
  else
    display "   ERROR: Volume not started..." $LOG_FORCE
    exit 24
  fi
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

# stop_volume: stop the volume and verify that it did stop. Also, handles slow
# clusters in a loop calling wait_for_clusterd.
#
function stop_volume(){

  local out; local err

  while true ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	   gluster --mode=script volume stop $VOLNAME 2>&1")"
      err=$?
      display "gluster vol stop(err=$err): $out" $LOG_DEBUG
      (( err == 0 )) && break # vol stop worked, exit loop
      if ! glusterd_busy "$out" ; then
	break # an error other than a transaction in progress...
      fi
      wait_for_glusterd
  done
  verify_vol_stopped
}

# delete_volume: delete the volume and verify that it was deleted. Also,
# handles slow clusters in a loop calling wait_for_clusterd.
#
function delete_volume(){

  local out; local err

  while true ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster --mode=script volume delete $VOLNAME 2>&1")"
      err=$?
      display "gluster vol delete(err=$err): $out" $LOG_DEBUG
      (( err == 0 )) && break # vol delete worked, exit loop
      if ! glusterd_busy "$out" ; then
	break # an error other than a transaction in progress...
      fi
      wait_for_glusterd
  done
  verify_vol_deleted
}

# cleanup: do the following steps (order matters), but always prompt for
# confirmation before deleting the volume, etc.
# Note: this function used to be part of the default task flow for preparing
#   RHS for Hadoop workload; however, now (2014-Mar) it is *only* available
#   via the undocumented --_clean option.
# 1) re-start glusterd
# 2) stop vol **
# 3) delete vol **
# 4) detach nodes
# 5) umount vol if mounted
# 6) unmount brick_mnt if mounted
# 7) remove the brick and gluster mount records from /etc/fstab
# 8) delete the LV, VG and PV. (--lvm only)
# ** gluster cmd only done once for entire pool; all other cmds executed on
#    each node
#
function cleanup(){

  local x; local node; local i; local out; local err; local force=''
  local brick="$BRICK_DEV"

  # unconditionally prompt before deleting files and the volume!
  echo
  echo "The next step is restart glusterd, stop and delete the gluster volume,"
  echo "and detach the trusted storage pool."
  echo "Answering yes will perform these tasks."
  echo
  if ! yesno "Continue? [y|N] " ; then
    exit 0
  fi
  if ! yesno "Are you 100% certain? Continue? [y|N] "
  then
    exit 0
  fi
  echo

  display "**Note: gluster \"cleanup\" errors below may be ignored if the $VOLNAME volume" $LOG_INFO
  display "  has not been created or started, etc." $LOG_INFO

  # 1) kill gluster in case there are various gluster processes hangs, then
  #    re-start gluster
  kill_gluster
  start_gluster

  # 2) stop vol (distributed)
  # 3) delete vol (distributed)
  display "  -- on node $firstNode (distributed):" $LOG_INFO
  display "       stopping $VOLNAME volume..."     $LOG_INFO
  display "       deleting $VOLNAME volume..."     $LOG_INFO
  stop_volume
  delete_volume

  # 4) detach nodes on all but firstNode
  display "  -- from node $firstNode:" $LOG_INFO
  display "       detaching all other nodes from trusted pool..." $LOG_INFO
  for x in {0,1}; do # 2nd time through use force option
      out=''
      (( x != 0 )) && force='force'
      for (( i=1; i<$NUMNODES; i++ )); do # starting at 1 not 0
	  out+="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	  gluster peer detach ${HOSTS[$i]} $force 2>&1")"
	  out+="\n"
      done
      display "peer detach: $out" $LOG_DEBUG
      if verify_peer_detach $x ; then
	break # detached on 1st try
      fi
  done

  # 5) umount vol on every node, if mounted
  # 6) unmount brick_mnt on every node, if mounted
  # 7) remove the brick and gluster mount records from /etc/fstab
  # 8) delete the LV, VG and PV on every node (if --lvm)
  display "  -- on all nodes:"            $LOG_INFO
  display "       umount $GLUSTER_MNT..." $LOG_INFO
  display "       umount $BRICK_DIR..."   $LOG_INFO
  display "       update /etc/fstab..."   $LOG_INFO
  [[ $LVM == true ]] && display "       delete LV, VG, PV..." $LOG_INFO
  for (( i=0; i<$NUMNODES; i++ )); do
      node=${HOSTS[$i]}
      # set VG/LV names and LV_BRICK based on options and brick-dev
      if [[ -z "$BRICK_DEV" ]] ; then  # brick-dev dynamic per hosts file
	brick="${BRICKS[$i]}"
        setup_vg_lv_brick "$brick"
      fi

      out="$(ssh -oStrictHostKeyChecking=no root@$node "
          if grep -qs $GLUSTER_MNT /proc/mounts ; then
            umount $GLUSTER_MNT 2>&1
          fi
          if grep -qs $BRICK_DIR /proc/mounts ; then
            umount $BRICK_DIR 2>&1
          fi
	  if grep -wqs $BRICK_DIR /etc/fstab ; then # delete from fstab
	    sed -i '\|$BRICK_DIR|d' /etc/fstab
	  fi
	  if grep -wqs $GLUSTER_MNT /etc/fstab ; then # delete from fstab
	    sed -i '\|$GLUSTER_MNT|d' /etc/fstab
	  fi
	  if [[ $LVM == true ]] ; then
	    source ${REMOTE_INSTALL_DIR}functions
	    if lv_present $LV_BRICK ; then
	      lvremove -f $LV_BRICK 2>&1
	    fi
	    if vg_present $VG_NAME ; then
	      vgremove -f $VG_NAME 2>&1
	    fi
	    if pv_present $brick ; then
	      pvremove -y $brick 2>&1
	    fi
	  fi")"
      display "results on $node: $out" $LOG_DEBUG
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

# brick_dirs_mnt: invoked by setup(). For each node do:
# - set up xfs on lv-brick-dev on every node (needed here rather in prep_node
#     so that combo of --_clean followed by --_setup works)
# - mkdir brick_dir and vol_mnt on every node
# - append brick_dir and gluster mount entries to fstab on every node
# - mount brick on every node
# - mkdir brick1/<volname>dir on every node (done after brick mount)
# - mkdir mapredlocal scratch dir on every node (done after brick mount)
#
function brick_dirs_mnt(){

  local out; local node; local i; local err
  local XFS_SIZE=512
  local brick="$BRICK_DEV"
  local BRICK_MNT_OPTS="noatime,inode64"
  local GLUSTER_MNT_OPTS="entry-timeout=0,attribute-timeout=0,use-readdirp=no,acl,_netdev"
  local MNT_BUSY_ERR=32

  for (( i=0; i<$NUMNODES; i++ )); do
      node=${HOSTS[$i]}
      display "On $node:" $LOG_DEBUG

      # set VG/LV names and LV_BRICK based on options and brick-dev
      if [[ -z "$BRICK_DEV" ]] ; then  # brick-dev dynamic per hosts file
	brick="${BRICKS[$i]}"
        setup_vg_lv_brick "$brick"
      fi

      # set up xfs, make brick and vol mnt dirs
      # note: must be done before the brick mount
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mkfs -t xfs -i size=$XFS_SIZE -f $LV_BRICK 2>&1
	    mkdir -p $BRICK_DIR $GLUSTER_MNT 2>&1
            if [[ -d $BRICK_DIR && -d $GLUSTER_MNT ]] ; then
              echo ok
            else
              echo 'directories not created'
              exit 1
            fi ")"
      (( $? != 0 )) && {
	display "ERROR on $node: mkdir $BRICK_DIR & $GLUSTER_MNT: $out" \
		$LOG_FORCE;
	exit 36; }
      display " * mkdir $BRICK_DIR & $GLUSTER_MNT: $out" $LOG_DEBUG

      # append brick and gluster mounts to fstab
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	     if ! grep -qs $BRICK_DIR /etc/fstab ; then
	       echo '$LV_BRICK $BRICK_DIR xfs \
		 $BRICK_MNT_OPTS  0 0' >>/etc/fstab
	     fi
	     if ! grep -qs $GLUSTER_MNT /etc/fstab ; then
	       echo '$node:/$VOLNAME  $GLUSTER_MNT  glusterfs \
		 $GLUSTER_MNT_OPTS 0 0' >>/etc/fstab
	     fi")"
      (( $? != 0 )) && {
	display "ERROR: $node: append fstab: $out" $LOG_FORCE; exit 42; }
      display " * append fstab: $out" $LOG_DEBUG

      # Note: brick mnt & mapred scratch dir must be created after the brick is
      # mounted; otherwise, these dirs will be "hidden" by the mount. Also, 
      # permissions and owner must be set *after* the gluster dir is mounted
      # for the same reason.
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mount $BRICK_DIR 2>&1")" # mount via fstab
      err=$?
      display " * brick mount: $out" $LOG_DEBUG
      (( err != 0 && err != MNT_BUSY_ERR )) && {
	display "ERROR on $node: mount $LV_BRICK as $BRICK_DIR: $out" \
		$LOG_FORCE;
        exit 45; }

      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	    mkdir -p $BRICK_MNT $MAPRED_SCRATCH_DIR 2>&1
            if [[ -d $BRICK_MNT && -d $MAPRED_SCRATCH_DIR ]] ; then
              echo ok
            else
              echo 'directories not created'
              exit 1
            fi")"
      (( $? != 0 )) && {
        display "ERROR on $node: mkdir $BRICK_MNT & $MAPRED_SCRATCH_DIR: $out" \
		$LOG_FORCE;
        exit 48; }
      display " * mkdir $BRICK_MNT & $MAPRED_SCRATCH_DIR: $out" $LOG_DEBUG
  done
}

# create_volume: create the gluster volume and verify that it was created.
# Handle the case of slow clusters by calling wait_for_glusterd.
#
function create_volume(){

  local out; local err; local node; local bricks

  # first set up bricks string
  for node in "${HOSTS[@]}"; do
      bricks+=" $node:$BRICK_MNT"
  done

  while true ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	gluster volume create $VOLNAME replica $REPLICA_CNT $bricks 2>&1")"
      err=$?
      display "gluster vol create(err=$err): $out" $LOG_DEBUG
      (( err == 0 )) && break # vol create worked, exit loop
      if ! glusterd_busy "$out" ; then
	break # an error other than a transaction in progress...
      fi
      wait_for_glusterd
  done
  verify_vol_created $err "$bricks"
}

# start_volume: start the gluster volume and verify that it started. Handle
# the case of slow clusters by calling wait_for_glusterd.
#
function start_volume(){

  local out; local err

  while true ; do
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
  	    gluster --mode=script volume start $VOLNAME $force 2>&1")"
      err=$?
      display "gluster vol start(err=$err): $out" $LOG_DEBUG
      (( err == 0 )) && break # vol start worked, exit loop
      if ! glusterd_busy "$out" ; then
	break # an error other than a transaction in progress...
      fi
      wait_for_glusterd
  done
  verify_vol_started
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

# create_hadoop_group: create the passed-in group if it does not already exist.
# Note: the mgmt- and yarn-master nodes, if outside the storage pool, need to
# be included.
# Args: $1=hadoop group name
#
function create_hadoop_group(){

  local grp="$1"
  local node; local out; local err; local extra_node=''

  [[ -z "$MGMT_NODE_IN_POOL" ]] && extra_node+="$MGMT_NODE "
  [[ -z "$YARN_NODE_IN_POOL" ]] && extra_node+="$YARN_NODE "

  for node in ${HOSTS[@]} $extra_node; do
      # create hadoop group, if needed
      out="$(ssh -oStrictHostKeyChecking=no root@$node "
	if ! getent group $grp >/dev/null ; then
	  echo 'on $node: create $grp group'
	  groupadd --system $grp 2>&1 # no password
	fi")"
      err=$?
      display "groupadd $grp: $out" $LOG_DEBUG
      (( err != 0 )) && {
	display "ERROR $err on $node: $out" $LOG_FORCE;
	exit 55; }
  done
}

# create_hadoop_users: create the passed-in hadoop users on all nodes. Note: if
# the mgmt- and yarn-master nodes are outside of the trusted pool then they
# need to be included as one of the nodes where users are added.
# Args: $1=hadoop group name, $2 *name* of array of YARN/MR users
#
function create_hadoop_users(){

  local grp="$1"; local user_names="$2"
  local users=("${!user_names}") # array of user names
  local node; local out; local user; local extra_node=''

  [[ -z "$MGMT_NODE_IN_POOL" ]] && extra_node+="$MGMT_NODE "
  [[ -z "$YARN_NODE_IN_POOL" ]] && extra_node+="$YARN_NODE "

  for node in ${HOSTS[@]} $extra_node; do
      # create the required M/R-YARN users, if needed
      for user in "${users[@]}" ; do
	  out="$(ssh -oStrictHostKeyChecking=no root@$node "
	     if ! getent passwd $user >/dev/null ; then
		echo 'on $node: create users'
		useradd --system -g $grp $user 2>&1
		rc=\$?
		if (( rc == 0 )) ; then
		  echo '...success '
		else
		  echo '...error \$rc '
		fi
	     fi")"
	  display "useradd $user: $out" $LOG_DEBUG
	  if grep -qs 'error' <<<$out ; then
 	    display "ERROR on $node: $out" $LOG_FORCE
	    exit 58
	  fi
      done
  done
}

# create_hadoop_dirs: from the firstNode, create all the distributed
# directories needed for typical hadoop jobs. Also, assign the correct owners
# and permissions to each directory.
#
function create_hadoop_dirs(){

  local i; local out; local dir; local owner; local perm

  # the next 3 arrays are all paired
  # note: if a dirname is relative (doesn't start with '/') then the gluster
  #  mount is prepended to it
  local MR_DIRS=("$GLUSTER_MNT" 'mapred' 'mapred/system' 'tmp' 'user' 'mr-history' 'tmp/logs' 'mr-history/tmp' 'mr-history/done' 'job-staging-yarn' 'app-logs' 'hbase' 'apps' 'apps/webhcat')
  local MR_PERMS=(0775 0770 0755 1777 0775 0755 1777 1777 0770 0770 1777 0770 0775 0775)
  local MR_OWNERS=("$YARN_U" "$MAPRED_U" "$MAPRED_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$YARN_U" "$HBASE_U" "$HIVE_U" "$HCAT_U")

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
#  1) mkdir brick_dir
#  2) mkdir vol_mnt
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

  local i=0; local node=''
  local out; local err; local force=''
  local bricks=''
  local dir; local perm; local owner; local uid
  local MR_USERS=("$MAPRED_U" "$YARN_U" "$HBASE_U" "$HCAT_U" "$HIVE_U")

  if (( DO_SETUP_BRICKS )) ; then
    # 1) mkdir brick_dir on every node
    # 2) mkdir vol_mnt on every node
    # 3) append brick_dir and gluster mount entries to fstab on every node
    # 4) mount brick on every node
    # 5) mkdir mapredlocal scratch dir on every node (done after brick mount)
    display "  -- on all nodes:"                           $LOG_INFO
    display "       mkdir $BRICK_DIR, $GLUSTER_MNT and $MAPRED_SCRATCH_DIR..." \
	$LOG_INFO
    display "       append mount entries to /etc/fstab..." $LOG_INFO
    display "       mount $BRICK_DIR..."                   $LOG_INFO
    brick_dirs_mnt
  fi

  if (( DO_SETUP_VOL )) ;then
    # 6) create trusted pool from first node
    # 7) create vol on a single node
    # 8) start vol on a single node
    display "  -- on $firstNode node (distributed):"  $LOG_INFO
    display "       creating trusted pool..."         $LOG_INFO
    display "       creating $VOLNAME volume..."      $LOG_INFO
    display "       starting $VOLNAME volume..."      $LOG_INFO
    create_trusted_pool
    verify_pool_created
    # create the volume and verify
    create_volume
    # start the volume and verify
    start_volume

    # 9) mount vol on every node
    display "  -- mount $GLUSTER_MNT on all nodes..." $LOG_INFO
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
    create_hadoop_group "$HADOOP_G"
    # validate consistent hadoop group GID across cluster
    verify_hadoop_gid "$HADOOP_G"
    # create users
    create_hadoop_users "$HADOOP_G" MR_USERS[@] # last arg is *name*
    # validate consistent m/r-yarn user IDs across cluster
    verify_user_uids ${MR_USERS[@]}
  fi

  if (( DO_SETUP_HDIRS )) ; then
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

  local out; local i; local node; local ip
  local install_mgmt_node; local install_yarn_node
  local brick="$BRICK_DEV"; local LOCAL_PREP_LOG_DIR='/var/tmp/'
  # list of files to copy to node, exclude devutils/
  local FILES_TO_CP="$(find ./* -path ./devutils -prune -o -print)"


  # prep_node: sub-function which copies the prep_node script and all sub-
  # directories in the tarball to the passed-in node. Then the prep_node.sh
  # script is invoked on the passed-in node to install these files. If prep.sh
  # returns the "reboot-node" error code and the node is not the "install-from"
  # node then the global reboot-needed variable is set. If an unexpected error
  # code is returned then this function exits.
  # Args: $1=hostname, $2=node's ip (can be hostname if ip is unknown),
  #   $3=flag to install storage node, $4=flag to install the mgmt node,
  #   $5=flag to install yarn-master node, $6=brick-dev (or null).
  #
  function prep_node(){

    local node="$1"; local ip="$2" local install_storage="$3"
    local install_mgmt=$4; local install_yarn=$5; local brick="$6"
    local err; local ssh_target
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
    declare -A PREP_ARGS=([NODE]="$node" \
	[BRICK_DEV]="$brick" [LV_BRICK]="$LV_BRICK" [BRICK_DIR]="$BRICK_DIR" \
	[VG_NAME]="$VG_NAME" [LV_NAME]="$LV_NAME" \
	[INST_STORAGE]="$install_storage" [INST_MGMT]="$install_mgmt" \
	[INST_YARN]="$install_yarn" [MGMT_NODE]="$MGMT_NODE" \
	[YARN_NODE]="$YARN_NODE" [VERBOSE]="$VERBOSE" \
	[PREP_LOG]="$PREP_NODE_LOG_PATH" [REMOTE_DIR]="$REMOTE_INSTALL_DIR" \
	[USING_DNS]=$USING_DNS [LVM]="$LVM")
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

      # set VG/LV names and LV_BRICK based on options and brick-dev
      if [[ -z "$BRICK_DEV" ]] ; then  # brick-dev dynamic per hosts file
	brick="${BRICKS[$i]}"
        setup_vg_lv_brick "$brick"
      fi

      echo
      display
      display '--------------------------------------------' $LOG_SUMMARY
      display "-- Installing on $node ($ip)"                 $LOG_SUMMARY
      display '--------------------------------------------' $LOG_SUMMARY
      display
      install_mgmt_node=false
      install_yarn_node=false
      [[ -n "$MGMT_NODE_IN_POOL" && "$node" == "$MGMT_NODE" ]] && \
	install_mgmt_node=true
      [[ -n "$YARN_NODE_IN_POOL" && "$node" == "$YARN_NODE" ]] && \
	install_yarn_node=true
      prep_node $node $ip true $install_mgmt_node $install_yarn_node $brick

      display '-------------------------------------------------' $LOG_SUMMARY
      display "-- Done installing on $node ($ip)"                 $LOG_SUMMARY
      display '-------------------------------------------------' $LOG_SUMMARY
  done

  # if the mgmt or yarn nodes are not in the storage pool (not in hosts file)
  # then execute prep_node again in case there are management specific tasks.
  if [[ -z "$MGMT_NODE_IN_POOL" ]] ; then
    echo
    display 'Mgmt node is not a storage node thus mgmt code needs to be installed...' $LOG_INFO
    display "-- Starting install of management node \"$MGMT_NODE\"" $LOG_DEBUG
    prep_node $MGMT_NODE $MGMT_NODE false true null null # (no brick)
  fi
  if [[ -z "$YARN_NODE_IN_POOL" ]] ; then
    echo
    display 'Yarn-master node is not a storage node thus mgmt code needs to be installed...' $LOG_INFO
    display "-- Starting install of management node \"$MGMT_NODE\"" $LOG_DEBUG
    prep_node $MGMT_NODE $MGMT_NODE false true null null # (no brick)
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

# perf_config: assign the non-default gluster volume attributes below. If the
# gluster perf settings fail (could be due to a slow cluster) then repeat until
# success or a certain number of attempts have been made.
#
function perf_config(){

  local out; local err; local i=0
  local SLEEP=5; local LIMIT=$((NUMNODES * 2))
  local LAST_N=3 # tail records containing vol settings (vol info cmd)
  local TAG='Options Reconfigured:'
  local PREFETCH='performance.stat-prefetch'
  local EAGERLOCK='cluster.eager-lock'
  local QUICKREAD='performance.quick-read'
  local k; local v; local setting; local errcnt
  # set assoc array to desired values for the perf config keys
  declare -A settings=([$PREFETCH]='off' \
		       [$EAGERLOCK]='on' \
		       [$QUICKREAD]='off')

  for setting in ${!settings[@]}; do
      while true ; do
	  out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
		gluster vol set $VOLNAME $setting ${settings[$setting]} 2>&1")"
	  err=$?
	  display "gluster volume set $setting(err=$err): $out" $LOG_DEBUG
	  (( err == 0 )) && break # vol set worked, exit loop
	  if ! glusterd_busy "$out" ; then
	    break # an error other than a transaction in progress...
	  fi
	  wait_for_glusterd
	  display "   re-try $setting..." $LOG_DEBUG
      done
  done

  # verify settings
  while (( i < LIMIT )) ; do # don't loop forever
      out="$(ssh -oStrictHostKeyChecking=no root@$firstNode "
	    gluster volume info $VOLNAME >volinfo.out
	    remote_err=\$?
	    if (( remote_err == 0 )) ; then
	      sed -e '1,/$TAG/d' volinfo.out # output from tag to eof
	    fi
	    exit \$remote_err")"
      err=$?
      if (( err == 0 )) ; then
	out=($(echo ${out//: /:}))
	errcnt=0
	for setting in ${out[@]} ; do # "perf-key:value" list
	    k=${setting%:*} # strip off the value part
	    v=${setting#*:} # strip off the key part
	    if [[ "$v" != "${settings[$k]}" ]] ; then
	      display "WARN: $k not yet set..." $LOG_DEBUG
	      ((errcnt++))
	      break # for loop
	    fi
	done
	(( errcnt == 0 )) && break # while loop
      fi
      sleep $SLEEP
      ((i++))
      display "...verify gluster perf wait: $((i*SLEEP)) seconds" $LOG_DEBUG
  done

  if (( i < LIMIT )) ; then 
    display "   $VOLNAME volume performance set" $LOG_INFO
  else
    display "ERROR: $VOLNAME volume performance not set" $LOG_FORCE
  fi
}

# reboot_self: invoked when the install-from node (self) is also one of the
# storage nodes. In this case the reboot of the storage node (needed to 
# complete kernel patch installation) has been deferred -- until now.
# The user may be prompted to confirm the reboot of their node.
#
function reboot_self(){

  echo "*** Your system ($(hostname -s)) needs to be rebooted to complete the"
  echo "    installation of one or more kernel patches."
  if [[ "$ANS_YES" == 'n' ]] && yesno "    Reboot now? [y|N] " ; then
    display "*** REBOOTING self..." $LOG_INFO
    reboot
  fi
  echo "No reboot! You must reboot your system prior to running Hadoop jobs."
}


## ** main ** ##
##            ##
echo
initialize_globals

parse_cmd $@

display "$(date). Begin: $SCRIPT -- version $INSTALL_VER ***" $LOG_REPORT

echo
display "-- Verifying deployment environment, including the \"hosts\" file format:" $LOG_INFO
verify_local_deploy_setup

# validate command line options
check_cmdline

# set globals that are based on command line args and hosts file content
init_dynamic_globals

## start tasks: ##
(( DO_REPORT )) && report_deploy_values

(( DO_VALIDATE )) && validate_nodes ## NOT IMPLEMENTED! prompts and may exit

# per-node install and config...
(( DO_PREP )) && install_nodes

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
(( DO_PREP )) && reboot_nodes

#echo
#display "**** This script can be re-run anytime! ****" $LOG_REPORT
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
