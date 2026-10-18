# MacBook A1398 Keyboard Fix Guide

## The Problem

On Apple MacBooks (especially Retina models: A1398 2012-2015), the built-in keyboard/trackpad requires **USB/HID drivers** that are not in the mainline kernel. When booting ZFSBootMenu, you see a menu but can't type to select snapshots because the keyboard isn't passed through.

## Your Solution: Use `--macbook` Flag

Your current project (`debian-zfs`) has **complete support** for this issue via the `--macbook` flag!

### Fresh Installation (Recommended)

```bash
# Clone and run installer with MacBook support
sudo python3 install/debian_zfs_install.py --disk /dev/sdXY --macbook

# Or interactive mode (will ask)
sudo python3 install/debian_zfs_install.py
# When asked "Enable MacBook drivers?", answer: y
```

### Already Installed? Fix Existing Installation

If you already installed WITHOUT `--macbook`, fix now:

```bash
# From live USB or installed system
sudo python3 install/zbm_setup.py --macbook
```

This will:
1. Add USB/HID drivers for built-in keyboard/trackpad
2. Add Apple boot fallback loader (for recovery)
3. Include Wi-Fi driver (`broadcom-sta-dkms`) if needed

### Build Custom ISO with MacBook Support

```bash
sudo apt install live-build
sudo python3 scripts/build_iso.py --macbook
# Use resulting .iso for all future installations
```

## How It Works

The `--macbook` flag:

1. **Adds initramfs modules**: `kbd_usb`, `libinput`, etc. to the ZFSBootMenu initramfs
2. **Creates `/etc/zfsbootmenu/dracut.conf.d/20-apple-input.conf`**: Loads USB HID drivers early
3. **Adds Apple fallback EFI**: Boot partition for macOS recovery if system fails to boot
4. **Installs Broadcom Wi-Fi driver**: For BCM4331 (2012) and BCM4360 (2013-2015)

## Verification

After installation with `--macbook`:

```bash
# Check the EFI image contains keyboard support
objcopy -O binary --only-section=.initrd /boot/efi/EFI/ZBM/VMLINUZ.EFI /tmp/zbm-img
lsinitrd /tmp/zbm-img | grep -iE 'usb|kbd|hid'

# Check configuration file exists
cat /etc/zfsbootmenu/dracut.conf.d/20-apple-input.conf

# Verify the hooks directory has setup hooks
ls -la /etc/zfsbootmenu/hooks/early-setup.d/
```

## What You DON'T Need

- ❌ `archinstall_zfs` - That project doesn't exist anymore (404 errors)
- ❌ Manual driver compilation
- ❌ Modifying EFI binaries directly

## If Keyboard STILL Doesn't Work

1. **Check ZBM splash screen**: Do you see "Apple Boot" or "UEFI Shell" options?
2. **Verify EFI image**: Run the verification commands above
3. **Manual rebuild** (last resort):
   ```bash
   sudo python3 install/zbm_setup.py --macbook --force-rebuild
   ```

## For ISO Installation Only

If you're building an ISO to deploy:

```bash
sudo apt install live-build
sudo python3 scripts/build_iso.py \
    --macbook \          # Add keyboard/Wi-Fi support
    --hostname mymac      # Set hostname
make iso                 # Build the ISO
```

Then use that ISO for all A1398 installations.

## Command Reference

| Command | Purpose | When to Use |
|---------|---------|--------------|
| `debian_zfs_install.py --macbook` | Fresh install with keyboard support | New system installation |
| `zbm_setup.py --macbook` | Add MacBook drivers to existing system | Fix broken/boot menu without keyboard |
| `build_iso.py --macbook` | Build ISO with Wi-Fi drivers in live media | Creating deployment ISOs only |

## Troubleshooting

### Problem: No boot menu after reboot
```bash
# Check EFI boot entries
efibootmgr -v

# Should see "ZFSBootMenu" entry; if not, reinstall:
sudo python3 install/zbm_setup.py --macbook
```

### Problem: Apple Boot option missing
This should show up in ZBM boot menu. Verify with:
```bash
file /boot/efi/EFI/ZBM/VMLINUZ.EFI
# Should be a unified kernel binary or EFI executable
```

### Problem: Wi-Fi not working
Built-in Broadcom Wi-Fi needs `broadcom-sta-dkms`:
```bash
# From live media with ISO built via --macbook:
sudo apt install broadcom-sta-dkms
# Or after fresh install, add --macbook to reinstall ZBM
sudo python3 install/zbm_setup.py --macbook
```

## Summary

✅ **Your project has full MacBook keyboard support**  
✅ **Use `--macbook` flag with any installation**  
✅ **Don't look for archinstall_zfs - it's gone**  
✅ **Run verification commands to confirm proper install**

---

**Last Updated:** 2026-09-29  
**Status:** Production Ready