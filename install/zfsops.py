"""zfsops: create, import, mount and prepare ZFS pools and boot environments."""

import os

import devices as dv
import dzlib as dz
from dzlib import die, info, step, warn

MOUNT_POINT = "/mnt"


def ensure_hostid():
    if not os.path.exists("/etc/hostid"):
        info("Generating /etc/hostid")
        dz.run(["zgenhostid"])


def create_pool(plan):
    step("Creating ZFS pool %s" % plan.pool_name)
    vdev = plan.pool_device if dz.DRY_RUN else dv.stable_device_path(plan.pool_device)
    info("Pool vdev: %s" % vdev)
    cmd = ["zpool", "create", "-f",
           "-o", "ashift=12", "-o", "autotrim=on", "-o", "compatibility=openzfs-2.2-linux",
           "-O", "compression=lz4", "-O", "acltype=posixacl", "-O", "xattr=sa",
           "-O", "relatime=on", "-O", "dnodesize=auto", "-O", "normalization=formD",
           "-m", "none"]
    if plan.encrypt:
        if not plan.passphrase:
            plan.passphrase = dz.ask_passphrase()
        if len(plan.passphrase) < 8:
            die("ZFS requires a passphrase of at least 8 characters")
        dz.write_file(plan.key_file, plan.passphrase + "\n", mode=0o000)
        cmd += ["-O", "encryption=aes-256-gcm", "-O", "keyformat=passphrase",
                "-O", "keylocation=file://%s" % plan.key_file]
    dz.run(cmd + [plan.pool_name, vdev])
    dz.run(["zpool", "status", plan.pool_name], check=False)


def create_datasets(plan):
    step("Creating datasets")
    p = plan.pool_name
    dz.run(["zfs", "create", "-o", "mountpoint=none", "%s/ROOT" % p])
    dz.run(["zfs", "create", "-o", "mountpoint=/", "-o", "canmount=noauto", plan.root_ds])
    dz.run(["zfs", "create", "-o", "mountpoint=/home", "%s/home" % p])
    dz.run(["zfs", "create", "-o", "mountpoint=/var/log", "%s/var-log" % p])
    set_boot_properties(plan)


def set_boot_properties(plan):
    dz.run(["zpool", "set", "bootfs=%s" % plan.root_ds, plan.pool_name])
    dz.run(["zfs", "set", "org.zfsbootmenu:commandline=quiet loglevel=0", plan.root_ds])
    if plan.encrypt:
        dz.run(["zfs", "set", "org.zfsbootmenu:keysource=%s" % plan.root_ds, plan.pool_name])


def import_pool(plan):
    step("Importing %s at %s" % (plan.pool_name, MOUNT_POINT))
    imported = dz.ok(["zpool", "list", plan.pool_name])
    if imported:
        dz.run(["zpool", "export", plan.pool_name])
    dz.run(["zpool", "import", "-N", "-R", MOUNT_POINT, plan.pool_name])
    dz.run(["zpool", "set", "cachefile=/etc/zfs/zpool.cache", plan.pool_name])


def load_key(plan):
    if dz.DRY_RUN:
        if plan.encrypt:
            dz.run(["zfs", "load-key", "-L", "file://%s" % plan.key_file, plan.root_ds])
        return
    status = dz.out(["zfs", "get", "-H", "-o", "value", "keystatus", plan.root_ds])
    if status != "unavailable":
        return
    plan.encrypt = True
    if os.path.exists(plan.key_file):
        dz.run(["zfs", "load-key", "-L", "file://%s" % plan.key_file, plan.root_ds])
    else:
        info("Enter the passphrase for %s" % plan.root_ds)
        dz.run(["zfs", "load-key", "-L", "prompt", plan.root_ds])


def mount_datasets(plan):
    step("Mounting datasets")
    load_key(plan)
    dz.run(["zfs", "mount", plan.root_ds])
    for ds in ("%s/home" % plan.pool_name, "%s/var-log" % plan.pool_name):
        if dz.DRY_RUN or dz.ok(["zfs", "list", ds]):
            dz.run(["zfs", "mount", ds], check=False)
    dz.run(["findmnt", "-R", MOUNT_POINT], check=False)


def prepare_existing_pool(plan):
    step("Using existing pool %s" % plan.pool_name)
    import_pool(plan)
    root = "%s/ROOT" % plan.pool_name
    envs = [l for l in dz.out(["zfs", "list", "-H", "-o", "name", "-r", "-d", "1", root]).splitlines()
            if l and l != root]
    if not dz.DRY_RUN and not dz.ok(["zfs", "list", root]):
        dz.run(["zfs", "create", "-o", "mountpoint=none", root])

    labels = [e for e in envs] + ["Create new boot environment %s/ROOT/<name>" % plan.pool_name]
    if dz.ASSUME_YES or dz.DRY_RUN:
        idx = len(envs)
    else:
        idx = dz.choose("Boot environment to install into:", labels)
        if idx is None:
            die("Cancelled")
    if idx == len(envs):
        if not dz.ASSUME_YES and not dz.DRY_RUN:
            plan.be_name = dz.ask("New boot environment name", plan.be_name)
        if plan.root_ds in envs:
            die("%s already exists" % plan.root_ds)
        dz.run(["zfs", "create", "-o", "mountpoint=/", "-o", "canmount=noauto", plan.root_ds])
    else:
        plan.be_name = envs[idx].split("/")[-1]
        warn("debootstrap will write into the existing dataset %s" % plan.root_ds)
        if not dz.confirm("Continue with %s?" % plan.root_ds):
            die("Cancelled")
    set_boot_properties(plan)
