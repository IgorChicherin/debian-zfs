#!/usr/bin/env python3
"""test-vm.py — boot the ISO or a disk in QEMU (UEFI by default).

Examples:
  python3 scripts/test-vm.py output/debian-zfs-live.iso
  python3 scripts/test-vm.py output/debian-zfs-live.iso --target-disk 40G
  sudo python3 scripts/test-vm.py --disk /dev/sdX --snapshot
  python3 scripts/test-vm.py test.iso --memory 8192 --cpus 8 --bios

--target-disk creates a throw-away qcow2 disk so you can run the installer
in the VM; add --raid0 to get two NVMe disks for testing md RAID 0
(QEMU cannot emulate Intel RST firmware, so create the array with mdadm).
"""

import argparse
import atexit
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_DIR, "install"))

import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

OVMF_CODE = ["/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_CODE.fd",
             "/usr/share/ovmf/OVMF.fd", "/usr/share/qemu/ovmf-x86_64-code.fd"]
OVMF_VARS = ["/usr/share/OVMF/OVMF_VARS_4M.fd", "/usr/share/OVMF/OVMF_VARS.fd",
             "/usr/share/qemu/ovmf-x86_64-vars.fd"]

TMP = tempfile.mkdtemp(prefix="qemu-dz-")
atexit.register(lambda: shutil.rmtree(TMP, ignore_errors=True))


def first_existing(paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return ""


def main():
    ap = argparse.ArgumentParser(prog="test-vm.py", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iso", nargs="?", help="ISO file to boot")
    ap.add_argument("--iso", dest="iso_opt", help="ISO file to boot")
    ap.add_argument("--disk", help="block device or image to boot (writes enabled unless --snapshot)")
    ap.add_argument("--target-disk", metavar="SIZE", help="add an empty qcow2 install disk, e.g. 40G")
    ap.add_argument("--raid0", action="store_true", help="with --target-disk: add two NVMe disks")
    ap.add_argument("--memory", type=int, default=4096, help="RAM in MB (default: 4096)")
    ap.add_argument("--cpus", type=int, default=4, help="CPUs (default: 4)")
    fw = ap.add_mutually_exclusive_group()
    fw.add_argument("--uefi", action="store_true", default=True, help="UEFI firmware (default)")
    fw.add_argument("--bios", action="store_true", help="legacy BIOS")
    ap.add_argument("--snapshot", action="store_true", help="discard all disk writes")
    ap.add_argument("--dry-run", action="store_true", help="print the QEMU command only")
    a = ap.parse_args()
    dz.set_dry_run(a.dry_run)
    iso = a.iso_opt or a.iso

    step("Checking prerequisites")
    if not dz.have("qemu-system-x86_64") and not a.dry_run:
        die("QEMU not installed: sudo apt install qemu-system-x86 qemu-utils ovmf")
    if not iso and not a.disk:
        die("Give an ISO file or --disk")
    if iso and not os.path.isfile(iso):
        die("ISO not found: %s" % iso)
    if a.disk and not os.path.exists(a.disk):
        die("Disk not found: %s" % a.disk)

    uefi = not a.bios
    code = vars_src = ""
    if uefi:
        code, vars_src = first_existing(OVMF_CODE), first_existing(OVMF_VARS)
        if not code or not vars_src:
            warn("OVMF firmware not found (sudo apt install ovmf)")
            if not dz.confirm("Continue with legacy BIOS?"):
                die("Cancelled")
            uefi = False

    args = ["qemu-system-x86_64", "-m", str(a.memory), "-smp", str(a.cpus),
            "-vga", "virtio", "-usb", "-device", "usb-tablet", "-name", "Debian-ZFS-Test",
            "-netdev", "user,id=net0,hostname=debian-zfs-test", "-device", "virtio-net,netdev=net0"]
    if os.access("/dev/kvm", os.R_OK | os.W_OK):
        args += ["-enable-kvm", "-cpu", "host"]
    else:
        warn("/dev/kvm not available — running without acceleration (slow)")
    if uefi:
        vars_copy = os.path.join(TMP, "OVMF_VARS.fd")
        shutil.copy(vars_src, vars_copy)
        args += ["-machine", "q35",
                 "-drive", "if=pflash,format=raw,readonly=on,file=%s" % code,
                 "-drive", "if=pflash,format=raw,file=%s" % vars_copy]
    args += ["-boot", "menu=on"]

    if iso:
        args += ["-drive", "file=%s,media=cdrom,readonly=on" % iso, "-boot", "d"]
    if a.disk:
        if a.snapshot:
            args += ["-drive", "file=%s,format=raw,if=virtio,snapshot=on" % a.disk]
            info("Snapshot mode — writes are discarded")
        else:
            warn("Direct disk access — WRITES ENABLED on %s" % a.disk)
            if not dz.confirm("Continue?"):
                die("Cancelled")
            args += ["-drive", "file=%s,format=raw,if=virtio" % a.disk]
    if a.target_disk:
        count = 2 if a.raid0 else 1
        for i in range(count):
            img = os.path.join(TMP, "target%d.qcow2" % i)
            dz.run(["qemu-img", "create", "-q", "-f", "qcow2", img, a.target_disk])
            args += ["-drive", "file=%s,if=none,id=nvm%d,format=qcow2" % (img, i),
                     "-device", "nvme,serial=dztest%d,drive=nvm%d" % (i, i)]
        info("Install disk(s): %d x %s NVMe (deleted on exit)" % (count, a.target_disk))

    info("Mode: %s | RAM %d MB | %d CPUs" % ("UEFI" if uefi else "BIOS", a.memory, a.cpus))
    print("\n" + shlex.join(args) + "\n")
    info("QEMU keys: Ctrl+Alt+G release mouse, Ctrl+Alt+2 monitor, close window = power off")
    if a.dry_run:
        return 0
    return subprocess.run(args).returncode


if __name__ == "__main__":
    dz.run_main(main)
