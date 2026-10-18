#!/usr/bin/env python3
"""debian_zfs_install.py — Debian 13 (stable) or sid on a ZFS root with ZFSBootMenu and ZRAM.

Install targets (pick one):

  Whole disk (ERASES the disk):
      debian_zfs_install.py --disk /dev/nvme0n1
      debian_zfs_install.py --disk /dev/md126            # Intel RST RAID 0 volume

  Free space next to Windows (keeps all partitions, reuses the ESP):
      debian_zfs_install.py --disk /dev/nvme0n1 --use-free-space [--efi-part 1]

  Already prepared partitions (only the chosen partition is erased):
      debian_zfs_install.py --pool-part /dev/nvme0n1p5 --efi-device /dev/nvme0n1p1
      debian_zfs_install.py --select-partitions          # pick them from a list

  Existing ZFS pool (new or existing ROOT/<name> boot environment):
      debian_zfs_install.py --pool zroot --efi-device /dev/sda1
      debian_zfs_install.py --use-existing-pool          # pick pool and ESP from a list

  Guided wizard for all of the above:
      debian_zfs_install.py --interactive

Release (default: stable = Debian 13 "trixie"):
      debian_zfs_install.py --disk /dev/sda --release stable
      debian_zfs_install.py --disk /dev/sda --release sid     # unstable, rolling

MacBook (e.g. A1398):  --macbook  adds the built-in keyboard/trackpad drivers
to ZFSBootMenu, the Apple "EFI Boot" fallback loader and the Broadcom Wi-Fi
driver (wl). Wired network + SSH in the boot menu:
      --zbm-network --ssh-key ~/.ssh/id_ed25519.pub

Intel RST RAID: pass the RAID *volume* (usually /dev/md126 or
/dev/md/Volume0_0), never the imsm container (usually /dev/md127) or a member
NVMe disk. ZFSBootMenu is then built locally with mdadm support.
"""

import glob
import os
import re
import shutil
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import devices as dv  # noqa: E402
import dzlib as dz  # noqa: E402
import plan as pl  # noqa: E402
import system  # noqa: E402
import target  # noqa: E402
import zfsops  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402


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
        extra.append("deb %s %s main contrib non-free-firmware" % (dz.MIRROR, host))
    use_backports = host == "bookworm"   # bookworm's own ZFS 2.1 is too old
    if use_backports and "bookworm-backports" not in sources:
        extra.append("deb %s bookworm-backports main contrib non-free-firmware" % dz.MIRROR)
    if extra:
        info("Adding APT sources: %s" % "; ".join(extra))
        dz.write_file("/etc/apt/sources.list.d/debian-zfs-installer.list", "\n".join(extra) + "\n")

    dz.run(["apt-get", "update"], env=system.APT_ENV)
    kernel = os.uname().release
    zfs_cmd = ["apt-get", "install", "-y"]
    if use_backports:
        zfs_cmd += ["-t", "bookworm-backports"]
    dz.run(zfs_cmd + ["zfsutils-linux", "zfs-dkms", "linux-headers-%s" % kernel], env=system.APT_ENV)
    dz.run(["apt-get", "install", "-y", "debootstrap", "debian-archive-keyring", "gdisk", "dkms",
            "curl", "dosfstools", "efibootmgr", "mdadm", "cpio", "kexec-tools"], env=system.APT_ENV)
    dz.run(["modprobe", "zfs"])


def install_zfsbootmenu(plan):
    step("Installing ZFSBootMenu")
    argv = ["--yes", "--pool", plan.pool_name, "--dataset", "ROOT/%s" % plan.be_name,
            "--boot-device", plan.boot_device]
    if plan.is_md:
        argv.append("--mdraid")
        info("Intel RST / md RAID: building ZFSBootMenu locally with mdraid support")
    if plan.macbook:
        argv.append("--macbook")
        info("MacBook: ZFSBootMenu gets the built-in keyboard/trackpad drivers")
    if plan.zbm_network:
        argv.append("--network")
        info("ZFSBootMenu gets wired network + SSH (port 222)")
    system.run_zbm_setup(argv, plan.ssh_key if plan.zbm_network else "")


def configure_zram(plan):
    step("Configuring ZRAM swap")
    dz.write_file(zfsops.MOUNT_POINT + "/etc/systemd/zram-generator.conf",
                  "[zram0]\nzram-size = min(ram * 0.6, 4096)\n"
                  "compression-algorithm = zstd\nswap-priority = 100\nfs-type = swap\n")


def finalize(plan):
    step("Finalizing")
    system.teardown(plan.pool_name)
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


def main():
    args = pl.parse_args(sys.argv[1:], __doc__)
    dz.set_dry_run(args.dry_run)
    dz.set_assume_yes(args.yes)
    dz.require_root()
    if not dv.uefi_booted():
        warn("The live system was not booted in UEFI mode — EFI boot entries cannot be created")

    info("═" * 55)
    info("Debian on ZFS root — installer")
    info("═" * 55)
    plan = pl.build_plan(args)
    devices = dv.lsblk_devices()

    if plan.mode == "disk":
        target.resolve_disk_layout(plan, devices)
    elif plan.mode == "free-space":
        target.resolve_free_space_layout(plan, devices)
    elif plan.mode == "partitions":
        target.resolve_partitions_layout(plan, devices)
    else:
        if not plan.boot_device:
            die("--efi-device is required with an existing pool")
        target.validate_esp(plan, devices)
        members = dz.out(["zpool", "status", "-P", "-L", plan.pool_name])
        plan.is_md = plan.is_md or bool(re.search(r"\s/dev/md", members))

    if plan.encrypt and not plan.passphrase and plan.mode != "existing-pool":
        plan.passphrase = dz.ask_passphrase()

    plan.wl_devices = dv.broadcom_wl_devices()
    if plan.macbook:
        info("MacBook drivers: enabled%s" % (" (Broadcom Wi-Fi %s → wl)" % ", ".join(plan.wl_devices)
                                             if plan.wl_devices else ""))
    elif dv.dmi("sys_vendor").startswith("Apple") or plan.wl_devices:
        warn("%s detected — add --macbook for the built-in keyboard in ZFSBootMenu and the Wi-Fi driver"
             % ("Apple hardware (%s)" % dv.dmi("product_name") if dv.dmi("sys_vendor").startswith("Apple")
                else "Broadcom Wi-Fi (%s)" % ", ".join(plan.wl_devices)))
    info("Release: %s" % dz.RELEASES[plan.release]["label"])
    info("Mode: %s | pool: %s | root: %s | ESP: %s | md RAID: %s"
         % (plan.mode, plan.pool_name, plan.root_ds, plan.boot_device, plan.is_md))

    if not plan.skip_packages:
        install_host_packages(plan)
    zfsops.ensure_hostid()

    if plan.mode == "existing-pool":
        zfsops.prepare_existing_pool(plan)
    else:
        target.prepare_disk(plan)
        zfsops.create_pool(plan)
        zfsops.create_datasets(plan)
        zfsops.import_pool(plan)
    zfsops.mount_datasets(plan)
    system.install_debian(plan)
    system.prepare_chroot(plan)
    system.configure_system(plan)
    system.setup_esp(plan)
    install_zfsbootmenu(plan)
    configure_zram(plan)
    finalize(plan)


if __name__ == "__main__":
    dz.run_main(main)
