# Debian Trixie ZFS Root + ZFSBootMenu Installer

Automated Debian Trixie (13) installation with ZFS root filesystem and ZFSBootMenu bootloader.

## Features

- **ZFS Root** — Root filesystem on ZFS with compression=lz4, autotrim, ACL
- **ZFSBootMenu** — Modern bootloader with snapshot support
- **UEFI** — UEFI boot support with dedicated EFI System Partition
- **Single script** — `install/zfsinstall.sh` does everything from partition to boot

## Project Structure

```
debian-zfs/
├── README.md                    # This file
├── Makefile                     # Build automation
├── install/
│   └── zfsinstall.sh            # Single installer script
└── docs/
    ├── ARCHITECTURE.md          # Architecture and dataset structure
    ├── TESTING.md               # Testing guide
    └── SOURCES.md               # Documentation sources
```

## Quick Start

### 1. Prepare Live Environment

Boot a Debian Trixie live environment, then:

```bash
sudo -i
git clone <this repository>
cd debian-zfs
```

### 2. Run Installer

```bash
sudo bash install/zfsinstall.sh
```

The script will:
1. Add trixie-backports and install ZFS packages
2. Ask for EFI partition, ZFS partition, and hostname
3. Format EFI, create ZFS pool and datasets
4. debootstrap the base system
5. Install kernel, ZFS, ZFSBootMenu inside the chroot
6. Create UEFI boot entry for ZFSBootMenu

### 3. Reboot

```bash
reboot
```

## Building Custom ISO

```bash
sudo apt install live-build
sudo make build
```

## Testing in QEMU

```bash
make test
```

## Documentation

- [Architecture and Dataset Structure](docs/ARCHITECTURE.md)
- [Testing Guide](docs/TESTING.md)
- [Sources and Documentation](docs/SOURCES.md)
