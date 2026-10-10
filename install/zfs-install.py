#!/usr/bin/env python3
"""zfs-install.py — Debian 13 (stable) or sid on a ZFS root with ZFSBootMenu and ZRAM.

Install targets (pick one):

  Whole disk (ERASES the disk):
      zfs-install.py --disk /dev/nvme0n1
      zfs-install.py --disk /dev/md126            # Intel RST RAID 0 volume

  Free space next to Windows (keeps all partitions, reuses the ESP):
      zfs-install.py --disk /dev/nvme0n1 --use-free-space [--efi-part 1]

  Already prepared partitions (only the chosen partition is erased):
      zfs-install.py --pool-part /dev/nvme0n1p5 --efi-device /dev/nvme0n1p1
      zfs-install.py --select-partitions          # pick them from a list

  Existing ZFS pool (new or existing ROOT/<name> boot environment):
      zfs-install.py --pool zroot --efi-device /dev/sda1
      zfs-install.py --use-existing-pool          # pick pool and ESP from a list

  Guided wizard for all of the above:
      zfs-install.py --interactive

Release (default: stable = Debian 13 "trixie"):
      zfs-install.py --disk /dev/sda --release stable
      zfs-install.py --disk /dev/sda --release sid     # unstable, rolling

MacBook (e.g. A1398):  --macbook  adds the built-in keyboard/trackpad drivers
to ZFSBootMenu, the Apple "EFI Boot" fallback loader and the Broadcom Wi-Fi
driver (wl). Wired network + SSH in the boot menu:
      --zbm-network --ssh-key ~/.ssh/id_ed25519.pub

Intel RST RAID: pass the RAID *volume* (usually /dev/md126 or
/dev/md/Volume0_0), never the imsm container (usually /dev/md127) or a member
NVMe disk. ZFSBootMenu is then built locally with mdadm support.
"""

import argparse
import glob
import os
import re
import shutil
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

MOUNT_POINT = "/mnt"
MIRROR = dz.MIRROR
MIN_POOL_GIB = 8
MIN_FREE_SPACE_GIB = 20
APT_ENV = {"DEBIAN_FRONTEND": "noninteractive"}


class Plan(object):
    """Everything the installation needs, filled in by argument parsing or the wizard."""

    def __init__(self):
        self.mode = None            # disk | free-space | partitions | existing-pool
        self.disk = ""              # disk / free-space
        self.boot_part = 1          # ESP partition number (disk / free-space)
        self.pool_part = 2
        self.efi_part = ""          # --efi-part for free-space
        self.esp_size = "+512M"
        self.boot_device = ""       # ESP partition node
        self.pool_device = ""       # partition that becomes the pool vdev
        self.format_esp = False
        self.pool_name = "zroot"
        self.release = dz.DEFAULT_RELEASE   # key in dz.RELEASES (stable | sid)
        self.be_name_forced = False
        self.be_name = ""           # boot environment: <pool>/ROOT/<be_name> (default: codename)
        self.encrypt = False
        self.passphrase = ""
        self.hostname = "debian-zfs"
        self.password = ""
        self.is_md = False
        self.skip_packages = False
        self.zbm_network = False
        self.ssh_key = ""
        self.kernel_guard = True    # zfs-kernel-guard apt/kernel hooks
        self.macbook = False        # MacBook drivers (ZBM keyboard, fallback loader, wl Wi-Fi)
        self.wl_devices = []        # Broadcom Wi-Fi needing broadcom-sta (MacBooks)

    @property
    def codename(self):
        return dz.RELEASES[self.release]["codename"]

    @property
    def root_ds(self):
        return "%s/ROOT/%s" % (self.pool_name, self.be_name)

    @property
    def key_file(self):
        return "/etc/zfs/%s.key" % self.pool_name


###############################################################################
# Device validation
###############################################################################

def check_md_target(dev):
    """Reject imsm containers / dmraid; returns canonical device and md flag."""
    if dz.is_md(dev):
        if dz.md_level(dev) == "container":
            vols = dz.md_container_volumes(dev)
            die("%s (%s) is an Intel RST/imsm CONTAINER, not a RAID volume.\n"
                "        Use the RAID volume inside it instead: %s"
                % (dev, dz.kname(dev), ", ".join(vols) or "(none assembled)"))
        info("md RAID device %s -> /dev/%s (level %s, metadata %s)" % (
            dev, dz.kname(dev), dz.md_level(dev), dz.md_metadata(dev)))
        if dz.md_metadata(dev).startswith("external:"):
            info("Firmware RAID (Intel RST / imsm) — ZFSBootMenu will be built with mdraid support")
        return "/dev/" + dz.kname(dev), True
    if dev.startswith("/dev/mapper/isw_"):
        die("%s is a dmraid (isw) device; ZFSBootMenu cannot use dmraid.\n"
            "        Use mdadm instead:  dmraid -an && mdadm --assemble --scan" % dev)
    if dev.startswith("/dev/dm-") or dev.startswith("/dev/mapper/"):
        warn("%s is a device-mapper device — not tested with ZFSBootMenu" % dev)
    return dev, False


def check_not_raid_member(dev):
    if dz.is_md(dev):
        return
    holders = dz.disk_md_holders(dev)
    if holders:
        die("%s is a member of md array(s) %s — writing to it would destroy the array.\n"
            "        Use the RAID volume instead: %s"
            % (dev, " ".join(holders), ", ".join(dz.md_suggest_volumes(dev))))
    exam = dz.out(["mdadm", "--examine", dev]) if dz.have("mdadm") else ""
    if re.search(r"Intel Raid ISM|Raid Level", exam):
        die("%s carries RAID metadata but the array is not assembled.\n"
            "        Run: mdadm --assemble --scan && cat /proc/mdstat, then use the RAID volume" % dev)


def check_not_in_use(dev, devices):
    if dz.device_mounted(dev, devices):
        die("%s (or one of its partitions) is mounted — unmount it first" % dev)
    if os.path.realpath(dev) in dz.zfs_pool_members():
        die("%s is part of an imported ZFS pool" % dev)


def validate_disk(plan, devices):
    if not os.path.exists(plan.disk) or not os.path.isabs(plan.disk):
        die("Disk %s not found" % plan.disk)
    plan.disk, plan.is_md = check_md_target(plan.disk)
    check_not_raid_member(plan.disk)
    part = dz.part_number(plan.disk)
    if part:
        die("%s is a partition. Use --pool-part for prepared partitions, or pass the whole disk" % plan.disk)
    if plan.mode == "disk":
        check_not_in_use(plan.disk, devices)


def lookup(devices, dev):
    real = os.path.realpath(dev)
    for d in devices:
        if os.path.realpath(d["path"]) == real:
            return d
    return None


def validate_pool_partition(plan, devices):
    dev = plan.pool_device
    if not os.path.exists(dev):
        die("Pool partition %s not found" % dev)
    d = lookup(devices, dev) or {"path": dev, "size": 0, "type": "", "fstype": "", "parttype": ""}
    if d.get("type") in ("disk",) and not dz.is_md(dev):
        die("%s is a whole disk. Use --disk for a whole-disk install" % dev)
    if dz.is_md(dev) and dz.md_level(dev) == "container":
        check_md_target(dev)
    check_not_raid_member(dev)
    check_not_in_use(dev, devices)
    if d.get("parttype") == dz.ESP_GUID:
        die("%s is an EFI System Partition — choose a different partition for the pool" % dev)
    if d.get("parttype") == dz.MSR_GUID:
        die("%s is a Microsoft Reserved partition" % dev)
    if d["size"] and d["size"] < MIN_POOL_GIB * 1024 ** 3:
        die("%s is only %s; at least %d GiB is required" % (dev, dz.human_size(d["size"]), MIN_POOL_GIB))
    plan.is_md = plan.is_md or dz.is_md(dev)
    return d


def validate_esp(plan, devices):
    dev = plan.boot_device
    if not os.path.exists(dev):
        die("EFI partition %s not found" % dev)
    if os.path.realpath(dev) == os.path.realpath(plan.pool_device or "/nonexistent"):
        die("The EFI partition and the pool partition must be different")
    d = lookup(devices, dev) or {"path": dev, "size": 0, "fstype": "", "parttype": ""}
    if not dz.part_number(dev):
        die("%s is not a partition" % dev)
    check_not_raid_member(dev)
    fstype = d.get("fstype") or dz.out(["blkid", "-s", "TYPE", "-o", "value", dev])
    if fstype != "vfat" and (fstype in ("ntfs", "BitLocker", "ext4", "xfs", "btrfs", "zfs_member", "crypto_LUKS")
                             or d.get("size", 0) > 4 * 1024 ** 3):
        die("%s (%s, %s) does not look like an EFI System Partition — refusing to format it"
            % (dev, fstype or "no filesystem", dz.human_size(d.get("size", 0))))
    if fstype != "vfat":
        if not plan.format_esp:
            warn("%s is not FAT (found: %s)" % (dev, fstype or "nothing"))
            if not dz.confirm("Format %s as FAT32 for the ESP?" % dev):
                die("An ESP formatted as FAT32 is required (or pass --format-efi)")
            plan.format_esp = True
    elif d.get("parttype") and d["parttype"] != dz.ESP_GUID:
        warn("%s is FAT but its partition type is not 'EFI System' — firmware may ignore it" % dev)
    if d.get("mountpoint") and d["mountpoint"] != "/boot/efi":
        die("%s is mounted at %s — unmount it first" % (dev, d["mountpoint"]))
    plan.is_md = plan.is_md or dz.is_md(dev)


###############################################################################
# Interactive selection
###############################################################################

def show_devices(devices):
    info("Block devices:")
    for d in devices:
        if d.get("type") in ("loop", "rom"):
            continue
        print("    " + dz.describe(d))


def pool_candidates(devices):
    members = dz.zfs_pool_members()
    result = []
    for d in devices:
        if d.get("type") in ("disk", "loop", "rom") or d.get("type", "").startswith("raid") and \
                any(x.get("pkname") == d.get("kname") for x in devices):
            continue  # whole disks, and md volumes that have partitions
        if d.get("parttype") in (dz.ESP_GUID, dz.MSR_GUID):
            continue
        if d.get("mountpoint") or os.path.realpath(d["path"]) in members:
            continue
        if dz.disk_md_holders(d["path"]) or d["size"] < MIN_POOL_GIB * 1024 ** 3:
            continue
        if dz.is_md(d["path"]) and dz.md_level(d["path"]) == "container":
            continue
        result.append(d)
    return result


def esp_candidates(devices, exclude=""):
    return [d for d in devices
            if d.get("type") == "part"
            and (d.get("parttype") == dz.ESP_GUID or d.get("fstype") == "vfat")
            and os.path.realpath(d["path"]) != os.path.realpath(exclude or "/nonexistent")
            and not dz.disk_md_holders(d["path"])]


def pool_label(d):
    label = dz.describe(d)
    if d.get("fstype") == "zfs_member":
        label += "   <- old ZFS data will be ERASED"
    elif d.get("fstype") in ("ntfs", "BitLocker", "ext4", "xfs", "btrfs"):
        label += "   <- contains %s data, will be ERASED" % d["fstype"]
    return label


def select_partitions(plan):
    step("Select prepared partitions")
    devices = dz.lsblk_devices()
    show_devices(devices)

    if not plan.pool_device:
        cands = pool_candidates(devices)
        if not cands:
            die("No usable partition found (unmounted, >= %d GiB, not an ESP or RAID member).\n"
                "        Create one first (e.g. with gdisk / Windows Disk Management)" % MIN_POOL_GIB)
        idx = dz.choose("Partition for the ZFS pool (it will be ERASED):", [pool_label(d) for d in cands])
        if idx is None:
            die("Cancelled")
        plan.pool_device = cands[idx]["path"]

    if not plan.boot_device:
        cands = esp_candidates(devices, plan.pool_device)
        labels = [dz.describe(d) + ("   (reuse, keeps Windows boot files)" if d.get("fstype") == "vfat"
                                     else "   (will be formatted)") for d in cands]
        idx = dz.choose("EFI System Partition:", labels + ["Enter a path manually"])
        if idx is None:
            die("Cancelled")
        if idx == len(cands):
            plan.boot_device = dz.ask("EFI partition path")
        else:
            plan.boot_device = cands[idx]["path"]


def importable_pools():
    names = [p for p in dz.out(["zpool", "list", "-H", "-o", "name"]).splitlines() if p]
    for line in dz.out(["zpool", "import"]).splitlines():
        m = re.match(r"\s*pool:\s*(\S+)", line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return names


def select_existing_pool(plan):
    step("Select existing ZFS pool")
    pools = importable_pools()
    if not pools:
        die("No imported or importable ZFS pools found")
    idx = dz.choose("ZFS pool:", pools)
    if idx is None:
        die("Cancelled")
    plan.pool_name = pools[idx]


def select_esp_only(plan):
    devices = dz.lsblk_devices()
    cands = esp_candidates(devices)
    idx = dz.choose("EFI System Partition:", [dz.describe(d) for d in cands] + ["Enter a path manually"])
    if idx is None:
        die("Cancelled")
    plan.boot_device = dz.ask("EFI partition path") if idx == len(cands) else cands[idx]["path"]


def select_disk(plan):
    devices = dz.lsblk_devices()
    disks = [d for d in devices
             if ((d.get("type") == "disk" and not dz.disk_md_holders(d["path"]))
                 or (d.get("type", "").startswith("raid") and dz.md_level(d["path"]) != "container"))
             and not dz.device_mounted(d["path"], devices)]
    if not disks:
        die("No disks found")
    idx = dz.choose("Target disk:", [dz.describe(d) for d in disks])
    if idx is None:
        die("Cancelled")
    plan.disk = disks[idx]["path"]


def wizard(plan):
    step("Debian ZFS installation — interactive wizard")
    keys = sorted(dz.RELEASES, key=lambda k: k != dz.DEFAULT_RELEASE)
    idx = dz.choose("Debian branch:", [dz.RELEASES[k]["label"] for k in keys])
    if idx is None:
        die("Cancelled")
    plan.release = keys[idx]
    if not plan.be_name_forced:
        plan.be_name = plan.codename
    modes = [
        ("disk", "Whole disk — ERASE the disk and create ESP + ZFS partitions"),
        ("free-space", "Free space on a disk — keep Windows/partitions, reuse its ESP"),
        ("partitions", "Already prepared partitions — pick a partition for ZFS and an ESP"),
        ("existing-pool", "Existing ZFS pool — install into a new or existing boot environment"),
    ]
    idx = dz.choose("Installation target:", [m[1] for m in modes])
    if idx is None:
        die("Cancelled")
    plan.mode = modes[idx][0]

    if plan.mode in ("disk", "free-space"):
        select_disk(plan)
    elif plan.mode == "partitions":
        select_partitions(plan)
    else:
        select_existing_pool(plan)
        select_esp_only(plan)

    if plan.mode != "existing-pool":
        plan.pool_name = dz.ask("Pool name", plan.pool_name)
    plan.hostname = dz.ask("Hostname", plan.hostname)
    if plan.mode != "existing-pool":
        plan.encrypt = dz.ask("Enable ZFS native encryption? (y/n)", "n").lower().startswith("y")
    if not plan.macbook:
        is_mac = dz.dmi("sys_vendor").startswith("Apple")
        plan.macbook = dz.ask("Enable MacBook drivers (keyboard in boot menu, Broadcom Wi-Fi)? (y/n)",
                              "y" if is_mac else "n").lower().startswith("y")


###############################################################################
# Host preparation
###############################################################################

def apt_sources_text():
    text = ""
    for path in ["/etc/apt/sources.list"] + glob.glob("/etc/apt/sources.list.d/*"):
        try:
            with open(path) as fh:
                text += fh.read()
        except OSError:
            pass
    return text


def install_host_packages(plan):
    """ZFS + tools on the running live system (Debian 12, 13 or sid live media)."""
    step("Installing required packages on the live system")
    host = dz.host_codename()
    info("Live system: %s" % (host or "unknown"))
    sources = apt_sources_text()
    extra = []
    if "contrib" not in sources and host:
        extra.append("deb %s %s main contrib non-free-firmware" % (MIRROR, host))
    use_backports = host == "bookworm"   # bookworm's own ZFS 2.1 is too old
    if use_backports and "bookworm-backports" not in sources:
        extra.append("deb %s bookworm-backports main contrib non-free-firmware" % MIRROR)
    if extra:
        info("Adding APT sources: %s" % "; ".join(extra))
        dz.write_file("/etc/apt/sources.list.d/debian-zfs-installer.list", "\n".join(extra) + "\n")

    dz.run(["apt-get", "update"], env=APT_ENV)
    kernel = os.uname().release
    zfs_cmd = ["apt-get", "install", "-y"]
    if use_backports:
        zfs_cmd += ["-t", "bookworm-backports"]
    dz.run(zfs_cmd + ["zfsutils-linux", "zfs-dkms", "linux-headers-%s" % kernel], env=APT_ENV)
    dz.run(["apt-get", "install", "-y", "debootstrap", "debian-archive-keyring", "gdisk", "dkms",
            "curl", "dosfstools", "efibootmgr", "mdadm", "cpio", "kexec-tools"], env=APT_ENV)
    dz.run(["modprobe", "zfs"])


def ensure_hostid():
    if not os.path.exists("/etc/hostid"):
        info("Generating /etc/hostid")
        dz.run(["zgenhostid"])


def settle_and_wait(*devs):
    if dz.DRY_RUN:
        return
    dz.run(["udevadm", "settle", "--timeout=30"], check=False, quiet=True)
    for _ in range(30):
        if all(os.path.exists(d) for d in devs):
            return
        time.sleep(1)
    die("Partition(s) did not appear: %s" % ", ".join(d for d in devs if not os.path.exists(d)))


###############################################################################
# Target layout per mode
###############################################################################

def sgdisk_value(args):
    return dz.out(["sgdisk"] + args)


def resolve_disk_layout(plan, devices):
    validate_disk(plan, devices)
    plan.boot_device = dz.partition_device(plan.disk, plan.boot_part)
    plan.pool_device = dz.partition_device(plan.disk, plan.pool_part)
    plan.format_esp = True
    size = dz.human_size(int(dz.out(["blockdev", "--getsize64", plan.disk], "0")))
    warn("ALL DATA on %s (%s) will be DESTROYED!" % (plan.disk, size))
    dz.run(["lsblk", plan.disk], check=False, always=True)
    if not dz.DRY_RUN and not dz.confirm("Erase %s and install Debian on ZFS?" % plan.disk):
        die("Cancelled")


def resolve_free_space_layout(plan, devices):
    validate_disk(plan, devices)
    table = sgdisk_value(["-p", plan.disk])
    if "GPT" not in table and "gpt" not in table.lower():
        die("%s must use GPT for --use-free-space" % plan.disk)

    if plan.efi_part:
        plan.boot_part = int(plan.efi_part)
    else:
        esp = [l.split()[0] for l in table.splitlines()
               if re.match(r"\s*\d+\s", l) and len(l.split()) >= 6 and l.split()[5].upper() == "EF00"]
        if not esp:
            die("No EFI System Partition on %s — pass --efi-part NUM" % plan.disk)
        plan.boot_part = int(esp[0])
    nums = [int(l.split()[0]) for l in table.splitlines() if re.match(r"\s*\d+\s", l)]
    plan.pool_part = (max(nums) + 1) if nums else 1
    plan.boot_device = dz.partition_device(plan.disk, plan.boot_part)
    plan.pool_device = dz.partition_device(plan.disk, plan.pool_part)

    first = sgdisk_value(["-F", plan.disk])
    last = sgdisk_value(["-E", plan.disk])
    if not first.isdigit() or not last.isdigit() or int(first) == 0 or int(last) <= int(first):
        die("No free GPT space on %s — shrink Windows first to leave unallocated space" % plan.disk)
    sector = int(dz.out(["blockdev", "--getss", plan.disk], "512"))
    free_gib = (int(last) - int(first) + 1) * sector // 1024 ** 3
    if free_gib < MIN_FREE_SPACE_GIB:
        die("Only %d GiB free on %s; %d GiB required" % (free_gib, plan.disk, MIN_FREE_SPACE_GIB))
    plan.free_range = (first, last)

    warn("Keeping all partitions on %s; new ZFS partition %s uses %d GiB of free space"
         % (plan.disk, plan.pool_device, free_gib))
    warn("Reusing EFI partition %s (not formatted)" % plan.boot_device)
    if not dz.DRY_RUN and not dz.confirm("Continue?"):
        die("Cancelled")


def resolve_partitions_layout(plan, devices):
    if not plan.pool_device or not plan.boot_device:
        select_partitions(plan)
        devices = dz.lsblk_devices()
    plan.pool_device, md1 = check_md_target(plan.pool_device) if dz.is_md(plan.pool_device) and \
        not dz.part_number(plan.pool_device) else (plan.pool_device, False)
    d = validate_pool_partition(plan, devices)
    validate_esp(plan, devices)
    plan.is_md = plan.is_md or md1

    print()
    warn("Pool partition: %s  (%s) — ALL DATA on it will be ERASED" % (plan.pool_device, dz.describe(d)))
    if plan.format_esp:
        warn("EFI partition:  %s — will be FORMATTED (FAT32)" % plan.boot_device)
    else:
        info("EFI partition:  %s — reused, existing boot files are kept" % plan.boot_device)
    info("Nothing else on the disk(s) is touched.")
    if not dz.DRY_RUN and not dz.confirm("Continue?"):
        die("Cancelled")


def prepare_disk(plan):
    step("Preparing %s" % (plan.disk or plan.pool_device))
    if plan.mode == "disk":
        dz.run(["zpool", "labelclear", "-f", plan.disk], check=False, quiet=True)
        dz.run(["wipefs", "-a", plan.disk])
        dz.run(["sgdisk", "--zap-all", plan.disk])
        dz.run(["sgdisk", "-n", "%d:1M:%s" % (plan.boot_part, plan.esp_size),
                "-t", "%d:EF00" % plan.boot_part, "-c", "%d:EFI" % plan.boot_part, plan.disk])
        dz.run(["sgdisk", "-n", "%d:0:-10M" % plan.pool_part,
                "-t", "%d:BF00" % plan.pool_part, "-c", "%d:zfs" % plan.pool_part, plan.disk])
    elif plan.mode == "free-space":
        first, last = plan.free_range
        dz.run(["sgdisk", "-n", "%d:%s:%s" % (plan.pool_part, first, last),
                "-t", "%d:BF00" % plan.pool_part, "-c", "%d:zfs" % plan.pool_part, plan.disk])
    elif plan.mode == "partitions":
        dz.run(["zpool", "labelclear", "-f", plan.pool_device], check=False, quiet=True)
        dz.run(["wipefs", "-a", plan.pool_device])

    if plan.disk:
        dz.run(["partprobe", plan.disk], check=False)
        settle_and_wait(plan.boot_device, plan.pool_device)
        dz.run(["sgdisk", "-p", plan.disk], check=False)

    if plan.format_esp:
        info("Formatting %s as FAT32" % plan.boot_device)
        dz.run(["mkfs.vfat", "-F", "32", "-n", "EFI", plan.boot_device])


###############################################################################
# ZFS
###############################################################################

def create_pool(plan):
    step("Creating ZFS pool %s" % plan.pool_name)
    vdev = plan.pool_device if dz.DRY_RUN else dz.stable_device_path(plan.pool_device)
    info("Pool vdev: %s" % vdev)
    cmd = ["zpool", "create", "-f",
           "-o", "ashift=12", "-o", "autotrim=on", "-o", "compatibility=openzfs-2.2-linux",
           "-O", "compression=lz4", "-O", "acltype=posixacl", "-O", "xattr=sa",
           "-O", "relatime=on", "-O", "dnodesize=auto", "-O", "normalization=formD",
           "-m", "none"]
    if plan.encrypt:
        if not plan.passphrase:
            plan.passphrase = dz.ask_passphrase()
        if len(plan.passphrase) < 8:
            die("ZFS requires a passphrase of at least 8 characters")
        dz.write_file(plan.key_file, plan.passphrase + "\n", mode=0o000)
        cmd += ["-O", "encryption=aes-256-gcm", "-O", "keyformat=passphrase",
                "-O", "keylocation=file://%s" % plan.key_file]
    dz.run(cmd + [plan.pool_name, vdev])
    dz.run(["zpool", "status", plan.pool_name], check=False)


def create_datasets(plan):
    step("Creating datasets")
    p = plan.pool_name
    dz.run(["zfs", "create", "-o", "mountpoint=none", "%s/ROOT" % p])
    dz.run(["zfs", "create", "-o", "mountpoint=/", "-o", "canmount=noauto", plan.root_ds])
    dz.run(["zfs", "create", "-o", "mountpoint=/home", "%s/home" % p])
    dz.run(["zfs", "create", "-o", "mountpoint=/var/log", "%s/var-log" % p])
    set_boot_properties(plan)


def set_boot_properties(plan):
    dz.run(["zpool", "set", "bootfs=%s" % plan.root_ds, plan.pool_name])
    dz.run(["zfs", "set", "org.zfsbootmenu:commandline=quiet loglevel=0", plan.root_ds])
    if plan.encrypt:
        dz.run(["zfs", "set", "org.zfsbootmenu:keysource=%s" % plan.root_ds, plan.pool_name])


def import_pool(plan):
    step("Importing %s at %s" % (plan.pool_name, MOUNT_POINT))
    imported = dz.ok(["zpool", "list", plan.pool_name])
    if imported:
        dz.run(["zpool", "export", plan.pool_name])
    dz.run(["zpool", "import", "-N", "-R", MOUNT_POINT, plan.pool_name])
    dz.run(["zpool", "set", "cachefile=/etc/zfs/zpool.cache", plan.pool_name])


def load_key(plan):
    if dz.DRY_RUN:
        if plan.encrypt:
            dz.run(["zfs", "load-key", "-L", "file://%s" % plan.key_file, plan.root_ds])
        return
    status = dz.out(["zfs", "get", "-H", "-o", "value", "keystatus", plan.root_ds])
    if status != "unavailable":
        return
    plan.encrypt = True
    if os.path.exists(plan.key_file):
        dz.run(["zfs", "load-key", "-L", "file://%s" % plan.key_file, plan.root_ds])
    else:
        info("Enter the passphrase for %s" % plan.root_ds)
        dz.run(["zfs", "load-key", "-L", "prompt", plan.root_ds])


def mount_datasets(plan):
    step("Mounting datasets")
    load_key(plan)
    dz.run(["zfs", "mount", plan.root_ds])
    for ds in ("%s/home" % plan.pool_name, "%s/var-log" % plan.pool_name):
        if dz.DRY_RUN or dz.ok(["zfs", "list", ds]):
            dz.run(["zfs", "mount", ds], check=False)
    dz.run(["findmnt", "-R", MOUNT_POINT], check=False)


def prepare_existing_pool(plan):
    step("Using existing pool %s" % plan.pool_name)
    import_pool(plan)
    root = "%s/ROOT" % plan.pool_name
    envs = [l for l in dz.out(["zfs", "list", "-H", "-o", "name", "-r", "-d", "1", root]).splitlines()
            if l and l != root]
    if not dz.DRY_RUN and not dz.ok(["zfs", "list", root]):
        dz.run(["zfs", "create", "-o", "mountpoint=none", root])

    labels = [e for e in envs] + ["Create new boot environment %s/ROOT/<name>" % plan.pool_name]
    if dz.ASSUME_YES or dz.DRY_RUN:
        idx = len(envs)
    else:
        idx = dz.choose("Boot environment to install into:", labels)
        if idx is None:
            die("Cancelled")
    if idx == len(envs):
        if not dz.ASSUME_YES and not dz.DRY_RUN:
            plan.be_name = dz.ask("New boot environment name", plan.be_name)
        if plan.root_ds in envs:
            die("%s already exists" % plan.root_ds)
        dz.run(["zfs", "create", "-o", "mountpoint=/", "-o", "canmount=noauto", plan.root_ds])
    else:
        plan.be_name = envs[idx].split("/")[-1]
        warn("debootstrap will write into the existing dataset %s" % plan.root_ds)
        if not dz.confirm("Continue with %s?" % plan.root_ds):
            die("Cancelled")
    set_boot_properties(plan)


###############################################################################
# Debian installation
###############################################################################

def install_debian(plan):
    step("Installing Debian %s with debootstrap" % plan.codename)
    if plan.release == "sid":
        warn("sid is the unstable branch: packages change daily and can break")
    dz.run(["debootstrap", "--components=main,contrib,non-free-firmware",
            plan.codename, MOUNT_POINT, MIRROR])


def prepare_chroot(plan):
    step("Preparing chroot")
    target = MOUNT_POINT
    ensure_hostid()
    for src in ("/etc/hostid", "/etc/zfs/zpool.cache"):
        if os.path.exists(src) or dz.DRY_RUN:
            dz.run(["mkdir", "-p", os.path.dirname(target + src)])
            dz.run(["cp", "-L", src, target + src], check=False)
    dz.run(["cp", "-L", "/etc/resolv.conf", target + "/etc/resolv.conf"], check=False)
    if plan.encrypt and (os.path.exists(plan.key_file) or dz.DRY_RUN):
        dz.run(["cp", plan.key_file, target + plan.key_file])
        dz.run(["chmod", "000", target + plan.key_file])
    dz.run(["mount", "-t", "proc", "proc", target + "/proc"])
    for fs in ("/sys", "/dev"):
        dz.run(["mount", "--rbind", fs, target + fs])
        dz.run(["mount", "--make-rslave", target + fs])


def chroot_apt(args, check=True):
    return dz.run(["apt-get"] + args, chroot=MOUNT_POINT, env=APT_ENV, check=check)


def configure_system(plan):
    step("Configuring the new system")
    t = MOUNT_POINT

    dz.write_file(t + "/etc/hostname", plan.hostname + "\n")
    dz.write_file(t + "/etc/hosts",
                  "127.0.0.1\tlocalhost\n127.0.1.1\t%s\n\n"
                  "::1\tlocalhost ip6-localhost ip6-loopback\n"
                  "ff02::1\tip6-allnodes\nff02::2\tip6-allrouters\n" % plan.hostname)
    # deb822 sources (default format since Debian 13)
    dz.write_file(t + "/etc/apt/sources.list.d/debian.sources", dz.deb822_sources(plan.release))
    dz.write_file(t + "/etc/apt/sources.list",
                  "# Package sources are in /etc/apt/sources.list.d/debian.sources\n")

    chroot_apt(["update"])
    chroot_apt(["install", "-y", "locales", "keyboard-configuration", "console-setup", "tzdata"])
    locale_gen = t + "/etc/locale.gen"
    if os.path.exists(locale_gen) and not dz.DRY_RUN:
        with open(locale_gen) as fh:
            text = fh.read()
        text = re.sub(r"^#\s*(en_US\.UTF-8 UTF-8)", r"\1", text, flags=re.M)
        dz.write_file(locale_gen, text)
    dz.run(["locale-gen"], chroot=t)
    dz.run(["update-locale", "LANG=en_US.UTF-8"], chroot=t)

    step("Installing kernel and ZFS (%s)" % plan.codename)
    chroot_apt(["install", "-y", "linux-headers-amd64", "linux-image-amd64",
                "zfs-initramfs", "zfs-dkms", "zfsutils-linux"])
    check_zfs_module(plan)

    pkgs = ["dosfstools", "efibootmgr", "openssh-server", "sudo", "curl", "systemd-zram-generator",
            "cpio", "kexec-tools", "python3"]
    if plan.is_md:
        pkgs.append("mdadm")
    # Networking for the installed system: NetworkManager (nmtui) handles
    # Ethernet and Wi-Fi; wl = proprietary driver for Broadcom (MacBook) Wi-Fi
    pkgs += ["network-manager"]
    has_wifi = (plan.macbook and bool(plan.wl_devices)) or bool(glob.glob(dz.SYSFS + "/class/net/*/wireless"))
    if has_wifi:
        pkgs += ["wpasupplicant", "iw", "wireless-regdb"]
    chroot_apt(["install", "-y"] + pkgs)
    if plan.macbook:
        if plan.wl_devices:
            install_broadcom_wifi(plan)
        else:
            info("No Broadcom Wi-Fi chip found — skipping the wl driver")
    copy_network_connections()

    dz.write_file(t + "/etc/dkms/zfs.conf", "REMAKE_INITRD=yes\n")

    if plan.is_md:
        info("Writing mdadm.conf and RAID initramfs modules (Intel RST)")
        conf = dz.out(["chroot", t, "/usr/share/mdadm/mkconf"]) if not dz.DRY_RUN else ""
        if not conf:
            conf = "HOMEHOST <system>\nMAILADDR root\nDEVICE partitions containers\n" + \
                dz.out(["mdadm", "--detail", "--scan"])
        dz.write_file(t + "/etc/mdadm/mdadm.conf", conf.rstrip("\n") + "\n")
        for mod in ("vmd", "md_mod", "raid0"):
            dz.append_line(t + "/etc/initramfs-tools/modules", mod)

    if plan.kernel_guard:
        install_kernel_guard()

    for unit in ("zfs.target", "zfs-import-cache.service", "zfs-mount.service", "zfs-import.target"):
        dz.run(["systemctl", "enable", unit], chroot=t, check=False)

    if plan.encrypt:
        dz.write_file(t + "/etc/initramfs-tools/conf.d/umask.conf", "UMASK=0077\n")

    dz.run(["update-initramfs", "-u", "-k", "all"], chroot=t)
    if not dz.DRY_RUN:
        kernels = glob.glob(t + "/boot/vmlinuz-*")
        initrds = glob.glob(t + "/boot/initrd.img-*")
        if not kernels or not initrds:
            die("No kernel/initramfs in %s/boot — check the apt output above" % t)
        info("Kernels: %s" % ", ".join(os.path.basename(k) for k in kernels))

    if plan.password:
        dz.run(["chpasswd"], chroot=t, input="root:%s\n" % plan.password)
    else:
        info("Set the root password for the new system")
        if dz.DRY_RUN:
            dz.run(["passwd", "root"], chroot=t)
        else:
            while dz.run(["passwd", "root"], chroot=t, check=False).returncode != 0:
                warn("Try again")


def install_kernel_guard():
    """Kernel-update protection for OpenZFS (see install/zfs-kernel-guard.py)."""
    step("Installing zfs-kernel-guard (protects against kernel updates that break ZFS)")
    src = os.path.join(SCRIPT_DIR, "zfs-kernel-guard.py")
    if not dz.DRY_RUN:
        shutil.copy(src, MOUNT_POINT + "/tmp/zfs-kernel-guard.py")
    dz.run(["python3", "/tmp/zfs-kernel-guard.py", "install"], chroot=MOUNT_POINT, check=False)
    dz.run(["rm", "-f", MOUNT_POINT + "/tmp/zfs-kernel-guard.py"], check=False)


def install_broadcom_wifi(plan):
    step("Installing Broadcom Wi-Fi driver (wl) for %s" % ", ".join(plan.wl_devices))
    info("MacBook BCM4331/BCM4360-class Wi-Fi needs broadcom-sta-dkms from 'non-free'")
    if chroot_apt(["install", "-y", "broadcom-sta-dkms"], check=False).returncode != 0:
        warn("broadcom-sta-dkms failed to install — Wi-Fi will not work until it is fixed")
        return
    if not dz.DRY_RUN and not glob.glob(MOUNT_POINT + "/lib/modules/*/**/wl.ko*", recursive=True):
        warn("wl.ko was not built by DKMS (kernel too new for broadcom-sta?) — check: dkms status")
    else:
        info("wl driver installed ✓ (b43/bcma/brcmsmac are blacklisted by the package)")


def copy_network_connections():
    """Carry the live system's NetworkManager connections (e.g. Wi-Fi) over."""
    src = "/etc/NetworkManager/system-connections"
    files = glob.glob(src + "/*") if os.path.isdir(src) else []
    if not files:
        return
    info("Copying %d NetworkManager connection(s) from the live system" % len(files))
    dst = MOUNT_POINT + src
    dz.run(["mkdir", "-p", dst])
    for f in files:
        dz.run(["cp", "-p", f, dst + "/"])
    dz.run(["sh", "-c", "chmod 600 %s/*" % dst])


def check_zfs_module(plan):
    """Every installed kernel needs a DKMS-built zfs.ko, or the system cannot boot."""
    if dz.DRY_RUN:
        return
    t = MOUNT_POINT
    missing = []
    for vmlinuz in glob.glob(t + "/boot/vmlinuz-*"):
        ver = os.path.basename(vmlinuz)[len("vmlinuz-"):]
        if not glob.glob(t + "/lib/modules/%s/**/zfs.ko*" % ver, recursive=True):
            missing.append(ver)
    if missing:
        hint = ("sid's kernel is probably newer than its ZFS supports — use --release stable,\n"
                "        or install an older linux-image in the chroot and remove the new one"
                if plan.release == "sid" else
                "check the DKMS output above (chroot %s dkms status)" % t)
        die("ZFS module was not built for kernel(s) %s\n        %s" % (", ".join(missing), hint))
    info("zfs.ko built for all kernels ✓")


def setup_esp(plan):
    step("Mounting EFI System Partition")
    uuid = "0000-0000" if dz.DRY_RUN else dz.out(["blkid", "-s", "UUID", "-o", "value", plan.boot_device])
    if not uuid:
        die("Could not read the UUID of %s" % plan.boot_device)
    dz.write_file(MOUNT_POINT + "/etc/fstab",
                  "# EFI System Partition\nUUID=%s  /boot/efi  vfat  defaults,umask=0077  0  1\n" % uuid)
    dz.run(["mkdir", "-p", MOUNT_POINT + "/boot/efi"])
    dz.run(["mount", "-t", "vfat", plan.boot_device, MOUNT_POINT + "/boot/efi"])


def install_zfsbootmenu(plan):
    step("Installing ZFSBootMenu")
    stage = MOUNT_POINT + "/tmp/zbm-setup"
    if not dz.DRY_RUN:
        os.makedirs(stage + "/install", exist_ok=True)
        for name in ("zfsbootmenu-setup.py", "dzlib.py"):
            shutil.copy(os.path.join(SCRIPT_DIR, name), os.path.join(stage, "install", name))
        cfg = dz.find_zbm_config_dir(SCRIPT_DIR)
        if cfg:
            shutil.copytree(cfg, stage + "/config/zfsbootmenu", dirs_exist_ok=True)
    args = ["python3", "/tmp/zbm-setup/install/zfsbootmenu-setup.py", "--yes",
            "--pool", plan.pool_name, "--dataset", "ROOT/%s" % plan.be_name,
            "--boot-device", plan.boot_device]
    if plan.is_md:
        args.append("--mdraid")
        info("Intel RST / md RAID: building ZFSBootMenu locally with mdraid support")
    if plan.macbook:
        args.append("--macbook")
        info("MacBook: ZFSBootMenu gets the built-in keyboard/trackpad drivers")
    if plan.zbm_network:
        args.append("--network")
        if plan.ssh_key:
            if not dz.DRY_RUN:
                shutil.copy(os.path.expanduser(plan.ssh_key), stage + "/authorized_keys")
            args += ["--ssh-key", "/tmp/zbm-setup/authorized_keys"]
        info("ZFSBootMenu gets wired network + SSH (port 222)")
    if dz.run(args, chroot=MOUNT_POINT, check=False).returncode != 0:
        die("ZFSBootMenu setup failed. The system is still mounted at %s; retry with:\n"
            "        chroot %s %s" % (MOUNT_POINT, MOUNT_POINT, " ".join(args)))
    dz.run(["rm", "-rf", stage])


def configure_zram(plan):
    step("Configuring ZRAM swap")
    dz.write_file(MOUNT_POINT + "/etc/systemd/zram-generator.conf",
                  "[zram0]\nzram-size = min(ram * 0.6, 4096)\n"
                  "compression-algorithm = zstd\nswap-priority = 100\nfs-type = swap\n")


def finalize(plan):
    step("Finalizing")
    if dz.run(["umount", "-R", MOUNT_POINT], check=False).returncode != 0:
        warn("Some mounts were busy — retrying with a lazy unmount")
        dz.run(["umount", "-lR", MOUNT_POINT], check=False)
    if dz.run(["zpool", "export", plan.pool_name], check=False).returncode != 0:
        warn("Could not export %s — run 'zpool export %s' before rebooting" % (plan.pool_name, plan.pool_name))
    print()
    dz.banner("INSTALLATION COMPLETED")
    info("Pool:        %s (%s)" % (plan.pool_name, plan.pool_device or "existing"))
    info("Release:     %s" % dz.RELEASES[plan.release]["label"].split(" — ")[0])
    info("Root:        %s" % plan.root_ds)
    info("ESP:         %s" % plan.boot_device)
    if plan.is_md:
        info("RAID:        Intel RST / md — ZFSBootMenu built with mdraid support")
    info("")
    info("Next: reboot, remove the live USB, choose 'ZFSBootMenu' in the UEFI boot menu.")
    if plan.encrypt:
        warn("You will be asked for the ZFS passphrase at boot.")


###############################################################################
# Main
###############################################################################

def parse_args(argv):
    ap = argparse.ArgumentParser(
        prog="zfs-install.py", description=__doc__.split("\n\n")[0],
        epilog="\n\n".join(__doc__.split("\n\n")[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_argument_group("target")
    g.add_argument("--disk", help="whole disk / RAID volume to ERASE (or with --use-free-space)")
    g.add_argument("--use-free-space", action="store_true", help="use free GPT space on --disk, reuse its ESP")
    g.add_argument("--efi-part", help="ESP partition number on --disk for --use-free-space")
    g.add_argument("--pool-part", metavar="DEV", help="prepared partition for the pool (ERASED)")
    g.add_argument("--select-partitions", action="store_true", help="pick prepared partitions from a list")
    g.add_argument("--efi-device", metavar="DEV", help="ESP partition (prepared partitions / existing pool)")
    g.add_argument("--format-efi", action="store_true", help="format the chosen ESP as FAT32")
    g.add_argument("--pool", metavar="NAME", help="install into this existing pool")
    g.add_argument("--use-existing-pool", action="store_true", help="pick an existing pool from a list")
    g.add_argument("--interactive", action="store_true", help="guided wizard")
    o = ap.add_argument_group("options")
    o.add_argument("--pool-name", default="zroot", help="name of the new pool (default: zroot)")
    o.add_argument("--release", default=dz.DEFAULT_RELEASE,
                   help="Debian branch: stable (Debian 13 trixie, default) or sid (unstable)")
    o.add_argument("--boot-env", help="boot environment name (default: release codename)")
    o.add_argument("--esp-size", default="+512M", help="ESP size for whole-disk mode (default: +512M)")
    o.add_argument("--encrypt", action="store_true", help="ZFS native encryption (aes-256-gcm)")
    o.add_argument("--passphrase", help="encryption passphrase (prompted if omitted)")
    o.add_argument("--hostname", default="debian-zfs")
    o.add_argument("--password", help="root password (prompted if omitted)")
    o.add_argument("--no-kernel-guard", action="store_true",
                   help="do not install zfs-kernel-guard (blocks/pins kernels without working ZFS)")
    o.add_argument("--macbook", action="store_true",
                   help="MacBook drivers: keyboard/trackpad in ZFSBootMenu, Apple boot fallback, Broadcom Wi-Fi")
    o.add_argument("--zbm-network", action="store_true",
                   help="wired DHCP + SSH (port 222) inside ZFSBootMenu (needs --ssh-key)")
    o.add_argument("--ssh-key", help="public key / authorized_keys file for SSH into ZFSBootMenu")
    o.add_argument("--skip-packages", action="store_true", help="do not apt-get install on the live system")
    o.add_argument("--dry-run", action="store_true", help="print commands without changing anything")
    o.add_argument("--yes", action="store_true", help="do not ask for confirmations (DANGEROUS)")
    return ap.parse_args(argv)


def build_plan(args):
    plan = Plan()
    plan.pool_name = args.pool_name
    plan.release = dz.resolve_release(args.release)
    plan.be_name_forced = bool(args.boot_env)
    plan.be_name = args.boot_env or plan.codename
    plan.esp_size = args.esp_size
    plan.encrypt = args.encrypt
    plan.passphrase = args.passphrase or ""
    plan.hostname = args.hostname
    plan.password = args.password or ""
    plan.format_esp = args.format_efi
    plan.skip_packages = args.skip_packages
    plan.macbook = args.macbook
    plan.kernel_guard = not args.no_kernel_guard
    plan.zbm_network = args.zbm_network or bool(args.ssh_key)
    plan.ssh_key = args.ssh_key or ""
    if plan.zbm_network and not plan.ssh_key:
        die("--zbm-network needs --ssh-key FILE (password logins are disabled in the boot menu)")
    if plan.ssh_key and not os.path.isfile(os.path.expanduser(plan.ssh_key)):
        die("SSH key file not found: %s" % plan.ssh_key)
    plan.efi_part = args.efi_part or ""
    plan.disk = args.disk or ""
    plan.pool_device = args.pool_part or ""
    plan.boot_device = args.efi_device or ""

    if args.interactive:
        wizard(plan)
    elif args.pool or args.use_existing_pool:
        plan.mode = "existing-pool"
        if args.pool:
            plan.pool_name = args.pool
        else:
            select_existing_pool(plan)
        if not plan.boot_device:
            select_esp_only(plan)
    elif args.pool_part or args.select_partitions:
        plan.mode = "partitions"
    elif args.disk:
        plan.mode = "free-space" if args.use_free_space else "disk"
    else:
        die("Choose a target: --disk, --pool-part/--select-partitions, --pool/--use-existing-pool "
            "or --interactive (see --help)")
    return plan


def main():
    args = parse_args(sys.argv[1:])
    dz.set_dry_run(args.dry_run)
    dz.set_assume_yes(args.yes)
    dz.require_root()
    if not dz.uefi_booted():
        warn("The live system was not booted in UEFI mode — EFI boot entries cannot be created")

    info("═" * 55)
    info("Debian on ZFS root — installer")
    info("═" * 55)
    plan = build_plan(args)
    devices = dz.lsblk_devices()

    if plan.mode == "disk":
        resolve_disk_layout(plan, devices)
    elif plan.mode == "free-space":
        resolve_free_space_layout(plan, devices)
    elif plan.mode == "partitions":
        resolve_partitions_layout(plan, devices)
    else:
        if not plan.boot_device:
            die("--efi-device is required with an existing pool")
        validate_esp(plan, devices)
        members = dz.out(["zpool", "status", "-P", "-L", plan.pool_name])
        plan.is_md = plan.is_md or bool(re.search(r"\s/dev/md", members))

    if plan.encrypt and not plan.passphrase and plan.mode != "existing-pool":
        plan.passphrase = dz.ask_passphrase()

    plan.wl_devices = dz.broadcom_wl_devices()
    if plan.macbook:
        info("MacBook drivers: enabled%s" % (" (Broadcom Wi-Fi %s → wl)" % ", ".join(plan.wl_devices)
                                             if plan.wl_devices else ""))
    elif dz.dmi("sys_vendor").startswith("Apple") or plan.wl_devices:
        warn("%s detected — add --macbook for the built-in keyboard in ZFSBootMenu and the Wi-Fi driver"
             % ("Apple hardware (%s)" % dz.dmi("product_name") if dz.dmi("sys_vendor").startswith("Apple")
                else "Broadcom Wi-Fi (%s)" % ", ".join(plan.wl_devices)))
    info("Release: %s" % dz.RELEASES[plan.release]["label"])
    info("Mode: %s | pool: %s | root: %s | ESP: %s | md RAID: %s"
         % (plan.mode, plan.pool_name, plan.root_ds, plan.boot_device, plan.is_md))

    if not plan.skip_packages:
        install_host_packages(plan)
    ensure_hostid()

    if plan.mode == "existing-pool":
        prepare_existing_pool(plan)
    else:
        prepare_disk(plan)
        create_pool(plan)
        create_datasets(plan)
        import_pool(plan)
    mount_datasets(plan)
    install_debian(plan)
    prepare_chroot(plan)
    configure_system(plan)
    setup_esp(plan)
    install_zfsbootmenu(plan)
    configure_zram(plan)
    finalize(plan)


if __name__ == "__main__":
    dz.run_main(main)
