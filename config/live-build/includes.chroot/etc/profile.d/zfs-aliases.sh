# Help for the live environment (sourced by bash — keep shell).
# The commands themselves are in /usr/local/bin (written by scripts/build_iso.py).

zfs-help() {
    cat << 'HELP'
Commands:
  zfs-install           Install Debian on ZFS (--interactive for the wizard)
  zfsbootmenu-setup     (Re)install ZFSBootMenu (--mdraid for Intel RST RAID)
  zram-setup            Configure ZRAM swap
  zbm-check             Check/fix "failed to find kernels"
  zbm-rescue            Repair an installed system on an Intel RST / md RAID that does not boot

Install targets:
  zfs-install --interactive
  zfs-install --disk /dev/nvme0n1                    whole disk (ERASED)
  zfs-install --disk /dev/nvme0n1 --use-free-space   next to Windows
  zfs-install --select-partitions                    prepared partitions
  zfs-install --pool-part /dev/nvme0n1p5 --efi-device /dev/nvme0n1p1
  zfs-install --use-existing-pool                    existing ZFS pool
  zfs-install --disk /dev/sda --release sid          Debian sid instead of 13
  zfs-install --disk /dev/sda --macbook              MacBook drivers (keyboard, Wi-Fi)

Wi-Fi: nmtui   |   SSH into the boot menu: --zbm-network --ssh-key FILE
Every command accepts --help and --dry-run.
HELP
}
