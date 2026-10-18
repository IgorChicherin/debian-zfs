#!/usr/bin/env python3
"""zbm_check_kernels.py — check (and fix) why ZFSBootMenu "failed to find kernels".

ZFSBootMenu boots kernels from <dataset>/boot (vmlinuz-* + initrd.img-*).
This mounts the root dataset read-write at a temporary path (without
changing its mountpoint property), lists kernels/initrds, checks the
ZFSBootMenu properties and, with --fix, reinstalls the kernel and rebuilds
the initramfs INSIDE that dataset via chroot.

Examples:
  zbm_check_kernels.py --pool zroot                 # dataset from the pool's bootfs
  zbm_check_kernels.py --pool zroot --dataset ROOT/trixie --fix
"""

import argparse
import glob
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

APT_ENV = {"DEBIAN_FRONTEND": "noninteractive"}


def kernels(root):
    ks = sorted(glob.glob(os.path.join(root, "boot", "vmlinuz-*")))
    ids = sorted(glob.glob(os.path.join(root, "boot", "initrd.img-*")))
    return ks, ids


def versions(paths, prefix):
    return {os.path.basename(p)[len(prefix):] for p in paths}


def mount_dataset(ds):
    """Return (root_path, cleanup_needed)."""
    if dz.out(["zfs", "get", "-H", "-o", "value", "mounted", ds]) == "yes":
        mp = dz.out(["findmnt", "-n", "-o", "TARGET", "-t", "zfs", "-S", ds]).splitlines()
        if mp:
            return mp[0], False
    tmp = tempfile.mkdtemp(prefix="zbm-check-")
    if dz.out(["zfs", "get", "-H", "-o", "value", "keystatus", ds]) == "unavailable":
        info("Dataset is encrypted — loading key")
        dz.run(["zfs", "load-key", ds], always=True)
    if dz.run(["mount", "-t", "zfs", "-o", "zfsutil", ds, tmp], always=True, check=False).returncode != 0:
        os.rmdir(tmp)
        die("Could not mount %s (is the pool imported? zpool import -N <pool>)" % ds)
    return tmp, True


def unmount(root):
    for sub in ("dev", "sys", "proc"):
        path = os.path.join(root, sub)
        if dz.ok(["mountpoint", "-q", path]):
            dz.run(["umount", "-R", path], check=False, always=True)
    dz.run(["umount", root], check=False, always=True)
    try:
        os.rmdir(root)
    except OSError:
        pass


def fix(root, running_system):
    step("Reinstalling the kernel inside the dataset")
    chroot = None if running_system else root
    if chroot:
        dz.run(["mount", "-t", "proc", "proc", root + "/proc"])
        for fs in ("/sys", "/dev"):
            dz.run(["mount", "--rbind", fs, root + fs])
            dz.run(["mount", "--make-rslave", root + fs])
        if os.path.exists("/etc/resolv.conf"):
            dz.run(["cp", "-L", "--remove-destination", "/etc/resolv.conf", root + "/etc/resolv.conf"], check=False)
    dz.run(["apt-get", "update"], chroot=chroot, env=APT_ENV)
    dz.run(["apt-get", "install", "--reinstall", "-y", "linux-image-amd64"], chroot=chroot, env=APT_ENV)
    ks, ids = kernels(root)
    missing = versions(ks, "vmlinuz-") - versions(ids, "initrd.img-")
    for ver in sorted(missing):
        dz.run(["update-initramfs", "-c", "-k", ver], chroot=chroot)
    dz.run(["update-initramfs", "-u", "-k", "all"], chroot=chroot)


def main():
    ap = argparse.ArgumentParser(prog="zbm_check_kernels.py", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pool", default="zroot")
    ap.add_argument("--dataset", default="", help="root dataset (default: from the pool's bootfs)")
    ap.add_argument("--fix", action="store_true", help="reinstall kernel / rebuild initramfs if missing")
    ap.add_argument("--dry-run", action="store_true", help="print fix commands only")
    a = ap.parse_args()
    dz.set_dry_run(a.dry_run)
    dz.require_root()

    ds = "%s/%s" % (a.pool, a.dataset or dz.default_root_dataset(a.pool))
    step("Checking ZFSBootMenu kernel detection for %s" % ds)
    if not dz.ok(["zfs", "list", ds]):
        die("Dataset %s not found (is the pool imported? zpool import -N %s)" % (ds, a.pool))

    root, cleanup = mount_dataset(ds)
    running_system = root == "/"
    try:
        ks, ids = kernels(root)
        info("Found %d kernel(s) and %d initrd(s) in %s/boot" % (len(ks), len(ids), root.rstrip("/")))
        for p in ks + ids:
            print("    %s  %s" % (os.path.basename(p), dz.human_size(os.path.getsize(p))))
        unmatched = versions(ks, "vmlinuz-") ^ versions(ids, "initrd.img-")
        broken = not ks or not ids or unmatched
        if unmatched:
            warn("Kernel/initrd versions without a partner: %s" % ", ".join(sorted(unmatched)))

        if broken:
            if a.fix:
                fix(root, running_system)
                ks, ids = kernels(root)
                if ks and ids and not (versions(ks, "vmlinuz-") ^ versions(ids, "initrd.img-")):
                    info("Fixed ✓")
                elif not dz.DRY_RUN:
                    die("Fix failed — check the apt output above")
            else:
                warn("Run with --fix to reinstall the kernel inside the dataset")
        else:
            info("Kernels detected ✓")

        step("ZFSBootMenu properties")
        cmdline = dz.out(["zfs", "get", "-H", "-o", "value", "org.zfsbootmenu:commandline", ds], "-")
        info("org.zfsbootmenu:commandline: %s" % cmdline)
        if cmdline in ("-", ""):
            warn("commandline not set — setting 'quiet loglevel=0'")
            dz.run(["zfs", "set", "org.zfsbootmenu:commandline=quiet loglevel=0", ds])
        bootfs = dz.out(["zpool", "get", "-H", "-o", "value", "bootfs", a.pool], "-")
        info("bootfs: %s" % bootfs)
        if bootfs in ("-", ""):
            warn("bootfs not set — ZFSBootMenu will not auto-boot. Fix: zpool set bootfs=%s %s" % (ds, a.pool))
        if dz.out(["zfs", "get", "-H", "-o", "value", "canmount", ds]) == "off":
            warn("canmount=off on %s — ZFSBootMenu ignores it. Fix: zfs set canmount=noauto %s" % (ds, ds))
        if dz.out(["zfs", "get", "-H", "-o", "value", "mountpoint", ds]) != "/":
            warn("mountpoint of %s is not '/' — ZFSBootMenu only lists datasets with mountpoint=/" % ds)
    finally:
        if cleanup:
            unmount(root)
    step("Check completed")


if __name__ == "__main__":
    dz.run_main(main)
