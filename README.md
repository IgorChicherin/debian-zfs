# Debian 13 / sid on ZFS Root + ZFSBootMenu + ZRAM

Automated installation of **Debian 13 "trixie" (stable, default)** or **Debian sid
(unstable)** on a ZFS root filesystem, booted by **ZFSBootMenu**, with ZRAM
compressed swap. It installs onto a whole disk, into free space next to Windows,
onto partitions you prepared yourself, or into an existing ZFS pool.

## 📋 Features

- **ZFS root:** lz4 compression, autotrim, POSIX ACLs, optional native encryption (AES-256-GCM)
- **ZFSBootMenu:** boots boot environments and snapshots; downloaded prebuilt, or built locally when extra drivers are needed
- **Four install targets:** whole disk, free space next to Windows, prepared partitions, existing pool; plus a guided wizard
- **Debian branch choice:** `--release stable` (Debian 13) or `--release sid`, both side by side in one pool if you like
- **Intel RST RAID 0 (NVMe):** md/imsm detection, ZFSBootMenu built with mdadm support
- **MacBook support** (`--macbook`): built-in keyboard in the boot menu, Apple boot fallback, Broadcom Wi-Fi
- **Kernel-update protection:** `zfs-kernel-guard` blocks kernels that OpenZFS doesn't support and keeps the machine bootable
- **Optional network + SSH inside ZFSBootMenu**, for wired adapters
- **ZRAM swap** via systemd-zram-generator (60% of RAM, max 4 GiB, zstd)
- **Custom live ISO** with the installer, plus QEMU test and USB writer tools
- **Python 3 only.** The standard library is enough, and every tool has `--help` and `--dry-run`.

## 🗂 Project Structure

```
debian-zfs/
├── README.md
├── QUICK_START_RAID0.md           # Intel RST RAID 0 walkthrough + emergency boot
├── EXISTING_POOL_INSTALLATION.md  # installing into an existing pool
├── Makefile                       # make build / test / test-install / usb / lint
├── install/                       # Python 3, standard library only
│   ├── zfs-install.py             # main installer (all targets, wizard)
│   ├── zfsbootmenu-setup.py       # ZFSBootMenu setup (--mdraid, --macbook, --network)
│   ├── zfs-kernel-guard.py        # kernel-update protection (standalone)
│   ├── zbm-check-kernels.py       # fix "failed to find kernels"
│   ├── zram-config.py             # ZRAM configuration
│   └── dzlib.py                   # shared helpers (keep next to the scripts)
├── config/
│   ├── zfsbootmenu/
│   │   ├── config.yaml                                 # reference configuration
│   │   ├── dracut.conf.d/10-mdraid.conf                # Intel RST / mdadm support
│   │   └── hooks/early-setup.d/10-mdraid-assemble.sh   # runs inside ZBM (sh)
│   ├── zram/zram-generator.conf
│   └── live-build/                # ISO: package lists, optional/macbook.list.chroot, live files
├── scripts/
│   ├── build-iso.py               # build the live ISO (--release, --macbook)
│   ├── test-vm.py                 # QEMU: ISO, disk, empty NVMe install disks
│   └── usb-write.py               # write the ISO to a USB drive
└── docs/                          # architecture, testing, sources
```

## 🚀 Quick Start

### 1. Boot a live system

Boot a Debian live ISO (13 recommended; 12 works too) or the custom ISO from
`make build`, in **UEFI mode**. Then:

```bash
sudo -i
nmtui                      # connect to the network if needed (Wi-Fi)
git clone <this repository> && cd debian-zfs
lsblk
```

`python3` is on Debian live images; otherwise run `apt install python3`.

### 2. Install

The installer does everything:

- partitions and the pool
- debootstrap, kernel, and ZFS via DKMS
- ZFSBootMenu and its EFI entries
- NetworkManager, ZRAM and `zfs-kernel-guard`

```bash
sudo python3 install/zfs-install.py --interactive       # guided wizard
```

Or pick the target directly:

| Target | Command | What is erased |
|---|---|---|
| **Whole disk** | `--disk /dev/nvme0n1` | the entire disk |
| **Free space next to Windows** | `--disk /dev/nvme0n1 --use-free-space` | nothing (new partition in free space, ESP reused) |
| **Prepared partitions** | `--select-partitions` or `--pool-part /dev/nvme0n1p5 --efi-device /dev/nvme0n1p1` | only the chosen pool partition |
| **Existing ZFS pool** | `--use-existing-pool` or `--pool zroot --efi-device /dev/sda1` | nothing (new or chosen boot environment) |

```bash
sudo python3 install/zfs-install.py --disk /dev/sda                     # Debian 13, whole disk
sudo python3 install/zfs-install.py --disk /dev/sda --encrypt           # with ZFS encryption
sudo python3 install/zfs-install.py --disk /dev/sda --release sid       # Debian sid
sudo python3 install/zfs-install.py --select-partitions --hostname nas  # prepared partitions
sudo python3 install/zfs-install.py --disk /dev/md126                   # Intel RST RAID 0 volume
sudo python3 install/zfs-install.py --disk /dev/sda --macbook           # MacBook
sudo python3 install/zfs-install.py --disk /dev/sda --dry-run           # only show the commands
```

<details>
<summary>All installer options</summary>

| Option | Meaning |
|---|---|
| `--release stable\|sid` | Debian branch (default `stable` = Debian 13 trixie) |
| `--pool-name NAME` | name of a new pool (default `zroot`) |
| `--boot-env NAME` | boot environment `<pool>/ROOT/NAME` (default: release codename) |
| `--esp-size SIZE` | ESP size in whole-disk mode (default `+512M`) |
| `--efi-part N` | ESP partition number for `--use-free-space` (auto-detected otherwise) |
| `--format-efi` | format the chosen ESP (prepared partitions / existing pool) |
| `--encrypt`, `--passphrase P` | ZFS native encryption (passphrase prompted if omitted) |
| `--hostname NAME`, `--password P` | hostname, root password (prompted if omitted) |
| `--macbook` | MacBook drivers (see below) |
| `--zbm-network --ssh-key FILE` | wired network + SSH inside ZFSBootMenu |
| `--no-kernel-guard` | do not install zfs-kernel-guard |
| `--skip-packages` | do not `apt-get install` on the live system |
| `--dry-run`, `--yes` | print commands only / never ask (dangerous) |

</details>

### 3. Reboot

Remove the USB drive and pick **ZFSBootMenu** in the firmware boot menu. On a
Mac, hold Option and pick **EFI Boot**. Press **ESC** during the countdown to
open the menu: boot environments, snapshots, kernels (Ctrl+K), recovery shell.

After installation (optional):

```bash
sudo python3 install/zfsbootmenu-setup.py --update   # refresh ZFSBootMenu
zfs-kernel-guard check                               # ZFS status of every kernel
sudo python3 install/zram-config.py --status         # ZRAM (--size, --remove)
```

## 💿 Install targets in detail

### Prepared partitions

Create the partitions beforehand with any tool, such as gdisk, GParted or
Windows Disk Management. For example, leave a partition for Linux and keep the
existing ESP.

`--select-partitions` lists only partitions that meet all of these:

- unmounted
- at least 8 GiB
- not an ESP or a Microsoft Reserved partition
- not a RAID member disk or container
- not part of an imported pool

Partitions that still contain NTFS, ext4 or ZFS data are flagged. Then it lists
FAT/EFI partitions for the ESP:

- An existing FAT ESP is **reused**, so the Windows boot files stay.
- A non-FAT partition is formatted only after confirmation or with `--format-efi`.
  It is never formatted if it holds NTFS/Linux data or is larger than 4 GiB.

Only the selected pool partition is wiped. The partition table is not changed.

### Free space next to Windows

Shrink the Windows partition in Windows Disk Management so the space is left
**unallocated** (GPT). The installer creates a ZFS partition in the largest
free block (at least 20 GiB) and reuses the existing EFI partition.

### Existing pool

This installs into a new boot environment `<pool>/ROOT/<name>`, or overwrites a
chosen existing one, and sets it as `bootfs`. This way Debian 13 and sid can
share one pool:

```bash
sudo python3 install/zfs-install.py --pool zroot --efi-device /dev/sda1 --release sid
```

See [EXISTING_POOL_INSTALLATION.md](EXISTING_POOL_INSTALLATION.md).

### Datasets created

| Dataset | Mountpoint |
|---|---|
| `<pool>/ROOT` | none (container for boot environments) |
| `<pool>/ROOT/trixie` or `.../sid` | `/` (canmount=noauto, `bootfs`) |
| `<pool>/home` | `/home` |
| `<pool>/var-log` | `/var/log` |

The pool uses `ashift=12` and `compatibility=openzfs-2.2-linux`, so older
rescue media and the prebuilt ZFSBootMenu can import it.

## 🌿 Debian branch: stable or sid

| `--release` | Installs | Boot environment | Notes |
|---|---|---|---|
| `stable` (default) | Debian 13 "trixie" | `<pool>/ROOT/trixie` | security + updates suites; kernel 6.12 LTS |
| `sid` | Debian unstable | `<pool>/ROOT/sid` | rolling; ZFS (DKMS) can lag behind new kernels |

APT sources are written in deb822 format (`/etc/apt/sources.list.d/debian.sources`)
with `main contrib non-free non-free-firmware`. OpenZFS comes from `contrib`,
so no backports are needed. The installer stops if DKMS didn't build `zfs.ko`
for every installed kernel, because such a system can't boot.

## 🛡 Kernel-update protection (zfs-kernel-guard)

A kernel that OpenZFS doesn't support yet (common on **sid**) gets no
`zfs.ko`, and the system can't import its root pool. `zfs-kernel-guard` is
installed on every new system (`--no-kernel-guard` skips it) and hooks into
apt and the kernel packages:

| When | What it does |
|---|---|
| **Before** apt installs a kernel | Compares the kernel with the range zfs-dkms supports (`Linux-Minimum`/`Linux-Maximum` in its `META`, including a zfs-dkms upgrade in the same apt run). If the kernel is outside the range, the **apt run is stopped** before anything is installed. |
| **After** every apt/dpkg run | Checks every kernel in `/boot`: `zfs.ko` built by DKMS, and `zfs.ko` inside the initramfs. It retries a failed DKMS build once per zfs-dkms version and rebuilds an initramfs that lacks `zfs.ko`. |
| Newest kernel still broken | Warns and **pins ZFSBootMenu** (`org.zfsbootmenu:kernel`) to the newest working kernel, so the machine keeps booting. The pin is removed automatically once the newest kernel works. A pin you set yourself is never changed. |

```bash
zfs-kernel-guard check                             # status of every kernel
sudo zfs-kernel-guard reconcile                    # fix / pin / unpin now
ZFS_KERNEL_GUARD=off sudo apt upgrade              # skip the guard for one run
sudo python3 install/zfs-kernel-guard.py install   # add it to an existing system
sudo zfs-kernel-guard uninstall
```

Settings are in `/etc/default/zfs-kernel-guard`:

- `PREINSTALL=block|warn|off`
- `AUTO_FIX=yes|no`
- `PIN_ZBM=yes|no`

## 🧱 Intel RST RAID 0 (2× NVMe)

Pass the RAID **volume** (usually `/dev/md126` or `/dev/md/Volume0_0`). Don't
pass the imsm container (usually `/dev/md127`) or a member NVMe disk; the
installer refuses those and names the correct volume.

The prebuilt ZFSBootMenu can't assemble RST arrays, so ZBM is built locally with:

- the dracut `mdraid` module and `mdadm.conf`
- the `vmd`, `md_mod` and `raid0` drivers
- `rd.auto=1` on the ZBM command line
- an early-setup hook that runs `mdadm --assemble --scan`

The Debian initramfs gets the same modules. If `efibootmgr` can't create an
entry on the md device, the setup falls back to raid-disk 0 and then to
`\EFI\BOOT\BOOTX64.EFI`.

```bash
cat /proc/mdstat                                        # find the volume
sudo python3 install/zfs-install.py --disk /dev/md126
sudo python3 install/zfsbootmenu-setup.py --mdraid      # existing installs
```

Details and the emergency boot procedure are in
[QUICK_START_RAID0.md](QUICK_START_RAID0.md).

## 🍏 MacBook (A1398 MacBook Pro Retina 2012–2015 and similar)

MacBook support is a separate option, `--macbook`. On Apple hardware without
it, the scripts only print a hint. In the wizard it's a yes/no question that
defaults to *yes* on a Mac.

```bash
sudo python3 install/zfs-install.py --disk /dev/sda --macbook      # new install
sudo python3 install/zfsbootmenu-setup.py --macbook                # existing install
sudo python3 install/zfsbootmenu-setup.py --no-macbook             # remove again
sudo python3 scripts/build-iso.py --macbook                        # live ISO with Mac Wi-Fi
```

`--macbook` enables:

- **Keyboard in ZFSBootMenu.** ZBM is built locally with the drivers for the
  built-in keyboard and trackpad loaded early: `xhci_pci`, `ehci_pci`, `usbhid`,
  `hid_apple`, `bcm5974`, plus `applespi` for SPI-keyboard models. The prebuilt
  image may lack these, which leaves the internal keyboard dead in the menu.
- **Apple boot fallback.** ZBM is also installed as `\EFI\BOOT\BOOTX64.EFI`,
  because Apple firmware often ignores Linux boot entries. Hold **Option (⌥)**
  at power-on and pick **EFI Boot**.
- **Wi-Fi.** The Broadcom BCM4331/BCM4360 gets the proprietary `wl` driver
  (`broadcom-sta-dkms`, non-free). The Wi-Fi connection used on the live USB is
  copied to the new system. Use `nmtui` to change networks.
- **Live ISO.** `build-iso.py --macbook` adds `broadcom-sta-dkms` to the live
  system, so Wi-Fi works during installation. It isn't in the default ISO
  because the package blacklists the open Broadcom drivers (b43, brcmsmac) on
  every machine. Without it, use a USB/Thunderbolt Ethernet adapter or phone
  USB tethering.

`zfsbootmenu-setup.py` remembers the choice: later runs such as `--update` keep
the MacBook drivers until `--no-macbook`. The same goes for `--network` /
`--no-network`.

## 🔌 Network + SSH inside ZFSBootMenu (optional)

Wi-Fi isn't possible inside ZFSBootMenu, but **wired** networking is: Apple
Thunderbolt Ethernet, USB Ethernet or phone USB tethering, with a dropbear SSH
server.

```bash
sudo python3 install/zfs-install.py --disk /dev/sda --zbm-network --ssh-key ~/.ssh/id_ed25519.pub
sudo python3 install/zfsbootmenu-setup.py --network --ssh-key ~/.ssh/id_ed25519.pub   # later
```

Plug the adapter in **before** powering on. The boot menu gets an address by
DHCP and logs it (`zbm-network: …` in the kernel log). Connect with
`ssh -p 222 root@<ip>` and run `zfsbootmenu`, for example to type the
encryption passphrase or pick a snapshot remotely. Login is by key only.

Dedicated dropbear host keys are generated in `/etc/zfsbootmenu/dropbear/`.
They end up inside the EFI image on the unencrypted ESP, so they are never
your system's own SSH keys.

## 🛠 Building the live ISO

```bash
sudo apt install live-build debian-archive-keyring
make build                                         # = sudo python3 scripts/build-iso.py
sudo python3 scripts/build-iso.py --release sid    # sid live system
sudo python3 scripts/build-iso.py --macbook        # + MacBook Broadcom Wi-Fi driver
sudo python3 scripts/usb-write.py                  # pick the USB drive from a list
```

The ISO contains ZFS, NetworkManager (`nmtui`) and the installer in
`/root/install`. Shortcuts: `zfs-install`, `zfsbootmenu-setup`, `zram-setup`,
`zbm-check`, and `zfs-help`. Build on a native Linux filesystem, not
`/mnt/c/...` under WSL.

## 🧪 Testing in QEMU

```bash
make test                          # boot the ISO
make test-install                  # boot the ISO with an empty 40 GB NVMe install disk
python3 scripts/test-vm.py output/debian-zfs-live.iso --target-disk 40G --raid0   # two NVMe disks
sudo python3 scripts/test-vm.py --disk /dev/sdX --snapshot                        # boot a real disk, no writes
```

QEMU can't emulate Intel RST firmware. To test md RAID 0, create the array in
the VM with mdadm.

## 📦 Package Versions

| Package | Debian 13 (trixie) | sid |
|---------|--------------------|-----|
| zfsutils-linux / zfs-dkms / zfs-initramfs | 2.3.x (contrib) | newest 2.3.x/2.4.x |
| linux-image-amd64 | 6.12 LTS | newest mainline |
| ZFSBootMenu | 3.x prebuilt, or built locally (RAID / MacBook / network) | same |
| systemd-zram-generator | main | main |

Exact versions on the target: `apt-cache policy zfsutils-linux linux-image-amd64`.

## ⚠️ Important Notes

1. **ZFS is not in the Debian Installer** because of licensing, so installation uses debootstrap.
2. **ZFSBootMenu replaces GRUB.** Don't install GRUB on the new system.
3. **Use systemd-zram-generator, not zram-tools** as well.
4. **Boot image backups are automatic.** The previous image is kept as `EFI/ZBM/VMLINUZ-BACKUP.EFI`, with its own "ZFSBootMenu (Backup)" boot entry.
5. **Encryption:** ZFSBootMenu asks for the passphrase at boot. The key file `/etc/zfs/<pool>.key` is copied into the new system (mode 000, initramfs `UMASK=0077`), so Debian normally does not ask a second time.
6. **RAID 0 has no redundancy.** Keep backups; ZFS snapshots are not backups.

## 🐛 Troubleshooting

### ZFSBootMenu: "failed to find kernels"

```bash
sudo python3 install/zbm-check-kernels.py --pool zroot            # dataset from the pool's bootfs
sudo python3 install/zbm-check-kernels.py --pool zroot --fix      # reinstall kernel + initramfs inside it
```

The script mounts the dataset with `mount -t zfs -o zfsutil`, without changing
its mountpoint property, and runs the fix inside it via chroot. It also checks
`bootfs`, `canmount` and `mountpoint`.

### A new kernel doesn't boot / apt stopped a kernel upgrade

```bash
zfs-kernel-guard check     # which kernels have a working zfs.ko
dkms status                # did the zfs build fail?
```

In ZFSBootMenu, press **Ctrl+K** to boot an older kernel. If apt was stopped,
wait for a newer `zfs-dkms`, or hold the kernel:
`apt-mark hold linux-image-amd64 linux-headers-amd64`.

### ZFSBootMenu doesn't see the Intel RST array

```bash
sudo python3 install/zfsbootmenu-setup.py --mdraid
```

The script verifies the image contents: mdadm, `raid0`, `vmd`, `rd.auto=1` and
the assemble hook. See [QUICK_START_RAID0.md](QUICK_START_RAID0.md).

### Keyboard doesn't work in ZFSBootMenu (MacBook)

```bash
sudo python3 install/zfsbootmenu-setup.py --macbook
```

If it still doesn't work, collect `lsusb` and
`sudo dmesg | grep -iE 'hid|xhci|apple'` from Debian. An external USB keyboard
works meanwhile.

### No Wi-Fi

Run `nmtui`. On a MacBook, check `lsmod | grep wl` and `dkms status`. The
driver comes from `broadcom-sta-dkms` (installed with `--macbook`).

### ZRAM not active

In a live system or chroot, ZRAM starts only after a reboot. Check it with
`sudo python3 install/zram-config.py --status`.

## 📚 Documentation

- [Intel RST RAID 0 quick start](QUICK_START_RAID0.md)
- [Installing into an existing pool](EXISTING_POOL_INSTALLATION.md)
- [Architecture and dataset structure](docs/ARCHITECTURE.md)
- [RAID support and fixes](docs/FIXES_AND_RAID_SUPPORT.md)
- [Testing guide](docs/TESTING.md)
- [Sources](docs/SOURCES.md)

## 🔗 Sources

- [OpenZFS documentation — Debian](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)
- [ZFSBootMenu documentation](https://docs.zfsbootmenu.org/)
- [ZFSBootMenu — remote access](https://docs.zfsbootmenu.org/en/latest/guides/general/remote-access.html)
- [Debian Wiki — ZFS](https://wiki.debian.org/ZFS)
- [Debian Wiki — ZRam](https://wiki.debian.org/ZRam)

## 📄 License

MIT License. Use at your own risk. OpenZFS is licensed under the CDDL, which may be incompatible with the GPL.
