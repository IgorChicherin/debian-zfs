================================================================================
Debian ZFS installer (live ISO)
================================================================================

The installer is in /etc/install/; the commands zfs-install, zfsbootmenu-setup, zram-setup,
zbm-check and zbm-rescue (in /usr/local/bin) run its scripts. Use sudo.
All tools are Python 3 scripts; every one supports --help and --dry-run.

QUICK START
  nmtui                  # join Wi-Fi (MacBook Wi-Fi needs an ISO built with --macbook)
  lsblk
  sudo zfs-install --interactive

INSTALL TARGETS
  Whole disk (ERASES it, creates ESP + ZFS partition):
    sudo zfs-install --disk /dev/nvme0n1

  Free space next to Windows (keeps partitions, reuses the ESP):
    sudo zfs-install --disk /dev/nvme0n1 --use-free-space

  Already prepared partitions (only the chosen partition is erased):
    sudo zfs-install --select-partitions
    sudo zfs-install --pool-part /dev/nvme0n1p5 --efi-device /dev/nvme0n1p1

  Existing ZFS pool (new or existing boot environment):
    sudo zfs-install --use-existing-pool

  MacBook: add --macbook (built-in keyboard in the boot menu, Apple boot
  fallback, Broadcom Wi-Fi driver). Optional wired network + SSH in the menu:
    --zbm-network --ssh-key /root/id_ed25519.pub

  Intel RST RAID 0: use the RAID volume (cat /proc/mdstat, usually /dev/md126),
  never the imsm container (usually /dev/md127) or a member NVMe disk.

  Branch:  --release stable (Debian 13, default) | --release sid
  Options: --encrypt, --hostname NAME, --pool-name NAME, --boot-env NAME,
           --password PASS, --dry-run

OTHER TOOLS
  zbm_setup.py           (re)install ZFSBootMenu; --mdraid for Intel RST
  zram_config.py         ZRAM swap (--status, --remove)
  zbm_check_kernels.py   "failed to find kernels": --pool zroot --fix
  mdraid_rescue.py       guided repair when the system on an Intel RST / md RAID does not boot
                         (ZFSBootMenu shows no pool, or the kernel drops to an initramfs shell)
  zfs_kernel_guard.py    installed on new systems: stops kernel updates that
                         OpenZFS does not support, pins ZFSBootMenu to a working kernel

The installer already sets up ZFSBootMenu and ZRAM; the other tools are for
repairs and changes after installation.
================================================================================
