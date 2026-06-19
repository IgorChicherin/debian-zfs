# Debian Trixie ZFS Root + ZFSBootMenu + ZRAM

Automated Debian Trixie (13) installation with ZFS root filesystem, ZFSBootMenu bootloader, and ZRAM compressed swap.

## 📋 Features

- **ZFS Root** — Root filesystem on ZFS with compression=lz4, autotrim, ACL
- **ZFSBootMenu** — Modern bootloader with snapshot support and custom kernels
- **ZRAM** — Compressed RAM swap via systemd-zram-generator (60% RAM, zstd)
- **UEFI** — UEFI boot support with dedicated 1GB EFI System Partition
- **Encryption** — Optional ZFS native encryption (AES-256-GCM)
- **Custom ISO** — Build your own Live image via live-build
- **Windows dual-boot** — Install alongside Windows using free GPT space with dedicated EFI partition

## 🗂 Project Structure

```
debian-zfs/
├── README.md                      # This file
├── Makefile                       # Build automation for ISO
├── install/
│   ├── zfs-install.sh             # Main ZFS root installation script
│   ├── zfsbootmenu-setup.sh       # ZFSBootMenu setup
│   ├── zbm-check-kernels.sh       # Check and fix ZFSBootMenu kernel detection
│   ├── fix-boot.sh                # Fix "no boot environments found" after install
│   └── zram-config.sh             # ZRAM configuration
├── config/
│   ├── zfsbootmenu/
│   │   └── config.yaml            # ZFSBootMenu configuration
│   ├── zram/
│   │   └── zram-generator.conf    # ZRAM configuration
│   └── live-build/                # ISO build configuration
│       ├── package-lists/
│       │   └── zfs.list.chroot
│       ├── includes.chroot/
│       │   ├── etc/install/       # Scripts embedded in live ISO
│       │   └── root/debian-zfs/   # Full project copy in live ISO
│       ├── hooks/
│       │   └── live.hook.chroot   # Permissions hook
│       └── auto/
│           └── config
├── scripts/
│   ├── build-iso.sh               # Custom ISO build script
│   ├── test-vm.sh                 # QEMU testing script
│   └── usb-write.sh               # USB drive writing script
└── docs/
    ├── ARCHITECTURE.md            # Architecture and dataset structure
    ├── TESTING.md                 # Testing guide
    └── SOURCES.md                 # Documentation sources
```

## 🚀 Quick Start

### 1. Prepare Live Environment

```bash
# Download Debian Trixie live ISO or use the custom ISO from this project
# https://www.debian.org/download

# In the live environment, run:
sudo -i
git clone <this repository>
cd debian-zfs
```

Or if using the custom ISO built from this project, scripts are already at `/root/debian-zfs/`.

### 2. Install ZFS Root

```bash
# Check disks
lsblk

# Fresh install (wipes entire disk):
sudo bash install/zfs-install.sh --disk /dev/sda

# With encryption:
sudo bash install/zfs-install.sh --disk /dev/sda --encrypt --passphrase "YOUR_PASSPHRASE"

# Install alongside Windows (creates dedicated 1GB EFI in free GPT space):
sudo bash install/zfs-install.sh --disk /dev/nvme0n1 --use-free-space

# Install alongside Windows reusing an existing EFI partition (must be >= 1GB):
sudo bash install/zfs-install.sh --disk /dev/nvme0n1 --use-free-space --efi-part 1

# Intel RST RAID 0:
sudo bash install/zfs-install.sh --disk /dev/md127 --use-free-space
```

### 3. If Boot Fails — Run Fix Script

If ZFSBootMenu shows **"no boot environments found"** after reboot, boot back into the live ISO and run:

```bash
sudo bash /root/debian-zfs/install/fix-boot.sh
```

This automatically:
- Imports the ZFS pool
- Fixes boot environment properties (`bootfs`, `mountpoint`, `canmount`, `org.zfsbootmenu:commandline`)
- Reinstalls kernel/initramfs if missing
- Fixes EFI fallback path (`EFI/BOOT/BOOTX64.EFI`)
- Recreates NVRAM boot entries

### 4. Setup ZFSBootMenu (manual)

```bash
# If ZFSBootMenu needs to be (re)configured manually:
sudo bash install/zfsbootmenu-setup.sh
```

### 5. Configure ZRAM

```bash
sudo bash install/zram-config.sh
```

## 🛠 Building Custom ISO

The ISO includes all project scripts at `/root/debian-zfs/` so no cloning is needed.

```bash
# Install dependencies:
sudo apt install live-build

# Build ISO:
sudo make build

# Write to USB:
sudo bash scripts/usb-write.sh /dev/sdX  # WARNING: use correct disk!
```

## 🧪 Testing in QEMU

```bash
# Test ISO in virtual machine:
make test

# Test installed system:
bash scripts/test-vm.sh --disk /dev/sdX
```

## 📦 Package Versions (June 2026)

| Package | Version | Source |
|---------|---------|--------|
| zfsutils-linux | 2.3.5+ (backports) | trixie-backports |
| zfs-initramfs | 2.3.5+ (backports) | trixie-backports |
| zfs-dkms | 2.3.5+ (backports) | trixie-backports |
| ZFSBootMenu | 3.1.x | get.zfsbootmenu.org |
| systemd-zram-generator | 1.1.2+ | trixie |
| linux-image-amd64 | 6.12.x | trixie |

## ⚠️ Important Notes

1. **ZFS is not included in Debian Installer** due to licensing restrictions — installation is done manually via debootstrap
2. **ZFSBootMenu replaces GRUB** — do not install GRUB when using ZFSBootMenu
3. **Disable Secure Boot** — ZFSBootMenu EFI binary is not signed; Secure Boot must be off
4. **Do not use zram-tools and systemd-zram-generator simultaneously** — choose one (systemd is recommended)
5. **EFI partition size** — installer creates a dedicated 1GB EFI partition; the Windows 100MB EFI is too small for ZFSBootMenu
6. **Windows dual-boot** — use `--use-free-space`; shrink the Windows partition first to leave unallocated GPT space

## 🐛 Troubleshooting

### ZFSBootMenu: "no boot environments found"

Boot from live ISO and run the fix script:

```bash
sudo bash /root/debian-zfs/install/fix-boot.sh
# or with explicit EFI partition:
sudo bash /root/debian-zfs/install/fix-boot.sh --efi-disk /dev/sda --efi-part 1
```

### ZFSBootMenu: "failed to find kernels"

```bash
sudo bash /root/debian-zfs/install/zbm-check-kernels.sh \
    --pool zroot --dataset ROOT/trixie --fix
```

### ZFS package conflicts

If you see `libzfs6linux` / `libzfs7linux` conflicts:

```bash
sudo apt remove -y libzfs6linux libuutil3linux libnvpair3linux libzpool6linux || true
sudo apt install -y -t trixie-backports zfsutils-linux zfs-initramfs zfs-dkms
```

### ZRAM not activating

```bash
sudo bash install/zram-config.sh --status
```

## 📚 Documentation

- [Architecture and Dataset Structure](docs/ARCHITECTURE.md)
- [Existing Pool Installation](EXISTING_POOL_INSTALLATION.md)
- [Intel RST RAID 0 Quick Start](QUICK_START_RAID0.md)
- [Testing Guide](docs/TESTING.md)
- [Sources and Documentation](docs/SOURCES.md)

## 🔗 Sources

- [Official OpenZFS Documentation — Debian](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)
- [ZFSBootMenu Documentation](https://docs.zfsbootmenu.org/)
- [Debian Wiki — ZFS](https://wiki.debian.org/ZFS)
- [Debian Wiki — ZRAM](https://wiki.debian.org/ZRam)

## 📄 License

MIT License — use at your own risk. ZFS has CDDL license which may be incompatible with GPL.
