# Quick Start: Debian ZFS Root on Intel RST RAID 0

**For users with 2x NVMe in Intel RST RAID 0 configuration**

## 1. Identify Your RAID Device

Boot from Debian Trixie live environment or the custom ISO from this project (scripts at `/root/debian-zfs/`).

List your RAID arrays:

```bash
# Check all block devices
lsblk

# Check mdadm RAID
sudo mdadm --detail --scan

# Check device-mapper (Intel RST shows here typically)
sudo dmsetup ls
```

You should see output like:
- `/dev/md127` (mdadm RAID)
- `/dev/dm-0` (device-mapper RAID)
- OR `/dev/mapper/raid0` (named device-mapper)

## 2. Clone This Repository (if not using custom ISO)

```bash
sudo -i
git clone <this-repository>
cd debian-zfs
```

If using the custom ISO, scripts are already at `/root/debian-zfs/`.

## 3. Run Installation

Replace `/dev/md127` with your actual RAID device:

```bash
# Dry run first (safe, no changes)
sudo bash install/zfs-install.sh --disk /dev/md127 --dry-run

# Actual installation (will destroy data on RAID device!)
sudo bash install/zfs-install.sh --disk /dev/md127

# With encryption
sudo bash install/zfs-install.sh --disk /dev/md127 --encrypt

# Custom hostname
sudo bash install/zfs-install.sh --disk /dev/md127 --hostname myserver

# Install alongside Windows (creates dedicated 1GB EFI in free GPT space):
sudo bash install/zfs-install.sh --disk /dev/md127 --use-free-space

# All options
sudo bash install/zfs-install.sh --disk /dev/md127 \
    --hostname myserver \
    --pool-name zpool \
    --encrypt \
    --passphrase MyZFSPass
```

## 4. Watch the Installation

The script will:
1. ✓ Detect your RAID configuration
2. ✓ Validate the RAID device is safe to use
3. ✓ Install ZFS packages from trixie-backports
4. ✓ Partition your RAID device (1GB EFI + ZFS)
5. ✓ Create ZFS pool and datasets (`zroot/ROOT/trixie`)
6. ✓ Install Debian Trixie via debootstrap
7. ✓ Configure ZFSBootMenu
8. ✓ Auto-fix boot environment properties
9. ✓ Setup ZRAM compressed swap

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

### ZFSBootMenu shows "No boot environments found"

Boot from live ISO and run:
```bash
sudo bash /root/debian-zfs/install/fix-boot.sh
```

### ZFSBootMenu shows "Failed to find kernels"

Run the kernel check script:
```bash
sudo bash install/zbm-check-kernels.sh --pool zroot --dataset ROOT/trixie --fix
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
sudo bash install/zram-config.sh --status
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

1. Try `--dry-run` to see what would happen
2. Check logs: `journalctl -xe`
3. Boot fix: `sudo bash /root/debian-zfs/install/fix-boot.sh`
4. Docs: [README.md](README.md), [EXISTING_POOL_INSTALLATION.md](EXISTING_POOL_INSTALLATION.md)

---

**Version:** 2.1 (June 2026)
**Last Updated:** June 2026
