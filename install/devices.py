"""devices — block device, md RAID and hardware lookups for the debian-zfs installer scripts.

Standard library only; sysfs based, so it works inside a chroot too.
"""

import glob
import json
import os

import dzlib as dz

# Allow tests to point the sysfs / by-id lookups at a fake tree
SYSFS = os.environ.get("DZ_SYSFS", "/sys")
BY_ID = os.environ.get("DZ_BY_ID", "/dev/disk/by-id")

ESP_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
ZFS_GUIDS = {
    "6a898cc3-1dd2-11b2-99a6-080020736631",  # Solaris /usr & Apple ZFS (bf00)
    "6a85cf4d-1dd2-11b2-99a6-080020736631",  # Solaris root (bf01)
}
MSR_GUID = "e3c9e316-0b5c-4db8-817d-f92df00215ae"


def _read(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


def kname(dev):
    """/dev/md/Volume0_0 -> md126 ; /dev/nvme0n1p2 -> nvme0n1p2"""
    return os.path.basename(os.path.realpath(dev))


def parent_kname(dev):
    """md126p1 -> md126 ; sda1 -> sda ; sda -> sda"""
    name = kname(dev)
    cls = os.path.join(SYSFS, "class/block", name)
    if os.path.exists(os.path.join(cls, "partition")):
        return os.path.basename(os.path.dirname(os.path.realpath(cls)))
    return name


def part_number(dev):
    return _read(os.path.join(SYSFS, "class/block", kname(dev), "partition"))


def partition_device(disk, number):
    """Partition node name: /dev/sda + 1 -> /dev/sda1, /dev/md126 -> /dev/md126p1."""
    disk = disk.rstrip("/")
    return "%s%s%s" % (disk, "p" if disk[-1].isdigit() else "", number)


def is_md(dev):
    return os.path.isdir(os.path.join(SYSFS, "block", parent_kname(dev), "md"))


def md_level(dev):
    return _read(os.path.join(SYSFS, "block", parent_kname(dev), "md/level"))


def md_state(dev):
    """array_state of an md volume: clean, active, inactive, readonly ..."""
    return _read(os.path.join(SYSFS, "block", parent_kname(dev), "md/array_state"))


def md_metadata(dev):
    return _read(os.path.join(SYSFS, "block", parent_kname(dev), "md/metadata_version"))


def md_chunk_size(dev):
    try:
        return int(_read(os.path.join(SYSFS, "block", parent_kname(dev), "md/chunk_size"), "0"))
    except ValueError:
        return 0


def md_container_volumes(container):
    """RAID volumes inside an imsm/ddf container: md127 -> ['/dev/md126']"""
    cname = kname(container)
    vols = []
    for md in sorted(glob.glob(os.path.join(SYSFS, "block", "md*"))):
        meta = _read(os.path.join(md, "md/metadata_version"))
        if meta.startswith("external:/%s/" % cname) or meta.startswith("external:%s/" % cname):
            vols.append("/dev/" + os.path.basename(md))
    return vols


def disk_md_holders(dev):
    """md arrays a disk or any of its partitions belongs to."""
    name = kname(dev)
    holders = set()
    for pattern in ("block/%s/holders/md*" % name, "block/%s/%s*/holders/md*" % (name, name)):
        for h in glob.glob(os.path.join(SYSFS, pattern)):
            holders.add(os.path.basename(h))
    return sorted(holders)


def md_first_member(dev):
    """raid-disk 0 of an md volume (holds the start of a RAID0 array)."""
    md = parent_kname(dev)
    link = os.path.join(SYSFS, "block", md, "md/rd0")
    if os.path.islink(link):
        return os.path.basename(os.readlink(link)).replace("dev-", "", 1)
    slaves = sorted(glob.glob(os.path.join(SYSFS, "block", md, "slaves", "*")))
    return os.path.basename(slaves[0]) if slaves else ""


def md_suggest_volumes(dev):
    """For a container or a member disk: RAID volumes the user should use."""
    result = []
    names = [kname(dev)] if is_md(dev) else disk_md_holders(dev)
    for h in names:
        if md_level("/dev/" + h) == "container":
            result.extend(md_container_volumes("/dev/" + h))
        else:
            result.append("/dev/" + h)
    return sorted(set(result))


def stable_device_path(dev):
    """/dev/disk/by-id path for a device (md-uuid-*, wwn-*, nvme-eui.* preferred)."""
    target = os.path.realpath(dev)
    links = sorted(glob.glob(os.path.join(BY_ID, "*")))
    for prefix in ("md-uuid-", "wwn-", "nvme-eui.", ""):
        for link in links:
            if os.path.basename(link).startswith(prefix) and os.path.realpath(link) == target:
                return link
    return dev


def lsblk_devices():
    """Flattened lsblk output (dicts with lower-case keys). Sizes in bytes."""
    cols = "NAME,KNAME,PATH,SIZE,TYPE,FSTYPE,PARTTYPE,PARTLABEL,LABEL,MOUNTPOINT,PKNAME,MODEL"
    raw = dz.out(["lsblk", "-J", "-b", "-o", cols])
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except ValueError:
        return []
    flat = []

    def walk(nodes):
        for n in nodes:
            item = {k.lower(): v for k, v in n.items() if k != "children"}
            item["size"] = int(item.get("size") or 0)
            item["parttype"] = (item.get("parttype") or "").lower()
            flat.append(item)
            walk(n.get("children", []))

    walk(data.get("blockdevices", []))
    # de-duplicate (md volumes show up under every member)
    seen, unique = set(), []
    for d in flat:
        if d["path"] not in seen:
            seen.add(d["path"])
            unique.append(d)
    return unique


def device_mounted(dev, devices=None):
    """True if the device or any of its children is mounted / used as swap."""
    devices = devices if devices is not None else lsblk_devices()
    name = kname(dev)
    for d in devices:
        if d.get("kname") == name or d.get("pkname") == name:
            if d.get("mountpoint"):
                return True
    return False


def describe(d):
    bits = [d["path"], dz.human_size(d["size"]), d.get("type") or ""]
    if d.get("fstype"):
        bits.append(d["fstype"])
    label = d.get("partlabel") or d.get("label")
    if label:
        bits.append("'%s'" % label)
    if d.get("parttype") == ESP_GUID:
        bits.append("[EFI System]")
    if d.get("mountpoint"):
        bits.append("mounted:%s" % d["mountpoint"])
    if d.get("model"):
        bits.append(d["model"].strip())
    return "  ".join(b for b in bits if b)


def zfs_pool_members():
    """Real device nodes that belong to imported pools."""
    members = set()
    for line in dz.out(["zpool", "status", "-P", "-L"]).splitlines():
        word = line.strip().split(" ")[0] if line.strip() else ""
        if word.startswith("/dev/"):
            members.add(os.path.realpath(word))
    return members


def dmi(field):
    return _read(os.path.join(SYSFS, "class/dmi/id", field))


# Broadcom Wi-Fi chips handled by the proprietary 'wl' driver (broadcom-sta-dkms),
# incl. MacBook BCM4331 (2012) and BCM4360 (2013-2015)
BROADCOM_WL_IDS = {"0x4311", "0x4312", "0x4313", "0x4315", "0x4328", "0x4329", "0x432a", "0x432b",
                   "0x432c", "0x432d", "0x4331", "0x4353", "0x4357", "0x4358", "0x4359", "0x4360",
                   "0x4365", "0x43a0", "0x43b1"}


def broadcom_wl_devices():
    """PCI addresses of Broadcom Wi-Fi chips that need broadcom-sta (wl)."""
    found = []
    for dev in glob.glob(os.path.join(SYSFS, "bus/pci/devices/*")):
        if _read(os.path.join(dev, "vendor")) == "0x14e4" and \
                _read(os.path.join(dev, "device")).lower() in BROADCOM_WL_IDS:
            found.append(os.path.basename(dev))
    return found


def uefi_booted():
    return os.path.isdir(os.path.join(SYSFS, "firmware/efi"))
