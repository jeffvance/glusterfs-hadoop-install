		GlusterFS-Hadoop Packaging and Deployment


  NOTE: this script is not meant to be run stand-alone. It is automatically
  invoked by the common ../prep_node.sh script (top-most directory).

  General packaging and generic install directions are found in the parent
  directory README file. This directory contains files and/or scripts used to 
  perform non-RHS, glusterfs-specific volume preparations that are not part of
  the common installation process.

  Currently, this includes:
  - getting the current glusterfs-hadoop plugin (JAR file),
  - installing xfs if needed,
  - installing glusterfs if needed.

  Note: RHS-specific preparations will omit files in this directory.
