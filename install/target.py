"""target: validate devices and prepare the disk, free space or partitions that receive the pool."""

import os
import re
import time

import devices as dv
import dzlib as dz
from dzlib import die, info, step, warn

MIN_POOL_GIB = 8
MIN_FREE_SPACE_GIB = 20


def check_md_target(dev):
    """Reject imsm containers / dmraid; returns canonical device and md flag."""
    if dv.is_md(dev):
        if dv.md_level(dev) == "container":
            vols = dv.md_container_volumes(dev)
            die("%s (%s) is an Intel RST/imsm CONTAINER, not a RAID volume.\n"
                "        Use the RAID volume inside it instead: %s"
                % (dev, dv.kname(dev), ", ".join(vols) or "(none assembled)"))
        info("md RAID device %s -> /dev/%s (level %s, metadata %s)" % (
            dev, dv.kname(dev), dv.md_level(dev), dv.md_metadata(dev)))
        if dv.md_metadata(dev).startswith("external:"):
            info("Firmware RAID (Intel RST / imsm) — ZFSBootMenu will be built with mdraid support")
        return "/dev/" + dv.kname(dev), True
    if dev.startswith("/dev/mapper/isw_"):
        die("%s is a dmraid (isw) device; ZFSBootMenu cannot use dmraid.\n"
            "        Use mdadm instead:  dmraid -an && mdadm --assemble --scan" % dev)
    if dev.startswith("/dev/dm-") or dev.startswith("/dev/mapper/"):
        warn("%s is a device-mapper device — not tested with ZFSBootMenu" % dev)
    return dev, False


def check_not_raid_member(dev):
    if dv.is_md(dev):
        return
    holders = dv.disk_md_holders(dev)
    if holders:
        die("%s is a member of md array(s) %s — writing to it would destroy the array.\n"
            "        Use the RAID volume instead: %s"
            % (dev, " ".join(holders), ", ".join(dv.md_suggest_volumes(dev))))
    exam = dz.out(["mdadm", "--examine", dev]) if dz.have("mdadm") else ""
    if re.search(r"Intel Raid ISM|Raid Level", exam):
        die("%s carries RAID metadata but the array is not assembled.\n"
            "        Run: mdadm --assemble --scan && cat /proc/mdstat, then use the RAID volume" % dev)


def check_not_in_use(dev, devices):
    if dv.device_mounted(dev, devices):
        die("%s (or one of its partitions) is mounted — unmount it first" % dev)
    if os.path.realpath(dev) in dv.zfs_pool_members():
        die("%s is part of an imported ZFS pool" % dev)


def validate_disk(plan, devices):
    if not os.path.exists(plan.disk) or not os.path.isabs(plan.disk):
        die("Disk %s not found" % plan.disk)
    plan.disk, plan.is_md = check_md_target(plan.disk)
    check_not_raid_member(plan.disk)
    part = dv.part_number(plan.disk)
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
    if d.get("type") in ("disk",) and not dv.is_md(dev):
        die("%s is a whole disk. Use --disk for a whole-disk install" % dev)
    if dv.is_md(dev) and dv.md_level(dev) == "container":
        check_md_target(dev)
    check_not_raid_member(dev)
    check_not_in_use(dev, devices)
    if d.get("parttype") == dv.ESP_GUID:
        die("%s is an EFI System Partition — choose a different partition for the pool" % dev)
    if d.get("parttype") == dv.MSR_GUID:
        die("%s is a Microsoft Reserved partition" % dev)
    if d["size"] and d["size"] < MIN_POOL_GIB * 1024 ** 3:
        die("%s is only %s; at least %d GiB is required" % (dev, dz.human_size(d["size"]), MIN_POOL_GIB))
    plan.is_md = plan.is_md or dv.is_md(dev)
    return d


def validate_esp(plan, devices):
    dev = plan.boot_device
    if not os.path.exists(dev):
        die("EFI partition %s not found" % dev)
    if os.path.realpath(dev) == os.path.realpath(plan.pool_device or "/nonexistent"):
        die("The EFI partition and the pool partition must be different")
    d = lookup(devices, dev) or {"path": dev, "size": 0, "fstype": "", "parttype": ""}
    if not dv.part_number(dev):
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
    elif d.get("parttype") and d["parttype"] != dv.ESP_GUID:
        warn("%s is FAT but its partition type is not 'EFI System' — firmware may ignore it" % dev)
    if d.get("mountpoint") and d["mountpoint"] != "/boot/efi":
        die("%s is mounted at %s — unmount it first" % (dev, d["mountpoint"]))
    plan.is_md = plan.is_md or dv.is_md(dev)


def show_devices(devices):
    info("Block devices:")
    for d in devices:
        if d.get("type") in ("loop", "rom"):
            continue
        print("    " + dv.describe(d))


def pool_candidates(devices):
    members = dv.zfs_pool_members()
    result = []
    for d in devices:
        if d.get("type") in ("disk", "loop", "rom") or d.get("type", "").startswith("raid") and \
                any(x.get("pkname") == d.get("kname") for x in devices):
            continue  # whole disks, and md volumes that have partitions
        if d.get("parttype") in (dv.ESP_GUID, dv.MSR_GUID):
            continue
        if d.get("mountpoint") or os.path.realpath(d["path"]) in members:
            continue
        if dv.disk_md_holders(d["path"]) or d["size"] < MIN_POOL_GIB * 1024 ** 3:
            continue
        if dv.is_md(d["path"]) and dv.md_level(d["path"]) == "container":
            continue
        result.append(d)
    return result


def esp_candidates(devices, exclude=""):
    return [d for d in devices
            if d.get("type") == "part"
            and (d.get("parttype") == dv.ESP_GUID or d.get("fstype") == "vfat")
            and os.path.realpath(d["path"]) != os.path.realpath(exclude or "/nonexistent")
            and not dv.disk_md_holders(d["path"])]


def pool_label(d):
    label = dv.describe(d)
    if d.get("fstype") == "zfs_member":
        label += "   <- old ZFS data will be ERASED"
    elif d.get("fstype") in ("ntfs", "BitLocker", "ext4", "xfs", "btrfs"):
        label += "   <- contains %s data, will be ERASED" % d["fstype"]
    return label


def select_partitions(plan):
    step("Select prepared partitions")
    devices = dv.lsblk_devices()
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
        labels = [dv.describe(d) + ("   (reuse, keeps Windows boot files)" if d.get("fstype") == "vfat"
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
    devices = dv.lsblk_devices()
    cands = esp_candidates(devices)
    idx = dz.choose("EFI System Partition:", [dv.describe(d) for d in cands] + ["Enter a path manually"])
    if idx is None:
        die("Cancelled")
    plan.boot_device = dz.ask("EFI partition path") if idx == len(cands) else cands[idx]["path"]


def select_disk(plan):
    devices = dv.lsblk_devices()
    disks = [d for d in devices
             if ((d.get("type") == "disk" and not dv.disk_md_holders(d["path"]))
                 or (d.get("type", "").startswith("raid") and dv.md_level(d["path"]) != "container"))
             and not dv.device_mounted(d["path"], devices)]
    if not disks:
        die("No disks found")
    idx = dz.choose("Target disk:", [dv.describe(d) for d in disks])
    if idx is None:
        die("Cancelled")
    plan.disk = disks[idx]["path"]


def settle_and_wait(*devs):
    if dz.DRY_RUN:
        return
    dz.run(["udevadm", "settle", "--timeout=30"], check=False, quiet=True)
    for _ in range(30):
        if all(os.path.exists(d) for d in devs):
            return
        time.sleep(1)
    die("Partition(s) did not appear: %s" % ", ".join(d for d in devs if not os.path.exists(d)))


def sgdisk_value(args):
    return dz.out(["sgdisk"] + args)


def resolve_disk_layout(plan, devices):
    validate_disk(plan, devices)
    plan.boot_device = dv.partition_device(plan.disk, plan.boot_part)
    plan.pool_device = dv.partition_device(plan.disk, plan.pool_part)
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
    plan.boot_device = dv.partition_device(plan.disk, plan.boot_part)
    plan.pool_device = dv.partition_device(plan.disk, plan.pool_part)

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
        devices = dv.lsblk_devices()
    plan.pool_device, md1 = check_md_target(plan.pool_device) if dv.is_md(plan.pool_device) and \
        not dv.part_number(plan.pool_device) else (plan.pool_device, False)
    d = validate_pool_partition(plan, devices)
    validate_esp(plan, devices)
    plan.is_md = plan.is_md or md1

    print()
    warn("Pool partition: %s  (%s) — ALL DATA on it will be ERASED" % (plan.pool_device, dv.describe(d)))
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
