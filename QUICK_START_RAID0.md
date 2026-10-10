# Quick Start: Debian ZFS Root on Intel RST RAID 0

**For users with 2x NVMe in Intel RST RAID 0 configuration**

## 1. Identify Your RAID Device

Boot a Debian live environment in **UEFI mode** with the SATA/NVMe controller
still set to **Intel RST (RAID)** in the firmware setup.

```bash
sudo -i
apt install -y mdadm          # if the live system does not have it yet
mdadm --assemble --scan       # no-op if already assembled
cat /proc/mdstat
```

An Intel RST RAID 0 volume shows up as **two** md devices:

```
md126 : active raid0 nvme0n1[1] nvme1n1[0]      <- the RAID VOLUME  -> install here
md127 : inactive nvme1n1[1](S) nvme0n1[0](S)    <- the imsm CONTAINER -> never use
      metadata=external:imsm
```

The numbers vary (`md0`, `md126`, ...); `/dev/md/Volume0_0` is a symlink to
the volume. Check with:

```bash
cat /sys/block/md126/md/level   # raid0      -> volume, OK
cat /sys/block/md127/md/level   # container  -> wrong device
```

The installer refuses the container and the raw member disks and tells you
which volume to use. `dmraid` (`/dev/mapper/isw_*`) is not supported — use mdadm.

## 2. Clone This Repository

```bash
sudo -i
git clone <this-repository>
cd debian-zfs
```

## 3. Run Installation

Replace `/dev/md126` with your RAID **volume** (see step 1):

```bash
# Dry run first (safe, no changes)
sudo python3 install/zfs-install.py --disk /dev/md126 --dry-run

# Actual installation (will destroy data on RAID device!)
sudo python3 install/zfs-install.py --disk /dev/md126

# With encryption
sudo python3 install/zfs-install.py --disk /dev/md126 --encrypt

# Custom hostname
sudo python3 install/zfs-install.py --disk /dev/md126 --hostname myserver

# All options
sudo python3 install/zfs-install.py --disk /dev/md126 \
    --hostname myserver \
    --password MyRootPass \
    --pool-name zpool \
    --encrypt \
    --passphrase MyZFSPass
```

## 4. Watch the Installation

The script will:
1. ✓ Detect your RAID configuration
2. ✓ Validate the RAID device is safe to use
3. ✓ Install ZFS packages
4. ✓ Partition your RAID device
5. ✓ Create ZFS pool and datasets
6. ✓ Install Debian via debootstrap
7. ✓ Configure ZFSBootMenu
8. ✓ Setup ZRAM compressed swap

This takes 5-15 minutes depending on network and disk speed.

## 5. Reboot

```bash
sudo reboot
```

## 6. First Boot

- Remove live USB when prompted
- Select "ZFSBootMenu" in UEFI/BIOS
- Login as `root` (password you specified)
- Change root password: `passwd`

## 7. Verify Installation

```bash
# Check ZFS pool
zpool status

# Check datasets
zfs list

# Check boot entries
efibootmgr -v

# Check ZRAM
zramctl
swapon --show

# Check all disks in RAID
cat /proc/mdstat  # if using mdadm
```

## 8. Important Post-Install Tasks

**CHANGE THE ROOT PASSWORD!**
```bash
sudo passwd
```

Enable SSH (optional):
```bash
sudo systemctl enable ssh
sudo systemctl start ssh
```

Update system:
```bash
sudo apt update && sudo apt upgrade
```

## Common Commands

```bash
# Snapshots
zfs snapshot zroot/ROOT/trixie@backup1
zfs list -t snapshot

# Check disk usage
zfs list -o name,used,available
df -h

# Emergency boot rescue
# If system won't boot, from live environment:
sudo zpool import -N -R /mnt zroot
sudo zfs load-key -L prompt zroot/ROOT/trixie
sudo zfs mount zroot/ROOT/trixie
sudo chroot /mnt /bin/bash

# View ZFSBootMenu menu at boot
# Press 'e' at ZFSBootMenu splash screen
```

## Troubleshooting

### RAID not detected at boot

1. Check RAID in BIOS/UEFI - ensure it's still enabled
2. Verify from live environment:
   ```bash
   sudo mdadm --detail --scan
   ```
3. If RAID went offline, reactivate:
   ```bash
   sudo mdadm --assemble --scan
   ```

### ZFSBootMenu doesn't detect the RAID array after install

The prebuilt ZFSBootMenu EFI has no mdadm, so it can't assemble the Intel RST
array and finds no pool. When the target is an md device, the installer now
builds ZFSBootMenu locally with RAID support. For systems installed earlier,
run this from the installed system (or its chroot):

```bash
sudo python3 install/zfsbootmenu-setup.py --mdraid
```

This:
1. Installs `mdadm`, `dracut-core` and the ZFSBootMenu build tooling (`generate-zbm`)
2. Writes `/etc/mdadm/mdadm.conf` (via `mkconf`) from the running arrays
3. Installs `/etc/zfsbootmenu/dracut.conf.d/10-mdraid.conf`: dracut `mdraid`
   module, `mdadm.conf`, and the `vmd`, `md_mod`, `raid0` drivers
4. Installs the early-setup hook `/etc/zfsbootmenu/hooks/early-setup.d/10-mdraid-assemble.sh`
   that runs `mdadm --assemble --scan` before ZFSBootMenu imports pools
5. Puts `rd.auto=1` on the ZFSBootMenu command line. **Without it dracut
   disables md assembly**, even when mdadm is inside the image
6. Adds `vmd md_mod raid0` to `/etc/initramfs-tools/modules` and rebuilds the
   Debian initramfs, so the kernel ZBM boots can assemble the array too
7. Builds `/boot/efi/EFI/ZBM/VMLINUZ.EFI`, checks what is inside, and creates
   the EFI boot entries

**Verify the image** (the script does this automatically):

```bash
objcopy -O binary --only-section=.initrd /boot/efi/EFI/ZBM/VMLINUZ.EFI /tmp/zbm-initrd
lsinitrd /tmp/zbm-initrd | grep -E 'mdadm|raid0|vmd|mdraid-assemble'
objcopy -O binary --only-section=.cmdline /boot/efi/EFI/ZBM/VMLINUZ.EFI /tmp/zbm-cmdline; cat /tmp/zbm-cmdline
```

(`lsinitramfs VMLINUZ.EFI` does not work: the EFI file is a unified kernel
image, so the initramfs has to be extracted first.)

**EFI boot entry on an RST volume:** `efibootmgr` often can't create entries
for md devices. The script tries the RAID volume first, then raid-disk 0 of
the RAID 0 array (its first chunk holds the GPT, so the partition GUID
matches). If both fail, it installs ZBM as the removable-media fallback
`\EFI\BOOT\BOOTX64.EFI` (backing up any existing file to
`BOOTX64.EFI.pre-zbm`). A post-generation hook keeps that copy up to date.
Use `--fallback` to always install it.

**Emergency boot (before the rebuild):** boot the live USB, then:

```bash
mdadm --assemble --scan
zpool import -N -R /mnt zroot
zfs mount zroot/ROOT/trixie && mount /dev/md126p1 /mnt/boot/efi
for d in dev proc sys; do mount --rbind /$d /mnt/$d; done
chroot /mnt bash /root/debian-zfs/install/zfsbootmenu-setup.py --mdraid   # path to your checkout
```

**Rebuild after upgrades:** the ZBM image has its own copy of ZFS and mdadm.
Run `generate-zbm` after upgrading ZFS (especially before `zpool upgrade`)
or mdadm.

### ZFSBootMenu shows "Failed to find kernels"

Run the kernel check script:
```bash
sudo python3 install/zbm-check-kernels.py --pool zroot --dataset ROOT/trixie --fix
```

### Can't access ZFS after boot

If using encryption, ensure passphrase is correct:
```bash
# From ZFSBootMenu, you'll be prompted for passphrase
# Or from live environment, manually unlock:
sudo zfs load-key -L prompt zroot/ROOT/trixie
```

### ZRAM not working

Check status:
```bash
sudo python3 install/zram-config.py --status
```

Reactivate if needed:
```bash
sudo systemctl restart dev-zram0.swap
```

## Important Notes

⚠️ **RAID 0 = No Redundancy**
- Single disk failure = complete data loss
- Backup critical data regularly
- Consider RAID 1 or 5 for important systems

⚠️ **ZFS = Not a Backup**
- ZFS is not a backup solution
- Snapshots are on same disks
- Use external backups for disaster recovery

⚠️ **Performance**
- RAID 0: ~2x throughput (sum of disk speeds)
- ZRAM swap: Uses RAM for swap (compressed)
- ZFS compression (LZ4): CPU ↑ Disk I/O ↓

## Success Indicators

After reboot, you should see:

```bash
$ zpool status
  pool: zroot
 state: ONLINE
  
$ zfs list
NAME               USED  AVAIL  REFER  MOUNTPOINT
zroot              5.2G  450G   144K  none
zroot/ROOT         2.1G  450G   144K  none
zroot/ROOT/trixie 2.1G  450G  2.1G  /
zroot/home         3.1G  450G  3.1G  /home
zroot/var-log      0B   450G   0B   /var/log

$ efibootmgr -v
BootCurrent: 0001
Timeout: 3 seconds
Boot0001* ZFSBootMenu	HD(1,GPT,12345678-1234...)

$ zramctl
NAME      ALGORITHM DISKSIZE DATA  COMPR TOTAL STREAMS MOUNTPOINT
/dev/zram0 zstd        3.8G   0B   0B    8.1K    1      /dev/zram0
```

## Need Help?

1. Check the detailed docs: `docs/FIXES_AND_RAID_SUPPORT.md`
2. Try `--dry-run` to see what would happen
3. Check logs: `journalctl -xe`
4. Search: "ZFS + your issue" on Ubuntu/Debian forums

---

**Version:** 2.0 (April 2026)  
**Last Updated:** April 2026
