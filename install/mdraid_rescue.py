#!/usr/bin/env python3
"""mdraid_rescue.py — repair md RAID (Intel RST / mdadm) support of an installed Debian ZFS-root system from the live ISO.

Use it when ZFSBootMenu shows no pool, or the booted kernel drops to an initramfs shell because the array is
not assembled. It assembles the arrays, finds and imports the pool under /mnt (widening the device search until
the pool shows up), mounts a boot environment, its datasets and the ESP, runs zbm_setup.py --mdraid inside the
installed system (mdadm.conf, dracut config, assemble hook, rd.auto=1, initramfs, ZFSBootMenu image, firmware
entry) and unmounts and exports the pool.

Guided (asks questions, takes no options but --help):
  sudo python3 mdraid_rescue.py

The pool is mounted at /mnt. The installed system needs network access for apt only when mdadm is missing.
"""

import argparse
import glob
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import devices as dv  # noqa: E402
import dzlib as dz  # noqa: E402
import system  # noqa: E402
import target  # noqa: E402
import zfsops  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

ROOT = zfsops.MOUNT_POINT
ESP_MOUNT = ROOT + "/boot/efi"
IMPORT_KEYS = ("pool", "id", "state", "action")


def parse_zpool_import(text):
    """`zpool import` (list mode) -> [{"name", "id", "state", "action", "force"}]. force: the action line says -f."""
    pools, cur, last = [], None, None
    for line in text.splitlines():
        m = re.match(r"^\s*(pool|id|state|action|config|status|see):\s*(.*)$", line)
        if m:
            key, value = m.group(1), m.group(2).strip()
            if key == "pool":
                cur = {"name": value, "id": "", "state": "", "action": "", "force": False}
                pools.append(cur)
                last = None
            elif cur is not None and key in IMPORT_KEYS:
                cur[key], last = value, key
            else:
                last = None                      # config:/status:/see: end the action text
        elif cur is not None and last == "action" and line.strip():
            cur["action"] += " " + line.strip()
    for pool in pools:
        pool["force"] = "-f" in pool["action"]
    return pools


def parse_label_pool(text):
    """`zdb -l DEV` -> pool name of the first label, or ''."""
    m = re.search(r"^\s*name:\s*'([^']+)'", text, flags=re.M)
    return m.group(1) if m else ""


def keys_locked(text):
    """`zfs get -H -r -o name,value keystatus POOL` -> True when some dataset still needs its key."""
    return any(line.split("\t")[-1].strip() == "unavailable" for line in text.splitlines())


def parse_datasets(text):
    """`zfs list -H -o name,mountpoint,canmount` -> [(name, mountpoint, canmount)]."""
    rows = []
    for line in text.splitlines():
        fields = [f.strip() for f in line.split("\t")]
        if len(fields) >= 3 and fields[0]:
            rows.append((fields[0], fields[1], fields[2]))
    return rows


def boot_environments(text, root=ROOT):
    """Datasets that mount on / . Under an altroot ZFS shows that root (/mnt) instead of /."""
    return [name for name, mountpoint, _ in parse_datasets(text) if mountpoint in ("/", root)]


def data_datasets(text, env):
    """Datasets that mount by themselves (home, var-log), shortest mountpoint first. The other boot environments
    under <pool>/ROOT are left alone: two of them would both claim /."""
    boot_root = env.split("/")[0] + "/ROOT/"
    rows = [(name, mp) for name, mp, canmount in parse_datasets(text)
            if name != env and not name.startswith(boot_root) and canmount == "on" and mp.startswith("/")]
    return [name for name, _ in sorted(rows, key=lambda row: (len(row[1]), row[1]))]


def md_volumes():
    """md devices that are volumes (not imsm containers), e.g. ['/dev/md126']."""
    found = []
    for path in sorted(glob.glob(os.path.join(dv.SYSFS, "block", "md*"))):
        name = os.path.basename(path)
        if name[2:].isdigit() and dv.md_level("/dev/" + name) not in ("", "container"):
            found.append("/dev/" + name)
    return found


def md_partitions(volumes):
    found = []
    for vol in volumes:
        found.extend(sorted(glob.glob(vol + "p[0-9]*")))
    return found


def pick(title, labels):
    idx = dz.choose(title, labels)
    if idx is None:
        die("Cancelled")
    return idx


def assemble():
    step("Assembling md arrays")
    if not dz.have("mdadm"):
        die("mdadm is not installed on this live system (apt install mdadm)")
    for module in ("vmd", "md_mod"):
        dz.run(["modprobe", "-q", module], check=False)
    dz.run(["mdadm", "--assemble", "--scan"], check=False)
    dz.run(["udevadm", "settle", "--timeout=20"], check=False)
    print(dv._read("/proc/mdstat") or "(no /proc/mdstat)")
    volumes = md_volumes()
    if not volumes:
        warn("No md volume is assembled")
        if not dz.confirm("Continue without an md volume (plain disks)?"):
            die("No md volume. Check cat /proc/mdstat and mdadm --examine --scan")
        return volumes
    for vol in volumes:
        state = dv.md_state(vol)
        info("%s: level %s, state %s" % (vol, dv.md_level(vol), state or "?"))
        if state == "inactive":
            dz.run(["mdadm", "--run", vol], check=False)
        elif state == "readonly":
            dz.run(["mdadm", "--readwrite", vol], check=False)
        # The kernel reads the partition table only when asked: without md126p1/p2 no pool can be found.
        if dz.have("partprobe"):
            dz.run(["partprobe", vol], check=False)
        else:
            dz.run(["blockdev", "--rereadpt", vol], check=False)
    dz.run(["udevadm", "settle", "--timeout=20"], check=False)
    info("Partitions on the md volumes: %s" % (" ".join(md_partitions(volumes)) or "none"))
    return volumes


def find_pools(volumes):
    """Widen the device search until a pool shows up. zpool import scans with libblkid by default; -d scans
    the device nodes directly, which finds partitions that libblkid does not know yet."""
    step("Looking for ZFS pools")
    parts = md_partitions(volumes)
    searches = [([], "default scan"), (["-d", "/dev"], "-d /dev"),
                (["-d", "/dev/disk/by-id"], "-d /dev/disk/by-id")]
    if parts:
        searches.append((sum([["-d", p] for p in parts], []), "-d " + " -d ".join(parts)))
    for args, label in searches:
        pools = parse_zpool_import(dz.out(["zpool", "import"] + args))
        if pools:
            info("Found with: %s" % label)
            return args, pools
        warn("Nothing found with: %s" % label)
    for part in parts:
        pool = parse_label_pool(dz.out(["zdb", "-l", part]))
        if pool:
            warn("%s has a ZFS label for pool '%s', but zpool import does not list it" % (part, pool))
    if parse_zpool_import(dz.out(["zpool", "import", "-D"])):
        warn("A destroyed pool exists (zpool import -D); this tool does not import destroyed pools")
    return [], []


def pick_pool(volumes):
    while True:
        args, pools = find_pools(volumes)
        if pools:
            break
        if not dz.confirm("No pool found. Rescan?"):
            die("No pool found. Check lsblk -f, cat /proc/mdstat and zdb -l /dev/md126p2")
        volumes = assemble()
    labels = ["%s  id %s  state %s%s" % (p["name"], p["id"], p["state"], "  (needs -f)" if p["force"] else "")
              for p in pools]
    pool = pools[pick("Import which pool?", labels) if len(pools) > 1 else 0]
    if pool["state"] not in ("ONLINE", "DEGRADED"):
        die("Pool %s is %s: %s" % (pool["name"], pool["state"], pool["action"] or "see zpool import"))
    return args, pool


def import_pool(args, pool):
    step("Importing pool %s under %s" % (pool["name"], ROOT))
    name = pool["name"]
    if name in dz.out(["zpool", "list", "-H", "-o", "name"]).split():
        if not dz.confirm("%s is already imported. Export it and import it again under %s?" % (name, ROOT)):
            die("Pool already imported")
        dz.run(["zpool", "export", name])
    cmd = ["zpool", "import"] + args + ["-N", "-R", ROOT]
    if pool["force"]:
        if not dz.confirm("The pool looks active on another system (last used elsewhere). Import with -f?"):
            die("Import cancelled")
        cmd.append("-f")
    dz.run(cmd + [pool["id"] or name])
    # The pool root may be unencrypted while a child is the encryption root, so look at every dataset.
    if keys_locked(dz.out(["zfs", "get", "-H", "-r", "-o", "name,value", "keystatus", name])):
        info("Encrypted datasets: the key is needed")
        dz.run(["zfs", "load-key", "-r", "-L", "prompt", name])
    return name


def mount_system(name):
    """Mount a boot environment, its data datasets and the ESP. Returns (boot environment, ESP device)."""
    step("Mounting datasets under %s" % ROOT)
    listing = dz.out(["zfs", "list", "-H", "-t", "filesystem", "-o", "name,mountpoint,canmount", "-r", name])
    envs = boot_environments(listing)
    if not envs:
        die("No dataset with mountpoint=/ in %s" % name)
    env = envs[pick("Boot environment to repair:", envs) if len(envs) > 1 else 0]
    dz.run(["zfs", "mount", "-O", env])
    others = data_datasets(listing, env)
    if others and dz.confirm("Also mount %s?" % ", ".join(others)):
        for dataset in others:
            dz.run(["zfs", "mount", dataset], check=False)

    candidates = sorted(target.esp_candidates(dv.lsblk_devices()),
                        key=lambda d: (not d["path"].startswith("/dev/md"), d["path"]))
    paths = [d["path"] for d in candidates]
    if dz.ok(["mountpoint", "-q", ESP_MOUNT]):
        info("ESP already mounted at %s" % ESP_MOUNT)
        source = dz.out(["findmnt", "-n", "-o", "SOURCE", ESP_MOUNT])
        return env, source or (paths[0] if paths else "")
    if not paths:
        die("No EFI system partition found (vfat with the ESP type). Mount it at %s and run again." % ESP_MOUNT)
    dev = paths[pick("EFI system partition to mount at %s:" % ESP_MOUNT, [dz.describe(d) for d in candidates])
                if len(paths) > 1 else 0]
    dz.run(["mkdir", "-p", ESP_MOUNT])
    dz.run(["mount", dev, ESP_MOUNT])
    info("Mounted %s at %s" % (dev, ESP_MOUNT))
    return env, dev


def repair(name, env, esp):
    step("Repairing md RAID support in the installed system")
    system.mount_virtual_filesystems()
    system.run_zbm_setup(["--yes", "--update", "--mdraid", "--pool", name,
                          "--dataset", env[len(name) + 1:], "--boot-device", esp])


def main():
    argparse.ArgumentParser(prog="mdraid_rescue.py", description=__doc__.split("\n\n")[0],
                            epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                            formatter_class=argparse.RawDescriptionHelpFormatter).parse_args()
    dz.require_root()
    volumes = assemble()
    args, pool = pick_pool(volumes)
    name = import_pool(args, pool)
    try:
        env, esp = mount_system(name)
        repair(name, env, esp)
    except (dz.Fatal, KeyboardInterrupt):
        warn("Stopped. The system may still be mounted at %s; unmount it with: umount -R %s && zpool export %s"
             % (ROOT, ROOT, name))
        raise
    if dz.confirm("Unmount %s and export %s now?" % (ROOT, name)):
        system.teardown(name)
    info("Reboot and choose 'ZFSBootMenu' in the UEFI boot menu.")


if __name__ == "__main__":
    dz.run_main(main)
