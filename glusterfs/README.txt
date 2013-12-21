		GlusterFS-Specific Preparation Notes


  NOTE: the script(s) contained in the glusterfs/ directory are not meant to be
    run stand-alone. They are automatically run by the common ../prep_node.sh
    script in top-most directory.

General packaging and generic install directions are found in the parent
directory README file. This directory contains files and/or scripts used to 
perform non-RHS, glusterfs-specific volume preparations that are not part of
the common installation process.

Currently, glusterfs-specific preparations include:
  - getting the current glusterfs-hadoop plugin (JAR file),
  - installing xfs if needed,
  - installing openJDK Java if needed
  - installing and starting gluster.
