# Installer shortcuts for the live environment (sourced by bash — keep shell)
alias zfs-install='sudo python3 /root/install/zfs-install.py'
alias zfsbootmenu-setup='sudo python3 /root/install/zfsbootmenu-setup.py'
alias zram-setup='sudo python3 /root/install/zram-config.py'
alias zbm-check='sudo python3 /root/install/zbm-check-kernels.py'

zfs-help() {
    cat << 'HELP'
Commands:
  zfs-install           Install Debian on ZFS (--interactive for the wizard)
  zfsbootmenu-setup     (Re)install ZFSBootMenu (--mdraid for Intel RST RAID)
  zram-setup            Configure ZRAM swap
  zbm-check             Check/fix "failed to find kernels"

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
