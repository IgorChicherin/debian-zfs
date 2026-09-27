#!/usr/bin/env python3
"""usb-write.py — write the live ISO to a USB drive (ALL DATA ON IT IS DESTROYED).

Examples:
  sudo python3 scripts/usb-write.py              # choose the drive from a list
  sudo python3 scripts/usb-write.py /dev/sdX
  sudo python3 scripts/usb-write.py /dev/sdX path/to/other.iso
"""

import argparse
import os
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_DIR, "install"))

import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

DEFAULT_ISO = os.path.join(PROJECT_DIR, "output", "debian-zfs-live.iso")
CHUNK = 4 * 1024 * 1024


def system_disks():
    """Disks that hold the running system's /, /boot or /boot/efi (never write to them)."""
    disks = set()
    for mp in ("/", "/boot", "/boot/efi", "/home"):
        src = dz.out(["findmnt", "-n", "-o", "SOURCE", mp])
        if src.startswith("/dev/"):
            disks.add(dz.parent_kname(src))
            for h in dz.out(["lsblk", "-s", "-n", "-o", "KNAME", src]).split():
                disks.add(h)
    return disks


def pick_device(devices, protected):
    cands = [d for d in devices if d.get("type") == "disk" and d.get("kname") not in protected]
    removable = [d for d in cands if dz.out(["cat", "/sys/block/%s/removable" % d["kname"]]) == "1"
                 or "usb" in dz.out(["lsblk", "-dn", "-o", "TRAN", d["path"]])]
    listing = removable or cands
    idx = dz.choose("USB drive to overwrite%s:" % ("" if removable else " (no removable drives detected!)"),
                    [dz.describe(d) for d in listing])
    if idx is None:
        die("Cancelled")
    return listing[idx]["path"]


def write_image(iso, dev):
    size = os.path.getsize(iso)
    written = 0
    fd = os.open(dev, os.O_WRONLY | getattr(os, "O_SYNC", 0))
    try:
        with open(iso, "rb") as src:
            while True:
                buf = src.read(CHUNK)
                if not buf:
                    break
                os.write(fd, buf)
                written += len(buf)
                pct = written * 100 // size
                sys.stdout.write("\r  %s / %s  (%d%%)" % (dz.human_size(written), dz.human_size(size), pct))
                sys.stdout.flush()
        os.fsync(fd)
    finally:
        os.close(fd)
    print()


def main():
    ap = argparse.ArgumentParser(prog="usb-write.py", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device", nargs="?", help="USB drive, e.g. /dev/sdb (whole disk)")
    ap.add_argument("iso", nargs="?", default=DEFAULT_ISO, help="ISO file (default: output/debian-zfs-live.iso)")
    ap.add_argument("--yes", "-y", action="store_true", help="do not ask for confirmation")
    ap.add_argument("--dry-run", action="store_true", help="show what would be written")
    a = ap.parse_args()
    dz.set_dry_run(a.dry_run)
    dz.set_assume_yes(a.yes)
    dz.require_root()

    if not os.path.isfile(a.iso):
        die("ISO not found: %s (build it with: sudo python3 scripts/build-iso.py)" % a.iso)
    devices = dz.lsblk_devices()
    protected = system_disks()
    dev = a.device or pick_device(devices, protected)
    if not os.path.exists(dev):
        die("Device not found: %s" % dev)
    if dz.part_number(dev):
        die("%s is a partition — give the whole drive (e.g. /dev/sdb)" % dev)
    if dz.kname(dev) in protected:
        die("%s holds the running system — refusing to overwrite it" % dev)

    size = dz.human_size(int(dz.out(["blockdev", "--getsize64", dev], "0")))
    print()
    dz.banner("ALL DATA ON %s (%s) WILL BE DESTROYED" % (dev, size))
    dz.run(["lsblk", "-o", "NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT", dev], check=False, always=True)
    if not a.dry_run and not dz.confirm("Write %s to %s?" % (os.path.basename(a.iso), dev)):
        die("Cancelled")

    step("Unmounting %s" % dev)
    for d in devices:
        if (d.get("kname") == dz.kname(dev) or d.get("pkname") == dz.kname(dev)) and d.get("mountpoint"):
            dz.run(["umount", d["path"]], check=False)

    step("Writing %s (%s)" % (a.iso, dz.human_size(os.path.getsize(a.iso))))
    if a.dry_run:
        print("[DRY-RUN] write %s -> %s" % (a.iso, dev))
    else:
        write_image(a.iso, dev)
        dz.run(["sync"])
    print()
    dz.banner("USB DRIVE READY")
    info("Boot the target machine from it in UEFI mode, then run:  zfs-install --interactive")


if __name__ == "__main__":
    dz.run_main(main)
