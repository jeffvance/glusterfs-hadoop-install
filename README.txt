		GlusterFS-Hadoop Packaging and Deployment

== Overview ==

  This top-level directory contains files and scripts common to both Red Hat  
  Storage (RHS) and to non-RHS targets for the preparation of gluster volumes
  for Hadoop workloads. If the target is fedora or other non-Red Hat Storage
  (RHS) platorm then files under the "glusterfs/" directory are used. If the
  target platform is RHS then there's more work to do, but the first step is
  to clone the rhs-hadoop-install repo and read its README file(s).
 
  When packaging the glusterfs-hadoop-install package for fedora or RHS the
  goal is to create a tar.gz file containing only the files and sub-directories
  needed for the target installation. This tarball will NOT include all of the
  files available in the glusterfs-hadoop-install repo, but rather just those
  files, scripts, and sub-directories needed for the target install.
  ./devutils/mk_tarball.sh is a helper script for creating a package tarball. If
  installing directly from a git clone the common install.sh "--dirs" option is
  required when the target deployment is RHS.

  Each sub-directory can contain a script named "pre_install.sh" and/or a script
  named "post_install.sh". These are the only scripts within a sub-directory
  that are automatically executed by the common install.sh script. As expected,
  "pre_install.sh" is invoked as the first step of the common "prep_node.sh" 
  script, and "post_install.sh" is invoked as the last step of prep_node.sh.
  Note: the common prep_node.sh script is automatically invoked by the common
  install.sh script once per node.

  Sub-directory *_install.sh scripts may execute additional programs and/or
  scripts, but the common install.sh script only executes one "pre_install" and
  one "post_install" script per sub-directory. Note: sub-directory *_install.sh
  scripts are optional and if not present no sub-directory scripts are executed,
  even if other executable scripts are present in the sub-directory. If there 
  are multiple sub-directories in the package, each with pre_|post_ install.sh
  scripts, the execution order is determined by the alphabetic order of the sub-
  directory names.


== Installation ==
  
  The tarball is downloaded to one of the cluster nodes or to the user's
  localhost. The download directory is arbitrary. The common install.sh requires
  password-less ssh from the node hosting the install tarball (the "install-
  from" node) to all nodes in the cluster. There is a utility script,
  devutils/passwordless-ssh.sh, to set up password-less SSH based on the nodes
  listed in the "hosts" file. 
 
  The tarball should contain the following:
   - 20_glusterfs_hadoop_sudoers: sudoers file for multi-users.
   - hosts.example: sample "hosts" config file.
   - install.sh: the common install script, executed by the root user.
   - prep_node.sh: companion script to install.sh, executed once per node.
   - post_install_dirs.sh: a script to set up multi-user security.
   - README.txt: this file.
   - devutils/: utility directory.
   - fedora/: optional, directory for fedora-specific files/scritps.
   - rhs/: optional, directory for rhs-specific files/scripts.
   Note: one of fedora/ or rhs/ (but not both) is required.

 
== Before you begin ==

  The "hosts" file must be created by the root user doing the install. It is not
  part of the tarball, but an example hosts file is provided. The "hosts" file
  is expected to be created in the same directory where the tarball has been 
  downloaded. If a different location is required the "--hosts" option can be 
  used to specify the "hosts" file path. The "hosts" file contains a list of IP
  adress followed by hostname (same format as /etc/hosts), one pair per line.
  Each line represents one node in the storage cluster (gluster trusted pool).
  Example:
     ip-for-node-1 hostname-for-node-1
     ip-for-node-3 hostname-for-node-3
     ip-for-node-2 hostname-for-node-2
     ip-for-node-4 hostname-for-node-4
 
  IMPORTANT: the node order in the hosts file is critical for two reasons:
  1) Assuming the storage volume is created with replica 2 then each pair of
     lines in hosts represents replica pairs. For example, the first 2 lines in
     hosts are replica pairs, as are the next two lines, etc.
  2) Hostnames are expected to be lower-case.


  Note:
  - passwordless SSH is required between the installation node and each storage
    node. See the Addendum at the end of this document if you would like to see 
    instructions on how to do this. Note: there is a utility script named
    devutils/passwordless-ssh.sh which sets up password-less SSH using the nodes
    defined in the local hosts file.
  - the order of the nodes in the "hosts" file is in replica order.


== Installation ==

Instructions:
 0) upload the tarball to the deployment directory on the "install-from" node.

 1) extract tarball to the local directory:
    $ tar xvzf <tarballName-version.tar.gz>

 2) cd to the extracted rhs-hadoop-install directory:
    $ cd <tarballName-version>

 3) execute the common "install.sh" from the install directory:
    $ ./install.sh [options (see --help)] <brick-dev> (note: brick_dev is 
                                                       required)
    For example: ./install.sh /dev/sdb

    Output is displayed on STDOUT and is also written to a logfile. The default
    logfile is: /var/log/glusterfs-cluster-install.log. The --logfile option
    allows for a different logfile. Even when a less verbose setting is used
    the logfile will contain all messages.

 4) When the script completes remaining Hadoop distro and management steps need
    to be followed.  After hadoop distro installation completes, create gluster 
    base directories and fix permissions by running this common script:
    
    $ ./post_install_dirs.sh /mnt/glusterfs /lib/hadoop
 
 5) Validate the Installation

    Open a terminal and navigate to the Hadoop Directory
    cd /usr/lib/hadoop
     
    Change user to the mapred user
    su mapred

    Submit a TeraGen Hadoop job test
    bin/hadoop jar hadoop-examples-1.2.0.1.3.2.0-112.jar teragen 1000 in-dir
	
    Submit a TeraSort Hadoop job test
    bin/hadoop jar hadoop-examples-1.2.0.1.3.2.0-112.jar terasort in-dir out-dir


== Addendum ==

1) Setting up password-less SSH 
 
   There is a utility script (devutils/passwordless-ssh.sh) which will set up
   password-less SSH from localhost (or wherever you run the script from) to 
   all hosts defined in the local "hosts" file. Use --help for more info.
