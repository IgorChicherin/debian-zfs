"""plan: command line, wizard and the Plan object for the Debian ZFS installer."""

import argparse
import os

import devices as dv
import dzlib as dz
import target
from dzlib import die, step


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
        target.select_disk(plan)
    elif plan.mode == "partitions":
        target.select_partitions(plan)
    else:
        target.select_existing_pool(plan)
        target.select_esp_only(plan)

    if plan.mode != "existing-pool":
        plan.pool_name = dz.ask("Pool name", plan.pool_name)
    plan.hostname = dz.ask("Hostname", plan.hostname)
    if plan.mode != "existing-pool":
        plan.encrypt = dz.ask("Enable ZFS native encryption? (y/n)", "n").lower().startswith("y")
    if not plan.macbook:
        is_mac = dv.dmi("sys_vendor").startswith("Apple")
        plan.macbook = dz.ask("Enable MacBook drivers (keyboard in boot menu, Broadcom Wi-Fi)? (y/n)",
                              "y" if is_mac else "n").lower().startswith("y")


def parse_args(argv, doc):
    ap = argparse.ArgumentParser(
        prog="debian_zfs_install.py", description=doc.split("\n\n")[0],
        epilog="\n\n".join(doc.split("\n\n")[1:]),
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
            target.select_existing_pool(plan)
        if not plan.boot_device:
            target.select_esp_only(plan)
    elif args.pool_part or args.select_partitions:
        plan.mode = "partitions"
    elif args.disk:
        plan.mode = "free-space" if args.use_free_space else "disk"
    else:
        die("Choose a target: --disk, --pool-part/--select-partitions, --pool/--use-existing-pool "
            "or --interactive (see --help)")
    return plan
