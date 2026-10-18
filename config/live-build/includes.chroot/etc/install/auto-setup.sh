#!/bin/bash
# auto-setup.sh — print the live system banner
# (called from /etc/profile.d/zfs-install-setup.sh; shell on purpose)

[ -f /etc/live/image ] || [ -d /run/live ] || exit 0
[ -d /etc/install ] || exit 0

cat << 'MSG'
================================================================================
  Debian ZFS live environment — installer ready (commands in /usr/local/bin)

  No network? Join Wi-Fi with:  nmtui

  Guided install (whole disk, free space, prepared partitions or existing pool):
    sudo zfs-install --interactive

  Or directly:
    sudo zfs-install --disk /dev/nvme0n1                      # whole disk
    sudo zfs-install --select-partitions                      # prepared partitions
    sudo zfs-install --disk /dev/md126                        # Intel RST RAID volume

  Help: zfs-help, cat /etc/install/README.txt
================================================================================
MSG
