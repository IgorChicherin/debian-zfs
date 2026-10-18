# debian-zfs

Install Debian on a ZFS root with ZFSBootMenu and zram (UEFI only).

- ZFS root, native encryption optional, boot environments (`<pool>/ROOT/<be>`)
- Debian 13 "trixie" (default) or sid: `--release stable|sid`
- ZFSBootMenu built on the machine being installed
- zram swap through `systemd-zram-generator` (60% of RAM, max 4 GiB, `zstd`)
- `zfs-kernel-guard` keeps kernel updates from breaking ZFS (`--no-kernel-guard` to skip)
- optional md RAID (Intel RST / mdadm) root: pass the RAID volume, e.g. `--disk /dev/md126`
- MacBook support: `--macbook` (ZFSBootMenu keyboard drivers, Apple fallback loader, Broadcom `wl` Wi-Fi)

## Install

From a Debian live system:

```sh
sudo python3 install/debian_zfs_install.py --interactive
sudo python3 install/debian_zfs_install.py --disk /dev/disk/by-id/... --password ...
sudo python3 install/debian_zfs_install.py --disk /dev/nvme0n1 --use-free-space      # next to Windows
sudo python3 install/debian_zfs_install.py --select-partitions                         # prepared partitions
sudo python3 install/debian_zfs_install.py --use-existing-pool                         # new boot environment
sudo python3 install/debian_zfs_install.py --disk /dev/md126 --password ...            # Intel RST volume, not the md127 container
```

Add `--dry-run` to print every command without running it. Guides in [docs/](docs/):
[RAID0 quick start](docs/QUICK_START_RAID0.md),
[existing pool](docs/EXISTING_POOL_INSTALLATION.md),
[MacBook keyboard](docs/KEYBOARD_FIX_GUIDE.md).

## Layout

```
install/
  debian_zfs_install.py   orchestrator and host preparation
  plan.py                 command line, wizard, Plan
  target.py               device validation, disk / free space / partition layout
  zfsops.py               pool, datasets, key loading, existing pools
  system.py               debootstrap, chroot, system configuration
  devices.py              lsblk / sysfs / md RAID / hardware lookups
  dzlib.py                logging, command runner, prompts, Debian releases
  zbm_setup.py            ZFSBootMenu install (also usable on an installed system)
  zram_config.py          zram swap (--status, --remove)
  zbm_check_kernels.py    "ZFSBootMenu failed to find kernels" check and fix
  mdraid_rescue.py        live-ISO repair of an installed system on an md RAID that does not boot
  zfs_kernel_guard.py     installed into the new system
scripts/                  build_iso.py, test-vm.py, usb-write.py
config/                   live-build tree, ZFSBootMenu config
tests/                    unit tests
docs/                     guides
```

## Rescue: installed system on md RAID does not boot

Symptoms: ZFSBootMenu shows no pool, or the kernel drops to an initramfs shell. From the live ISO:

```sh
sudo python3 install/mdraid_rescue.py        # alias in the live system: zbm-rescue
```

It assembles the arrays, finds the pool (default scan, then `-d /dev`, `-d /dev/disk/by-id`, `-d` each md
partition, then `zdb -l`), imports it under `/mnt`, mounts a boot environment, its datasets and the ESP, runs
`zbm_setup.py --mdraid --update` inside the installed system (mdadm.conf, dracut config, assemble hook,
`rd.auto=1`, initramfs, ZFSBootMenu image, firmware entry) and unmounts and exports the pool.

## Build the live ISO

Needs a Debian host (or Ubuntu on a native Linux filesystem), root and about 10 GB free.

```sh
sudo apt install live-build debian-archive-keyring qemu-system-x86 ovmf
make build                 # runs sudo itself -> output/debian-zfs-live.iso
make vm                    # boot it in QEMU
make usb USB=/dev/sdX      # write it to a stick
```

Without a Debian host, build in Docker (needs `--privileged` for live-build's chroot; output files stay owned by you):

```sh
make docker-build                                   # -> output/debian-zfs-live.iso
make docker-build ARGS="--macbook --release sid"    # options for scripts/build_iso.py
make docker-clean                                   # delete the build tree (Docker volume debian-zfs-work)
```

The build tree is a Docker volume, not `live-build-work/`, so it also works from a `nodev` checkout (e.g. ZFS `devices=off`).

In the live system run `zfs-install --interactive`. Build locally; do not publish the image.

## Adding drivers to ZFSBootMenu

If a keyboard, storage controller or network card does not work in the boot menu:

1. Find the module on the live system: `lsmod`, `lspci -k`, `dmesg`.
2. On an installed system:
   ```sh
   echo 'add_drivers+=" mod1 mod2 "' > /etc/zfsbootmenu/dracut.conf.d/20-extra-drivers.conf
   generate-zbm
   ```
   MacBooks: `python3 install/zbm_setup.py --macbook`.

## zram

On an installed system: `python3 install/zram_config.py --status`.

## Tests

```sh
make test
```

## Licensing note

ZFS is CDDL and the Linux kernel is GPLv2. An image that bundles a built ZFS module is legally contested
to redistribute. This repository ships build scripts, not images: build locally, do not publish.
