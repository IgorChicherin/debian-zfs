================================================================================
Debian ZFS installer (live ISO)
================================================================================

The installer is in /etc/install/ (copied to /root/install/ at login).
All tools are Python 3 scripts; every one supports --help and --dry-run.

QUICK START
  sudo -i
  nmtui                  # join Wi-Fi (MacBook Wi-Fi needs an ISO built with --macbook)
  lsblk
  python3 /root/install/debian_zfs_install.py --interactive

INSTALL TARGETS
  Whole disk (ERASES it, creates ESP + ZFS partition):
    python3 /root/install/debian_zfs_install.py --disk /dev/nvme0n1

  Free space next to Windows (keeps partitions, reuses the ESP):
    python3 /root/install/debian_zfs_install.py --disk /dev/nvme0n1 --use-free-space

  Already prepared partitions (only the chosen partition is erased):
    python3 /root/install/debian_zfs_install.py --select-partitions
    python3 /root/install/debian_zfs_install.py --pool-part /dev/nvme0n1p5 --efi-device /dev/nvme0n1p1

  Existing ZFS pool (new or existing boot environment):
    python3 /root/install/debian_zfs_install.py --use-existing-pool

  MacBook: add --macbook (built-in keyboard in the boot menu, Apple boot
  fallback, Broadcom Wi-Fi driver). Optional wired network + SSH in the menu:
    --zbm-network --ssh-key /root/id_ed25519.pub

  Intel RST RAID 0: use the RAID volume (cat /proc/mdstat, usually /dev/md126),
  never the imsm container (usually /dev/md127) or a member NVMe disk.

  Branch:  --release stable (Debian 13, default) | --release sid
  Options: --encrypt, --hostname NAME, --pool-name NAME, --boot-env NAME,
           --password PASS, --dry-run

OTHER TOOLS
  zbm_setup.py   (re)install ZFSBootMenu; --mdraid for Intel RST
  zram_config.py         ZRAM swap (--status, --remove)
  zbm_check_kernels.py   "failed to find kernels": --pool zroot --fix
  mdraid_rescue.py       guided repair when the system on an Intel RST / md RAID does not boot
                         (ZFSBootMenu shows no pool, or the kernel drops to an initramfs shell)
  zfs_kernel_guard.py    installed on new systems: stops kernel updates that
                         OpenZFS does not support, pins ZFSBootMenu to a working kernel

The installer already sets up ZFSBootMenu and ZRAM; the other tools are for
repairs and changes after installation.
================================================================================
