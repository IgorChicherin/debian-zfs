#!/usr/bin/env python3
"""build-iso.py — build a Debian 13 (stable) or sid live ISO with ZFS and the installer.

Requirements: Debian host (or Ubuntu/WSL on a native Linux filesystem),
live-build, debian-archive-keyring, 10 GB free space, root.

Examples:
  sudo python3 scripts/build-iso.py
  sudo python3 scripts/build-iso.py --clean --output-dir output
  sudo python3 scripts/build-iso.py --release sid     # unstable live system
  sudo python3 scripts/build-iso.py --macbook         # + MacBook Broadcom Wi-Fi driver

The installer on the ISO can install either branch regardless of the
branch the live system itself is built from.
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_DIR, "install"))

import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

LB_CONFIG_DIR = os.path.join(PROJECT_DIR, "config", "live-build")
WORK_DIR = os.path.join(PROJECT_DIR, "live-build-work")
MIRROR = dz.MIRROR
SECURITY = dz.SECURITY_MIRROR
ISO_NAME = "debian-zfs-live.iso"
AREAS = dz.COMPONENTS


def check_prerequisites(a):
    step("Checking prerequisites")
    if PROJECT_DIR.startswith("/mnt/"):
        warn("Project is on a Windows drive (%s) — live-build on NTFS/DrvFs usually fails" % PROJECT_DIR)
        info("Copy it to the Linux filesystem first:  cp -r %s ~/debian-zfs" % PROJECT_DIR)
        if not dz.confirm("Continue anyway?"):
            die("Cancelled")
    missing = [p for p, path in (("live-build", "/usr/bin/lb"),
                                 ("debian-archive-keyring", "/usr/share/keyrings/debian-archive-keyring.gpg"))
               if not os.path.exists(path)]
    if missing:
        warn("Missing: %s" % " ".join(missing))
        if not dz.confirm("Install them now?"):
            die("Required: apt install %s" % " ".join(missing))
        dz.run(["apt-get", "update"])
        dz.run(["apt-get", "install", "-y"] + missing, env={"DEBIAN_FRONTEND": "noninteractive"})
    st = os.statvfs(PROJECT_DIR)
    free_gb = st.f_bavail * st.f_frsize // 1024 ** 3
    if free_gb < 10:
        die("At least 10 GB free space required (available: %d GB)" % free_gb)
    info("Free space: %d GB ✓" % free_gb)


def clean(a):
    step("Cleaning previous builds")
    if os.path.isdir(WORK_DIR):
        dz.run(["rm", "-rf", WORK_DIR])
    out_dir = os.path.join(PROJECT_DIR, a.output_dir)
    if os.path.isdir(out_dir):
        dz.run(["rm", "-rf", out_dir])


def copy_tree(src, dst):
    if dz.DRY_RUN:
        print("[DRY-RUN] copy %s -> %s" % (src, dst))
        return
    shutil.copytree(src, dst, dirs_exist_ok=True)


def setup_live_build(a):
    step("Configuring live-build")
    os.makedirs(WORK_DIR, exist_ok=True)
    os.chdir(WORK_DIR)
    if os.path.isdir("config"):
        dz.run(["lb", "clean"], check=False)
        dz.run(["rm", "-rf", "auto", "config", "cache"])

    # --mode debian and explicit mirrors: on Ubuntu/WSL hosts live-build
    # otherwise defaults to archive.ubuntu.com and debootstrap fails
    rel = dz.RELEASES[a.release]
    info("Live system: %s" % rel["label"])
    # --mode debian and explicit mirrors: on Ubuntu/WSL hosts live-build
    # otherwise defaults to archive.ubuntu.com and debootstrap fails
    dz.run(["lb", "config",
            "--mode", "debian",
            "--architecture", "amd64",
            "--distribution", rel["codename"],
            "--archive-areas", AREAS,
            "--linux-flavours", "amd64",
            "--mirror-bootstrap", MIRROR,
            "--mirror-chroot", MIRROR,
            "--mirror-chroot-security", SECURITY,
            "--mirror-binary", MIRROR,
            "--mirror-binary-security", SECURITY,
            "--security", "true" if rel["security"] else "false",
            "--updates", "true" if rel["updates"] else "false",
            "--binary-images", "iso-hybrid",
            "--bootappend-live", "boot=live components"])
    # Debian 13 and sid ship OpenZFS 2.3 in contrib — no backports needed

    pkg_dir = os.path.join(LB_CONFIG_DIR, "package-lists")
    for f in glob.glob(os.path.join(pkg_dir, "*.chroot")):
        dz.run(["mkdir", "-p", "config/package-lists"])
        dz.run(["cp", f, "config/package-lists/"])
    if a.macbook:
        opt = os.path.join(LB_CONFIG_DIR, "optional", "macbook.list.chroot")
        dz.run(["mkdir", "-p", "config/package-lists"])
        dz.run(["cp", opt, "config/package-lists/"])
        info("MacBook: Broadcom Wi-Fi driver (broadcom-sta-dkms) added to the live system")
    inc = os.path.join(LB_CONFIG_DIR, "includes.chroot")
    if os.path.isdir(inc):
        copy_tree(inc, "config/includes.chroot")

    # Always ship the current installer (Python scripts + shared config)
    target = "config/includes.chroot/etc/install"
    dz.run(["mkdir", "-p", target])
    for f in glob.glob(os.path.join(PROJECT_DIR, "install", "*.py")):
        dz.run(["cp", f, target + "/"])
    cfg = os.path.join(PROJECT_DIR, "config", "zfsbootmenu")
    if os.path.isdir(cfg):
        copy_tree(cfg, target + "/config/zfsbootmenu")
    dz.run(["sh", "-c", "chmod +x %s/*.py" % target])
    info("Installer synced into the image (/etc/install)")


def build(a):
    step("Building ISO (20-40 minutes, log: %s/build.log)" % WORK_DIR)
    out_dir = os.path.join(PROJECT_DIR, a.output_dir)
    dz.run(["mkdir", "-p", out_dir])
    if dz.DRY_RUN:
        dz.run(["lb", "build"])
        return
    with open("build.log", "w") as log:
        rc = subprocess.run(["lb", "build"], stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        with open("build.log") as fh:
            tail = fh.readlines()[-50:]
        sys.stdout.write("".join(tail))
        die("Build failed (exit %d) — see %s/build.log" % (rc, WORK_DIR))

    isos = sorted(glob.glob("*.iso"), key=os.path.getmtime, reverse=True) or \
        sorted(glob.glob("**/*.iso", recursive=True))
    if not isos:
        die("Build finished but no .iso found in %s" % WORK_DIR)
    dest = os.path.join(out_dir, ISO_NAME)
    shutil.copy(isos[0], dest)
    sha = subprocess.run(["sha256sum", ISO_NAME], cwd=out_dir, stdout=subprocess.PIPE,
                         text=True, check=True).stdout
    dz.write_file(dest + ".sha256", sha)
    info("ISO: %s (%s)" % (dest, dz.human_size(os.path.getsize(dest))))
    info("SHA256: %s" % sha.split()[0])


def main():
    ap = argparse.ArgumentParser(prog="build-iso.py", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clean", action="store_true", help="remove previous build and output first")
    ap.add_argument("--output-dir", default="output", help="output directory (default: output)")
    ap.add_argument("--release", default=dz.DEFAULT_RELEASE,
                    help="live system branch: stable (Debian 13 trixie, default) or sid")
    ap.add_argument("--macbook", action="store_true",
                    help="include the MacBook Broadcom Wi-Fi driver (broadcom-sta-dkms) in the live system")
    ap.add_argument("--yes", "-y", action="store_true", help="never prompt")
    ap.add_argument("--dry-run", action="store_true", help="print commands only")
    a = ap.parse_args()
    a.release = dz.resolve_release(a.release)
    dz.set_dry_run(a.dry_run)
    dz.set_assume_yes(a.yes)
    dz.require_root()

    check_prerequisites(a)
    if a.clean:
        clean(a)
    setup_live_build(a)
    build(a)
    print()
    dz.banner("ISO BUILT")
    iso = os.path.join(PROJECT_DIR, a.output_dir, ISO_NAME)
    info("Write to USB:  sudo python3 scripts/usb-write.py /dev/sdX")
    info("Test in QEMU:  python3 scripts/test-vm.py %s" % iso)
    info("Working directory kept for debugging: %s" % WORK_DIR)


if __name__ == "__main__":
    dz.run_main(main)
