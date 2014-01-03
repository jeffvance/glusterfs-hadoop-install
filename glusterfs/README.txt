		GlusterFS-Specific Preparation Notes


  NOTE: the script(s) contained in the glusterfs/ directory are not meant to be
    run stand-alone. They are automatically run by the common ../prep_node.sh
    script.

General packaging and generic install directions are found in the parent
directory README file. This directory contains files and/or scripts used to 
perform non-RHS, glusterfs-specific volume preparations that are not part of
the common installation process.

Currently, glusterfs-specific preparations include:
  - getting the current glusterfs-hadoop plugin (JAR file),
  - installing xfs if needed,
  - installing openJDK Java if needed
  - installing and starting gluster.

As long as glusterfs/ is the only directory found in the parent directory (../)
running the installation script is simple:
  - cd to the parent directory (../),
  - ./install.sh --help  # to learn about the various options,
  - ./install.sh <brick-device>
  - examine log file in /var/log/glusterfs-hadoop-install.log

