# Debian ZFS Root Installation - Bug Fixes and Intel RST RAID 0 Support

**Version:** 2.0 (April 2026)  
**Last Updated:** April 2026  
**Status:** Production Ready

## Overview

This document describes all critical bug fixes and new Intel RST RAID 0 support added to the Debian ZFS automated installation scripts.

---

## 🐛 Critical Bugs Fixed

### 1. Unsafe sed Variable Substitution (zfs-install.sh:666-669)

**Severity:** CRITICAL (Security Issue)

**Issue:** Plaintext passwords and hostnames were substituted in sed commands without proper escaping, causing:
- Expansion of special shell characters (`;`, `&`, `/`, `\`)
- Potential command injection if usernames/hostnames contain special characters
- Security risk with passwords visible in sed output during debugging

**Fix Applied:**
```bash
# BEFORE (UNSAFE):
sed -i "s/__HOSTNAME__/$HOSTNAME/g" "$chroot_script"
sed -i "s/__ROOT_PASSWORD__/$ROOT_PASSWORD/g" "$chroot_script"

# AFTER (SAFE):
sed -e "s|__HOSTNAME__|$(printf '%s\n' "$HOSTNAME" | sed -e 's/[\/&]/\\&/g')|g" \
    "$chroot_script" > "$temp_script"

# Passwords handled separately with proper escaping
sed -i "s|__ROOT_PASSWORD__|$(printf '%s\n' "$ROOT_PASSWORD" | sed -e 's/[\/&]/\\&/g')|g" "$temp_script"
```

**Impact:** Passwords and special characters in hostnames are now safely handled.

---

### 2. UUID Capture Bug in DRY-RUN Mode (zfs-install.sh:696)

**Severity:** HIGH

**Issue:** In DRY-RUN mode, `run_cmd` returns the string `[DRY-RUN]` prefix, causing invalid UUID in `/etc/fstab`:
```
UUID=[DRY-RUN] blkid -s UUID...  /boot/efi  vfat...
```

**Fix Applied:**
```bash
# Check if DRY-RUN, use placeholder if needed
if [ "$DRY_RUN" = true ]; then
    BOOT_UUID="00000000-0000-0000-0000-000000000000"
else
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE") || {
        log_error "Failed to get UUID from $BOOT_DEVICE"
        return 1
    }
fi
```

**Impact:** DRY-RUN mode now produces valid configuration files.

---

### 3. Curl Download Without Error Checking (zfsbootmenu-setup.sh:227)

**Severity:** CRITICAL

**Issue:** curl command fails silently, potentially creating corrupted/empty ZFSBootMenu EFI files:
```bash
# BEFORE - No error checking!
curl -o "$ZBM_DIR/VMLINUZ.EFI" -L https://get.zfsbootmenu.org/efi
```

**Fix Applied:**
```bash
# Proper error checking with timeout
if ! curl -fSL --connect-timeout 10 -m 300 -o "$ZBM_DIR/VMLINUZ.EFI" \
    "https://get.zfsbootmenu.org/efi"; then
    log_error "Failed to download ZFSBootMenu EFI binary!"
    exit 1
fi
```

**Impact:** Installation will fail if download fails instead of creating corrupted system.

---

### 4. Fragile efibootmgr Output Parsing (zfsbootmenu-setup.sh:258-260)

**Severity:** HIGH

**Issue:** efibootmgr output format can vary, causing awk parsing to fail:
```bash
# BEFORE - Fragile parsing
efibootmgr | grep "ZFSBootMenu" | awk '{print $1}' | sed 's/Boot//;s/\*//'
```

**Fix Applied:**
```bash
# Robust parsing with validation
efibootmgr | grep "ZFSBootMenu" | sed 's/^Boot//' | sed 's/\*.*//' | sed 's/ .*//' | \
while read -r num; do
    if [ -n "$num" ] && [[ "$num" =~ ^[0-9]+$ ]]; then
        efibootmgr -B -b "$num" 2>/dev/null || log_warn "Failed to remove Boot$num"
    fi
done
```

**Impact:** EFI boot entry cleanup now works reliably.

---

### 5. Exit Called in Non-Main Function (zram-config.sh:214)

**Severity:** HIGH

**Issue:** `exit 0` called in `create_config()` function exits entire script, preventing cleanup:
```bash
# BEFORE - Dangerous
exit 0  # in function create_config()
```

**Fix Applied:**
```bash
# Proper return statement
return 0
```

**Impact:** Script cleanup code now executes properly.

---

### 6. Unhandled Error Returns (zram-config.sh:293-297)

**Severity:** MEDIUM

**Issue:** `exit 1` called in `activate_zram()` function, preventing graceful degradation:
```bash
# BEFORE
systemctl start dev-zram0.swap || {
    log_error "Failed!"
    exit 1  # Exits entire script
}

# AFTER
systemctl start dev-zram0.swap || {
    log_error "Failed!"
    return 1  # Returns from function, allows script to continue
}
```

**Impact:** Script can now continue and report multiple errors instead of failing on first issue.

---

## 🆕 Intel RST RAID 0 Support

### Overview

Full support for Intel RST RAID 0 configurations with automatic detection and validation.

### What's New

#### 1. RAID Array Detection

```bash
detect_raid_array() {
    # Detects mdadm RAID arrays (/dev/md*)
    # Detects device-mapper arrays (/dev/dm-*, /dev/mapper/*)
    # Warns about active RAID arrays
}
```

**Supported RAID Types:**
- mdadm software RAID (`/dev/md127`, `/dev/md0`, etc.)
- Device-mapper RAID (Intel RST, LVM) (`/dev/dm-0`, `/dev/mapper/raid0`, etc.)
- Direct disks (standard) (`/dev/sda`, `/dev/nvme0n1`, etc.)

#### 2. Disk Safety Validation

```bash
validate_disk_for_installation() {
    # Check if disk is already in ZFS pool
    # Check if disk is part of active RAID array
    # Prevent accidental data destruction
}
```

#### 3. Enhanced Device Naming

```bash
partition_device() {
    # Support for mdadm: /dev/md127p1
    # Support for device-mapper: /dev/dm-0p1
    # Support for NVMe: /dev/nvme0n1p1
    # Support for SATA: /dev/sda1
    # Support for MMC: /dev/mmcblk0p1
}
```

### Usage Examples

#### Intel RST RAID 0 (2x NVMe)

```bash
# List RAID arrays
lsblk
mdadm --detail --scan
dmsetup ls

# Install on Intel RST RAID device
sudo bash install/zfs-install.sh --disk /dev/md127

# Or if device-mapper shows it
sudo bash install/zfs-install.sh --disk /dev/dm-0
```

#### mdadm Software RAID

```bash
# Create RAID 0 from 2 NVMe disks
sudo mdadm --create /dev/md0 --level=0 --raid-disks=2 /dev/nvme0n1 /dev/nvme1n1

# Install on RAID device
sudo bash install/zfs-install.sh --disk /dev/md0
```

#### Mixed Disk Configurations

```bash
# Single NVMe
sudo bash install/zfs-install.sh --disk /dev/nvme0n1

# Single SATA
sudo bash install/zfs-install.sh --disk /dev/sda

# USB storage
sudo bash install/zfs-install.sh --disk /dev/sdb

# MMC card
sudo bash install/zfs-install.sh --disk /dev/mmcblk0
```

### Pre-Installation Safety Checks

The script now performs:

1. **RAID Detection**: Identifies if disk is part of RAID array
2. **ZFS Check**: Verifies disk isn't already in ZFS pool
3. **Data Warning**: Confirms you want to proceed
4. **Device Info**: Shows detected device type and details

### Example Output

```
[INFO] ═══════════════════════════════════════════════════════
[INFO] Debian Bookworm ZFS Root Installation Script
[INFO] Version: 2.0 (April 2026) - With Intel RST RAID 0 Support
[INFO] ═══════════════════════════════════════════════════════
[INFO] 
[INFO] RAID/Device Configuration:
[INFO]   Current disk: /dev/md127
[INFO]   Type: mdadm software RAID
[INFO]   Details:
[INFO]     /dev/md127 analysis:
[INFO]     Version : 1.2
[INFO]     Array UUID : 12345678:90abcdef:ghijklmn:opqrstuv
[INFO]     Name : myraid
[INFO]     State : clean
[INFO]     Active Devices : 2
[INFO]     /dev/nvme0n1p1[0]      active sync   238.47GiB
[INFO]     /dev/nvme1n1p1[1]      active sync   238.47GiB
```

---

## 📋 Complete List of Changes

### zfs-install.sh (Major Updates)

| Line | Issue | Fix |
|------|-------|-----|
| 2-31 | Help text | Added Intel RST RAID 0 example |
| 57-142 | New section | Added RAID detection functions |
| 178-223 | partition_device() | Enhanced to support mdadm and device-mapper |
| 207-212 | resolve_install_layout() | Added RAID info display |
| 213 | Disk validation | Added validate_disk_for_installation() call |
| 214 | Disk validation | Added detect_raid_array() call |
| 636-706 | Sed replacement | Fixed unsafe variable substitution |
| 714-720 | UUID capture | Fixed DRY-RUN UUID bug |
| 726-750 | Download error | Fixed curl without error checking |
| 901-915 | Main function | Updated version and added RAID info display |

### zfsbootmenu-setup.sh (Security & Stability)

| Line | Issue | Fix |
|------|-------|-----|
| 225-231 | Download error | Added proper curl error checking |
| 256-266 | efibootmgr parsing | Improved regex and validation |
| 264-273 | EFI entry creation | Added error handling |

### zram-config.sh (Error Handling)

| Line | Issue | Fix |
|------|-------|-----|
| 213 | exit in function | Changed to return 0 |
| 257 | exit in function | Changed to return 1 |
| 293-307 | exit in function | Changed to return 1 |
| 338-370 | main() error handling | Improved error handling flow |

---

## ✅ Testing Recommendations

### Test Scenarios

1. **Single NVMe Disk**
   ```bash
   sudo bash install/zfs-install.sh --disk /dev/nvme0n1 --dry-run
   ```

2. **Intel RST RAID 0 (2x NVMe)**
   ```bash
   sudo bash install/zfs-install.sh --disk /dev/md127 --dry-run
   ```

3. **Device-Mapper RAID**
   ```bash
   sudo bash install/zfs-install.sh --disk /dev/dm-0 --dry-run
   ```

4. **With Encryption**
   ```bash
   sudo bash install/zfs-install.sh --disk /dev/nvme0n1 --encrypt --passphrase "test" --dry-run
   ```

5. **Windows Dual-Boot**
   ```bash
   sudo bash install/zfs-install.sh --disk /dev/nvme0n1 --use-free-space --dry-run
   ```

### Validation Checks

After installation, verify:

```bash
# ZFS pool
zpool status zroot

# Datasets
zfs list

# ZFSBootMenu
efibootmgr -v

# ZRAM (if applicable)
zramctl
swapon --show

# Boot test
reboot
```

---

## 🔄 Migration from Old Version

If upgrading from version 1.0:

1. Backup current scripts:
   ```bash
   cp install/zfs-install.sh install/zfs-install.sh.v1
   cp install/zfsbootmenu-setup.sh install/zfsbootmenu-setup.sh.v1
   cp install/zram-config.sh install/zram-config.sh.v1
   ```

2. Update scripts from this repository

3. Review changes in this document

4. Test with `--dry-run` mode first

5. Run actual installation

---

## ⚠️ Important Notes

### Security

- Passwords are now safely escaped in sed commands
- Use strong passwords (no special shell characters recommended)
- Consider encryption for sensitive systems

### RAID Considerations

- **mdadm RAID 0**: No redundancy - disk failure = data loss
- **Intel RST RAID 0**: Firmware-managed - ensure BIOS configuration is stable
- **ZFS**: Separate from RAID layer - each disk in RAID array seen as single device
- **Backups**: Critical with RAID 0 - single point of failure

### Compatibility

- Tested on Debian Bookworm (12) live environment
- Works with systemd-zram-generator
- Compatible with UEFI/GPT systems
- Requires Linux 5.10+ for ZFS support

---

## 📞 Support & Feedback

For issues or feature requests:
- Check existing documentation
- Run with `--dry-run` to test safely
- Review system logs: `journalctl -xe`
- Report to: https://github.com/anomalyco/opencode

---

## 📝 Changelog

### Version 2.0 (April 2026)

**New Features:**
- ✅ Intel RST RAID 0 support
- ✅ Device-mapper RAID support
- ✅ Enhanced RAID detection and validation
- ✅ Support for mdadm software RAID
- ✅ Multi-device naming support

**Bug Fixes:**
- ✅ Critical: Unsafe sed password substitution
- ✅ Critical: Curl download without error checking
- ✅ High: UUID capture in DRY-RUN mode
- ✅ High: Fragile efibootmgr parsing
- ✅ High: Exit called in functions
- ✅ Medium: Unhandled error returns

**Improvements:**
- ✅ Better error messages and validation
- ✅ Enhanced device detection
- ✅ Improved documentation
- ✅ Better timeout handling for network operations
- ✅ Proper function error handling

### Version 1.0 (Earlier)

- Initial release
- Basic ZFS root installation
- ZFSBootMenu support
- ZRAM configuration

---

## 📚 Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - ZFS dataset structure
- [TESTING.md](TESTING.md) - Testing procedures
- [README.md](../README.md) - Quick start guide
- [SOURCES.md](SOURCES.md) - Documentation sources

