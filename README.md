# Debian Bookworm ZFS Root + ZFSBootMenu + ZRAM

Automated Debian Bookworm (12) installation with ZFS root filesystem, ZFSBootMenu bootloader, and ZRAM compressed swap.

## 📋 Features

- **ZFS Root** — Root filesystem on ZFS with compression=lz4, autotrim, ACL
- **ZFSBootMenu** — Modern bootloader with snapshot support and custom kernels
- **ZRAM** — Compressed RAM swap via systemd-zram-generator (60% RAM, zstd)
- **UEFI** — UEFI boot support with EFI System Partition
- **Encryption** — Optional ZFS native encryption (AES-256-GCM)
- **Custom ISO** — Build your own Live image via live-build

## 🗂 Project Structure

```
debian-zfs/
├── README.md                      # This file
├── Makefile                       # Build automation for ISO
├── install/
│   ├── zfs-install.sh             # Main ZFS root installation script
│   ├── zfsbootmenu-setup.sh       # ZFSBootMenu setup
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
│       │   └── etc/
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
# Download Debian Bookworm netinst or live ISO
# https://www.debian.org/download

# In the live environment, run:
sudo -i
git clone <this repository>
cd debian-zfs
```

### 2. Install ZFS Root

```bash
# Check disks
lsblk

# Edit variables in install/zfs-install.sh:
# DISK="/dev/sda"  # your disk
# BOOT_PART="1"    # EFI partition
# POOL_PART="2"    # ZFS partition

# Run installation (without encryption):
sudo bash install/zfs-install.sh --disk /dev/sda

# Or with encryption:
sudo bash install/zfs-install.sh --disk /dev/sda --encrypt --passphrase "YOUR_PASSPHRASE"
```

### 3. Setup ZFSBootMenu

```bash
# Automatic setup:
sudo bash install/zfsbootmenu-setup.sh

# Or manually follow instructions in docs/ARCHITECTURE.md
```

### 4. Configure ZRAM

```bash
# Install and configure ZRAM:
sudo bash install/zram-config.sh
```

## 🛠 Building Custom ISO

```bash
# Install dependencies (Debian):
sudo apt install live-build

# Build ISO:
make build

# Or directly:
sudo bash scripts/build-iso.sh

# Write to USB:
sudo bash scripts/usb-write.sh /dev/sdX  # WARNING: use correct disk!
```

## 🧪 Testing in QEMU

```bash
# Test ISO in virtual machine:
make test

# Or directly:
bash scripts/test-vm.sh output/debian-zfs.iso

# Test installed system:
bash scripts/test-vm.sh --disk /dev/sdX
```

## 📦 Package Versions (April 2026)

| Package | Version | Source |
|---------|---------|--------|
| zfsutils-linux | 2.3.2+ (backports) | bookworm-backports |
| zfs-initramfs | 2.3.2+ (backports) | bookworm-backports |
| ZFSBootMenu | 3.1.x | get.zfsbootmenu.org |
| systemd-zram-generator | 1.1.2+ | bookworm |
| linux-image-amd64 | 6.1.x LTS | bookworm |

## ⚠️ Important Notes

1. **ZFS is not included in Debian Installer** due to licensing restrictions — installation is done manually via debootstrap
2. **ZFSBootMenu replaces GRUB** — do not install GRUB when using ZFSBootMenu
3. **Do not use zram-tools and systemd-zram-generator simultaneously** — choose one (systemd is recommended)
4. **EFI backup** — always backup VMLINUZ.EFI before updates

## 📚 Documentation

- [Architecture and Dataset Structure](docs/ARCHITECTURE.md)
- [Testing Guide](docs/TESTING.md)
- [Sources and Documentation](docs/SOURCES.md)

## 🔗 Sources

- [Official OpenZFS Documentation — Debian Bookworm](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)
- [ZFSBootMenu Documentation](https://docs.zfsbootmenu.org/)
- [Debian Wiki — ZFS](https://wiki.debian.org/ZFS)
- [Debian Wiki — ZRAM](https://wiki.debian.org/ZRam)

## 📄 License

MIT License — use at your own risk. ZFS has CDDL license which may be incompatible with GPL.
