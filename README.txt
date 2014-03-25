		GlusterFS-Hadoop Packaging and Deployment

== Overview ==

  This top-level directory contains files and scripts common to both Red Hat  
  Storage (RHS) and to non-RHS targets for the preparation of gluster volumes
  for Hadoop workloads. If the target is fedora or other non-Red Hat Storage
  (RHS) platorms then files under the "glusterfs/" directory are used. If the
  target platform is RHS then there's more work to do, but the first step is
  to clone the rhs-hadoop-install repo and to read its README files.

  The installation script is simple to execute:
  - ./install.sh --help  # to learn about the various options,
  - ./install.sh [brick-device]
  - examine the log file in /var/log/glusterfs-hadoop-install.log

  Each sub-directory may contain a script named "pre_install.sh" and/or a script
  named "post_install.sh". These are the only scripts within a sub-directory
  that are automatically executed by the install.sh script. As expected,
  "pre_install.sh" is invoked as the first step of the prep_node.sh script, and
  "post_install.sh" is invoked as the last step of prep_node.sh. Note: the
  prep_node.sh script is automatically invoked by install.sh script, once per
  node.

  Sub-directory *_install.sh scripts may execute additional programs and/or
  scripts, but install.sh script only executes one "pre_install" and one
  "post_install" script per sub-directory. Note: sub-directory *_install.sh
  scripts are optional and if not present no sub-directory scripts are executed,
  even if other executable scripts are present in the sub-directory. If there 
  are multiple sub-directories in the package, each with pre_|post_ install.sh
  scripts, the execution order is determined by the alphabetic order of the sub-
  directory names.


== Installation ==
  
  The tarball is downloaded to one of the cluster nodes or to the user's
  localhost. The download directory is arbitrary. The common install.sh requires
  password-less ssh from the node hosting the install tarball (the "install-
  from" node) to all nodes in the cluster.
 
  The tarball should contain the following:
   - functions: functions common to multiple scripts.
   - either glusterfs/: directory for fedora-specific files/scritps --or--
     rhs/ (plus optionally other rhs-specific sub-dirs).
   - hosts.example: sample "hosts" config file.
   - install.sh: the common install script, executed by the root user.
   - prep_node.sh: companion script to install.sh, executed once per node.
   - README.txt: this file.
   - setup_container_executor.sh: script to configure a hadoop linux container.

 
== Before you begin ==

  The "hosts" file must be created by the root user doing the install. It is not
  part of the tarball, but an example hosts file is provided. The "hosts" file
  is expected to be created in the same directory where the tarball has been 
  downloaded. If a different location is required the "--hosts" option can be 
  used to specify the "hosts" file path. The "hosts" file is defined in the
  included "hosts.example" file, which should be read carefully. 
 
  IMPORTANT: the node order in the hosts file is critical for two reasons:
  1) Assuming the storage volume is created with replica 2 then each pair of
     lines in hosts represents replica pairs. For example, the first 2 lines in
     hosts are replica pairs, as are the next two lines, etc.
  2) Hostnames are expected to be lower-case.


  Note:
  - passwordless SSH is required between the installation node and each storage
    node.
  - the order of the nodes in the "hosts" file is in replica order.


== Installation ==

Instructions:
 0) upload the tarball to the deployment directory on the "install-from" node.

 1) extract tarball to the local directory:
    $ tar xvzf <tarballName-version.tar.gz>

 2) cd to the extracted rhs-hadoop-install directory:
    $ cd <tarballName-version>

 3) execute the common "install.sh" from the install directory:
    $ ./install.sh [options (see --help)] <brick-dev> (see hosts.example for
                                                       more on brick-dev)
    For example: ./install.sh /dev/sdb

    Output is displayed on STDOUT and is also written to a logfile. The default
    logfile is: /var/log/<glusterfs|rhs>-hadoop-install.log. The --logfile
    option allows for a different logfile. Even when a less verbose setting is
    used the logfile will contain all messages.
    Note: each storage node also has a logfile named
      /tmp/<glusterfs|rhs>-hadoop-install/prep_node.log. This logfile is added 
      to the main logfile but may be useful if a node crashes or the script
      hangs.

 4) When the script completes remaining Hadoop distro and management steps need
    to be followed.  After hadoop distro installation completes, run the
    provided setup_container_executor.sh script to configure hadoop linux
    containers:
      $ ./setup_container_executor.sh  # no arguments
 
 5) Validate the Installation

    Open a terminal and navigate to the Hadoop Directory
    cd /usr/lib/hadoop
     
    Change user to the mapred user
    su mapred

    Submit a TeraGen Hadoop job test
    bin/hadoop jar hadoop-examples-1.2.0.1.3.2.0-112.jar teragen 1000 in-dir
	
    Submit a TeraSort Hadoop job test
    bin/hadoop jar hadoop-examples-1.2.0.1.3.2.0-112.jar terasort in-dir out-dir

