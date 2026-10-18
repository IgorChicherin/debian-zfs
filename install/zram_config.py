#!/usr/bin/env python3
"""zram_config.py — ZRAM compressed swap via systemd-zram-generator.

Examples:
  zram_config.py                              # 60% of RAM (max 4 GiB), zstd, swap
  zram_config.py --size 8192 --algorithm lz4  # 8 GiB with lz4
  zram_config.py --size "ram / 2"             # any zram-generator expression
  zram_config.py --status
  zram_config.py --remove
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

CONFIG = "/etc/systemd/zram-generator.conf"
GENERATORS = ["/usr/lib/systemd/system-generators/zram-generator",
              "/lib/systemd/system-generators/zram-generator"]


def generator_path():
    for path in GENERATORS:
        if os.access(path, os.X_OK):
            return path
    return ""


def show_status():
    step("ZRAM status")
    info("ZRAM devices:")
    if dz.have("zramctl"):
        dz.run(["zramctl"], check=False, always=True)
    else:
        warn("zramctl not installed")
    info("Swap devices:")
    dz.run(["swapon", "--show"], check=False, always=True)
    info("Unit dev-zram0.swap: %s" % (dz.out(["systemctl", "is-active", "dev-zram0.swap"]) or "not found"))
    if os.path.exists(CONFIG):
        info("Configuration %s:" % CONFIG)
        print(open(CONFIG).read())
    else:
        warn("No configuration at %s" % CONFIG)
    dz.run(["free", "-h"], check=False, always=True)


def remove_config():
    step("Removing ZRAM configuration")
    if os.path.exists("/dev/zram0"):
        dz.run(["swapoff", "/dev/zram0"], check=False, quiet=True)
    dz.run(["systemctl", "stop", "dev-zram0.swap"], check=False, quiet=True)
    if os.path.exists(CONFIG):
        dz.run(["rm", "-f", CONFIG])
    dz.run(["systemctl", "daemon-reload"], check=False)
    info("ZRAM removed")


def install_package():
    step("Installing systemd-zram-generator")
    path = generator_path()
    if path:
        info("zram-generator found at %s" % path)
        return
    dz.run(["apt-get", "update"])
    dz.run(["apt-get", "install", "-y", "systemd-zram-generator"], env={"DEBIAN_FRONTEND": "noninteractive"})
    if not dz.DRY_RUN and not generator_path():
        die("systemd-zram-generator installed but the generator binary is missing\n"
            "        try: apt install --reinstall systemd-zram-generator")


def write_config(a):
    step("Writing %s" % CONFIG)
    if os.path.exists(CONFIG):
        warn("Existing configuration:")
        print(open(CONFIG).read())
        if not dz.confirm("Overwrite?"):
            info("Keeping the existing configuration")
            return
    if a.filesystem:
        body = ("[zram0]\nzram-size = {size}\ncompression-algorithm = {alg}\n"
                "fs-type = ext4\nmount-point = /var/compressed\n")
    else:
        body = ("[zram0]\nzram-size = {size}\ncompression-algorithm = {alg}\n"
                "swap-priority = {prio}\nfs-type = swap\n")
    dz.write_file(CONFIG, body.format(size=a.size, alg=a.algorithm, prio=a.priority))
    if not dz.DRY_RUN:
        print(open(CONFIG).read())


def activate(a):
    step("Activating ZRAM")
    if not dz.ok(["systemctl", "is-system-running"]) and \
            dz.out(["systemctl", "is-system-running"]) in ("", "offline"):
        warn("systemd is not running (chroot?) — the configuration applies after reboot")
        return
    dz.run(["systemctl", "daemon-reload"])
    if dz.DRY_RUN:
        return
    time.sleep(1)
    unit = "var-compressed.mount" if a.filesystem else "dev-zram0.swap"
    if dz.run(["systemctl", "restart", unit], check=False).returncode != 0:
        warn("Could not start %s — check: journalctl -xeu %s" % (unit, unit))
        warn("In a live environment ZRAM may only work after reboot")
        return
    info("%s: %s" % (unit, dz.out(["systemctl", "is-active", unit])))
    dz.run(["zramctl"], check=False)
    dz.run(["swapon", "--show"], check=False)


def main():
    ap = argparse.ArgumentParser(prog="zram_config.py", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", default="min(ram * 0.6, 4096)",
                    help="MiB or zram-generator expression (default: min(ram * 0.6, 4096))")
    ap.add_argument("--algorithm", default="zstd", help="zstd, lz4, lzo-rle ... (default: zstd)")
    ap.add_argument("--priority", default="100", help="swap priority (default: 100)")
    ap.add_argument("--filesystem", action="store_true", help="ext4 at /var/compressed instead of swap")
    ap.add_argument("--swap", action="store_true", help="use as swap (default)")
    ap.add_argument("--remove", action="store_true", help="remove the configuration")
    ap.add_argument("--status", action="store_true", help="show status")
    ap.add_argument("--yes", "-y", action="store_true", help="never prompt")
    ap.add_argument("--dry-run", action="store_true", help="print commands only")
    a = ap.parse_args()
    dz.set_dry_run(a.dry_run)
    dz.set_assume_yes(a.yes)

    if a.status:
        show_status()
        return
    dz.require_root()
    if a.remove:
        remove_config()
        return
    install_package()
    write_config(a)
    activate(a)
    print()
    dz.banner("ZRAM CONFIGURED")
    info("Size: %s | algorithm: %s | mode: %s" % (a.size, a.algorithm, "filesystem" if a.filesystem else "swap"))
    info("Check with: zramctl, swapon --show, free -h")


if __name__ == "__main__":
    dz.run_main(main)
