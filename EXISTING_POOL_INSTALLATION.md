# Installing Debian ZFS Root on Existing ZFS Pool

**Version:** 2.1 (April 2026)

This guide explains how to use the new **--use-existing-pool** feature to install Debian on an already-created ZFS pool.

---

## When to Use Existing Pool Mode

Use this mode when you have:

- ✓ ZFS pool already created with dedicated EFI partition
- ✓ Multiple disks already in RAID or other configuration
- ✓ Pre-existing ZFS datasets for root filesystem
- ✓ Custom dataset structures you want to preserve
- ✓ Separate storage pool you want to reuse

## Prerequisites

Before using existing pool mode, you need:

1. **Existing ZFS Pool** - Created and accessible
2. **ROOT Dataset** - Path like `poolname/ROOT/trixie` for installation
3. **EFI Partition** - Separate partition formatted as FAT32 (NOT part of ZFS pool)
4. **Debian Live Environment** - Same as fresh install

### Setup Example: Create Pool Before Installation

If you need to create a pool first:

```bash
# Boot Debian live environment
sudo -i

# List disks
lsblk

# Create ZFS pool on RAID
# Example 1: mdadm RAID 0
sudo mdadm --create /dev/md0 --level=0 --raid-disks=2 /dev/nvme0n1 /dev/nvme1n1
sudo zpool create -f \
    -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    zroot /dev/md0

# Create ROOT dataset
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/trixie

# Set bootfs
zpool set bootfs=zroot/ROOT/trixie zroot

# Create other datasets
zfs create -o mountpoint=/home zroot/home
zfs create -o mountpoint=/var/log zroot/var-log
```

---

## Usage Methods

### Method 1: Interactive Selection (Recommended)

Let the script guide you through pool and EFI selection:

```bash
sudo python3 install/zfs-install.py --use-existing-pool
```

The script will:
1. List available ZFS pools
2. Ask you to select which pool to use
3. Show available ROOT datasets
4. List available EFI partitions
5. Confirm your selections
6. Proceed with installation

### Method 2: Specify Pool and EFI

If you know your pool name and EFI partition:

```bash
sudo python3 install/zfs-install.py \
    --pool zroot \
    --efi-device /dev/sda1
```

Optional parameters:

```bash
sudo python3 install/zfs-install.py \
    --pool zroot \
    --efi-device /dev/sda1 \
    --hostname myserver \
    --encrypt \
    --password MyRootPass
```

### Method 3: Interactive Wizard

For complete guided setup:

```bash
sudo python3 install/zfs-install.py --interactive
```

This will:
1. Ask if you want fresh install or existing pool
2. Guide through all options step by step
3. Select pool and EFI interactively
4. Confirm before proceeding

---

## Pre-Installation Verification

Verify your setup before running installation:

```bash
# List existing pools
zpool list
zpool status

# List datasets
zfs list

# Find EFI partitions
fdisk -l | grep -i efi
lsblk -o NAME,SIZE,TYPE,FSTYPE | grep -E "sda|sdb|nvme"

# Check pool properties
zfs get all zroot/ROOT/trixie
```

---

## Step-by-Step Existing Pool Installation

### Step 1: Boot Live Environment

Boot a Debian live ISO (13 recommended)

### Step 2: Prepare Pool (if not already done)

```bash
sudo -i

# Create or verify pool exists
zpool list

# If creating new:
zpool create -f -o ashift=12 zroot /dev/your-disk-or-raid
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/trixie
zfs create zroot/home zroot/var-log
zpool set bootfs=zroot/ROOT/trixie zroot
```

### Step 3: Clone Installation Scripts

```bash
git clone <this-repository>
cd debian-zfs
```

### Step 4: Run Interactive Installation

```bash
sudo python3 install/zfs-install.py --use-existing-pool
```

Or with explicit parameters:

```bash
sudo python3 install/zfs-install.py \
    --pool zroot \
    --efi-device /dev/sda1 \
    --hostname debian-zfs \
    --encrypt
```

### Step 5: Verify Installation

```bash
# After reboot, verify:
zpool status
zfs list

# Check boot
efibootmgr -v

# Verify ZRAM (if configured)
zramctl
swapon --show
```

---

## Examples

### Example 1: RAID 0 NVMe with Existing Pool

**Scenario:** 2x NVMe already in RAID 0 (`/dev/md0`), pool created

```bash
# Verify pool
sudo zpool list
# zroot  500G   ...

# Install on existing pool
sudo python3 install/zfs-install.py \
    --pool zroot \
    --efi-device /dev/sda1
```

### Example 2: Device-Mapper (Intel RST) RAID

**Scenario:** Intel RST RAID already configured as `/dev/dm-0`

```bash
# Create pool if needed
sudo zpool create -f zroot /dev/dm-0

# Then install
sudo python3 install/zfs-install.py \
    --pool zroot \
    --efi-device /dev/sda1 \
    --hostname raid-server
```

### Example 3: Multiple Pools (Select Interactively)

**Scenario:** System has multiple ZFS pools

```bash
# Let script guide you
sudo python3 install/zfs-install.py --use-existing-pool

# Output:
# Available pools:
#   1) zroot
#   2) zdata
#   3) zbackup
# Select pool (1-3): 1
```

### Example 4: With Encryption

**Scenario:** Install on encrypted pool

```bash
sudo python3 install/zfs-install.py \
    --pool zroot \
    --efi-device /dev/sda1 \
    --encrypt \
    --passphrase "MySecurePass"
```

After installation, ZFS will prompt for passphrase at boot.

---

## Troubleshooting

### Pool Not Detected

```bash
# Verify pool exists
sudo zpool list
sudo zpool status

# If missing, import it
sudo zpool import -d /dev/disk/by-id

# List datasets
sudo zfs list
```

### No ROOT Datasets Found

If you get "No ROOT datasets found in pool", create them:

```bash
sudo zfs create -o mountpoint=none poolname/ROOT
sudo zfs create -o mountpoint=/ -o canmount=noauto poolname/ROOT/trixie
```

### EFI Partition Not Found

```bash
# List all partitions
sudo lsblk

# Find FAT32 partitions
sudo fdisk -l | grep -i FAT

# Check partition type
sudo fdisk -l /dev/sda | grep -i efi

# Create EFI if missing (GPT disk required)
sudo sgdisk -n 1:1m:+512M -t 1:ef00 /dev/sda
sudo mkfs.vfat -F32 /dev/sda1
```

### Mount Point Already In Use

```bash
# Check what's mounted
mount | grep /mnt

# Unmount if needed
sudo umount -R /mnt
```

### ZFS Pool Import Fails

```bash
# Try force import
sudo zpool import -f poolname

# Or with device specification
sudo zpool import -d /dev/disk/by-id -f poolname
```

---

## Verification Checklist

After installation completes:

- [ ] System boots from EFI (not GRUB)
- [ ] ZFSBootMenu appears at boot
- [ ] Can select boot snapshots in ZFSBootMenu
- [ ] Debian logs in successfully
- [ ] ZFS pool status is "ONLINE"
- [ ] All datasets mount correctly
- [ ] ZRAM swap is active (if configured)
- [ ] SSH works (if enabled)

```bash
# Run these checks after first boot
sudo zpool status
sudo zfs list
sudo efibootmgr -v
sudo zramctl
sudo swapon --show
```

---

## Advanced: Encryption Setup

For encrypted pools with key file:

```bash
# During setup, you'll be prompted:
# "Enable ZFS encryption? (y/n)"

# Enter encryption passphrase when prompted
# After installation, verify:
sudo zfs get encryption zroot/ROOT/trixie
```

To unlock manually after boot:

```bash
# From emergency shell/live environment
sudo zpool import -N zroot
sudo zfs load-key -L prompt zroot/ROOT/trixie
sudo zfs mount zroot/ROOT/trixie
```

---

## Backup and Recovery

Once installed on existing pool:

```bash
# Create snapshots
sudo zfs snapshot zroot/ROOT/trixie@initial

# List snapshots
sudo zfs list -t snapshot

# Clone for backup
sudo zfs clone zroot/ROOT/trixie@initial zroot/ROOT/trixie-backup

# Rollback if needed (DESTROYS newer data!)
sudo zfs rollback zroot/ROOT/trixie@initial
```

---

## Comparison: Existing Pool vs Fresh Install

| Feature | Fresh Install | Existing Pool |
|---------|---------------|---------------|
| Disk preparation | Automatic (wiped) | User-managed |
| RAID setup | Automatic creation | Pre-configured |
| Pool creation | Automatic | Pre-configured |
| Dataset creation | Automatic | Pre-configured |
| Time to boot | ~5-15 min | ~5-15 min |
| Customization | Limited | High |
| Risk of data loss | Only on target disk | Only if you corrupt dataset |

---

## Getting Help

- **Interactive mode:** `--interactive` guides you through all steps
- **Dry run:** Add `--dry-run` to see what would happen
- **Logs:** Check `journalctl -xe` after any errors
- **Pool info:** `zpool list`, `zfs list`, `zpool status`
- **Script help:** `python3 install/zfs-install.py --help`

---

## See Also

- [FIXES_AND_RAID_SUPPORT.md](docs/FIXES_AND_RAID_SUPPORT.md) - All fixes and features
- [QUICK_START_RAID0.md](QUICK_START_RAID0.md) - Quick start guide
- [README.md](README.md) - General documentation
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - ZFS structure

---

**Version:** 2.1 (April 2026)  
**Last Updated:** April 2026  
**Status:** Production Ready
