"""system: debootstrap, chroot setup and configuration of the new Debian system."""

import glob
import os
import re
import shutil

import devices as dv
import dzlib as dz
import zfsops
from dzlib import die, info, step, warn

MOUNT_POINT = zfsops.MOUNT_POINT
APT_ENV = {"DEBIAN_FRONTEND": "noninteractive"}
SRC_DIR = os.path.dirname(os.path.abspath(__file__))
KERNEL_GUARD = os.path.join(SRC_DIR, "zfs_kernel_guard.py")


def install_debian(plan):
    step("Installing Debian %s with debootstrap" % plan.codename)
    if plan.release == "sid":
        warn("sid is the unstable branch: packages change daily and can break")
    dz.run(["debootstrap", "--components=main,contrib,non-free-firmware",
            plan.codename, MOUNT_POINT, dz.MIRROR])


def prepare_chroot(plan):
    step("Preparing chroot")
    target = MOUNT_POINT
    zfsops.ensure_hostid()
    for src in ("/etc/hostid", "/etc/zfs/zpool.cache"):
        if os.path.exists(src) or dz.DRY_RUN:
            dz.run(["mkdir", "-p", os.path.dirname(target + src)])
            dz.run(["cp", "-L", src, target + src], check=False)
    dz.run(["cp", "-L", "/etc/resolv.conf", target + "/etc/resolv.conf"], check=False)
    if plan.encrypt and (os.path.exists(plan.key_file) or dz.DRY_RUN):
        dz.run(["cp", plan.key_file, target + plan.key_file])
        dz.run(["chmod", "000", target + plan.key_file])
    mount_virtual_filesystems()


def mount_virtual_filesystems():
    dz.run(["mount", "-t", "proc", "proc", MOUNT_POINT + "/proc"])
    for fs in ("/sys", "/dev"):
        dz.run(["mount", "--rbind", fs, MOUNT_POINT + fs])
        dz.run(["mount", "--make-rslave", MOUNT_POINT + fs])


ZBM_STAGE_FILES = ("zbm_setup.py", "devices.py", "dzlib.py")
ZBM_STAGE = "/tmp/zbm-setup"


def run_zbm_setup(argv, ssh_key=""):
    """Run zbm_setup.py inside the new system. The stage directory stays after a failure for a retry."""
    stage = MOUNT_POINT + ZBM_STAGE
    if not dz.DRY_RUN:
        os.makedirs(stage + "/install", exist_ok=True)
        for name in ZBM_STAGE_FILES:
            shutil.copy(os.path.join(SRC_DIR, name), os.path.join(stage, "install", name))
        cfg = dz.find_zbm_config_dir(SRC_DIR)
        if cfg:
            shutil.copytree(cfg, stage + "/config/zfsbootmenu", dirs_exist_ok=True)
    args = ["python3", ZBM_STAGE + "/install/zbm_setup.py"] + list(argv)
    if ssh_key:
        if not dz.DRY_RUN:
            shutil.copy(os.path.expanduser(ssh_key), stage + "/authorized_keys")
        args += ["--ssh-key", ZBM_STAGE + "/authorized_keys"]
    if dz.run(args, chroot=MOUNT_POINT, check=False).returncode != 0:
        die("ZFSBootMenu setup failed. The system is still mounted at %s; retry with:\n"
            "        chroot %s %s" % (MOUNT_POINT, MOUNT_POINT, " ".join(args)))
    dz.run(["rm", "-rf", stage])


def teardown(pool):
    if dz.run(["umount", "-R", MOUNT_POINT], check=False).returncode != 0:
        warn("Some mounts were busy — retrying with a lazy unmount")
        dz.run(["umount", "-lR", MOUNT_POINT], check=False)
    if dz.run(["zpool", "export", pool], check=False).returncode != 0:
        warn("Could not export %s — run 'zpool export %s' before rebooting" % (pool, pool))


def chroot_apt(args, check=True):
    return dz.run(["apt-get"] + args, chroot=MOUNT_POINT, env=APT_ENV, check=check)


def configure_system(plan):
    step("Configuring the new system")
    t = MOUNT_POINT

    dz.write_file(t + "/etc/hostname", plan.hostname + "\n")
    dz.write_file(t + "/etc/hosts",
                  "127.0.0.1\tlocalhost\n127.0.1.1\t%s\n\n"
                  "::1\tlocalhost ip6-localhost ip6-loopback\n"
                  "ff02::1\tip6-allnodes\nff02::2\tip6-allrouters\n" % plan.hostname)
    # deb822 sources (default format since Debian 13)
    dz.write_file(t + "/etc/apt/sources.list.d/debian.sources", dz.deb822_sources(plan.release))
    dz.write_file(t + "/etc/apt/sources.list",
                  "# Package sources are in /etc/apt/sources.list.d/debian.sources\n")

    chroot_apt(["update"])
    chroot_apt(["install", "-y", "locales", "keyboard-configuration", "console-setup", "tzdata"])
    locale_gen = t + "/etc/locale.gen"
    if os.path.exists(locale_gen) and not dz.DRY_RUN:
        with open(locale_gen) as fh:
            text = fh.read()
        text = re.sub(r"^#\s*(en_US\.UTF-8 UTF-8)", r"\1", text, flags=re.M)
        dz.write_file(locale_gen, text)
    dz.run(["locale-gen"], chroot=t)
    dz.run(["update-locale", "LANG=en_US.UTF-8"], chroot=t)

    step("Installing kernel and ZFS (%s)" % plan.codename)
    chroot_apt(["install", "-y", "linux-headers-amd64", "linux-image-amd64",
                "zfs-initramfs", "zfs-dkms", "zfsutils-linux"])
    check_zfs_module(plan)

    pkgs = ["dosfstools", "efibootmgr", "openssh-server", "sudo", "curl", "systemd-zram-generator",
            "cpio", "kexec-tools", "python3"]
    if plan.is_md:
        pkgs.append("mdadm")
    # Networking for the installed system: NetworkManager (nmtui) handles
    # Ethernet and Wi-Fi; wl = proprietary driver for Broadcom (MacBook) Wi-Fi
    pkgs += ["network-manager"]
    has_wifi = (plan.macbook and bool(plan.wl_devices)) or bool(glob.glob(dv.SYSFS + "/class/net/*/wireless"))
    if has_wifi:
        pkgs += ["wpasupplicant", "iw", "wireless-regdb"]
    chroot_apt(["install", "-y"] + pkgs)
    if plan.macbook:
        if plan.wl_devices:
            install_broadcom_wifi(plan)
        else:
            info("No Broadcom Wi-Fi chip found — skipping the wl driver")
    copy_network_connections()

    dz.write_file(t + "/etc/dkms/zfs.conf", "REMAKE_INITRD=yes\n")

    if plan.is_md:
        info("Writing mdadm.conf and RAID initramfs modules (Intel RST)")
        conf = dz.out(["chroot", t, "/usr/share/mdadm/mkconf"]) if not dz.DRY_RUN else ""
        if not conf:
            conf = "HOMEHOST <system>\nMAILADDR root\nDEVICE partitions containers\n" + \
                dz.out(["mdadm", "--detail", "--scan"])
        dz.write_file(t + "/etc/mdadm/mdadm.conf", conf.rstrip("\n") + "\n")
        for mod in dz.MD_MODULES:
            dz.append_line(t + "/etc/initramfs-tools/modules", mod)

    if plan.kernel_guard:
        install_kernel_guard()

    for unit in ("zfs.target", "zfs-import-cache.service", "zfs-mount.service", "zfs-import.target"):
        dz.run(["systemctl", "enable", unit], chroot=t, check=False)

    if plan.encrypt:
        dz.write_file(t + "/etc/initramfs-tools/conf.d/umask.conf", "UMASK=0077\n")

    dz.run(["update-initramfs", "-u", "-k", "all"], chroot=t)
    if not dz.DRY_RUN:
        kernels = glob.glob(t + "/boot/vmlinuz-*")
        initrds = glob.glob(t + "/boot/initrd.img-*")
        if not kernels or not initrds:
            die("No kernel/initramfs in %s/boot — check the apt output above" % t)
        info("Kernels: %s" % ", ".join(os.path.basename(k) for k in kernels))

    if plan.password:
        dz.run(["chpasswd"], chroot=t, input="root:%s\n" % plan.password)
    else:
        info("Set the root password for the new system")
        if dz.DRY_RUN:
            dz.run(["passwd", "root"], chroot=t)
        else:
            while dz.run(["passwd", "root"], chroot=t, check=False).returncode != 0:
                warn("Try again")


def install_kernel_guard():
    """Kernel-update protection for OpenZFS (see install/zfs_kernel_guard.py)."""
    step("Installing zfs-kernel-guard (protects against kernel updates that break ZFS)")
    src = KERNEL_GUARD
    if not dz.DRY_RUN:
        shutil.copy(src, MOUNT_POINT + "/tmp/zfs_kernel_guard.py")
    dz.run(["python3", "/tmp/zfs_kernel_guard.py", "install"], chroot=MOUNT_POINT, check=False)
    dz.run(["rm", "-f", MOUNT_POINT + "/tmp/zfs_kernel_guard.py"], check=False)


def install_broadcom_wifi(plan):
    step("Installing Broadcom Wi-Fi driver (wl) for %s" % ", ".join(plan.wl_devices))
    info("MacBook BCM4331/BCM4360-class Wi-Fi needs broadcom-sta-dkms from 'non-free'")
    if chroot_apt(["install", "-y", "broadcom-sta-dkms"], check=False).returncode != 0:
        warn("broadcom-sta-dkms failed to install — Wi-Fi will not work until it is fixed")
        return
    if not dz.DRY_RUN and not glob.glob(MOUNT_POINT + "/lib/modules/*/**/wl.ko*", recursive=True):
        warn("wl.ko was not built by DKMS (kernel too new for broadcom-sta?) — check: dkms status")
    else:
        info("wl driver installed ✓ (b43/bcma/brcmsmac are blacklisted by the package)")


def copy_network_connections():
    """Carry the live system's NetworkManager connections (e.g. Wi-Fi) over."""
    src = "/etc/NetworkManager/system-connections"
    files = glob.glob(src + "/*") if os.path.isdir(src) else []
    if not files:
        return
    info("Copying %d NetworkManager connection(s) from the live system" % len(files))
    dst = MOUNT_POINT + src
    dz.run(["mkdir", "-p", dst])
    for f in files:
        dz.run(["cp", "-p", f, dst + "/"])
    dz.run(["sh", "-c", "chmod 600 %s/*" % dst])


def check_zfs_module(plan):
    """Every installed kernel needs a DKMS-built zfs.ko, or the system cannot boot."""
    if dz.DRY_RUN:
        return
    t = MOUNT_POINT
    missing = []
    for vmlinuz in glob.glob(t + "/boot/vmlinuz-*"):
        ver = os.path.basename(vmlinuz)[len("vmlinuz-"):]
        if not glob.glob(t + "/lib/modules/%s/**/zfs.ko*" % ver, recursive=True):
            missing.append(ver)
    if missing:
        hint = ("sid's kernel is probably newer than its ZFS supports — use --release stable,\n"
                "        or install an older linux-image in the chroot and remove the new one"
                if plan.release == "sid" else
                "check the DKMS output above (chroot %s dkms status)" % t)
        die("ZFS module was not built for kernel(s) %s\n        %s" % (", ".join(missing), hint))
    info("zfs.ko built for all kernels ✓")


def setup_esp(plan):
    step("Mounting EFI System Partition")
    uuid = "0000-0000" if dz.DRY_RUN else dz.out(["blkid", "-s", "UUID", "-o", "value", plan.boot_device])
    if not uuid:
        die("Could not read the UUID of %s" % plan.boot_device)
    dz.write_file(MOUNT_POINT + "/etc/fstab",
                  "# EFI System Partition\nUUID=%s  /boot/efi  vfat  defaults,umask=0077  0  1\n" % uuid)
    dz.run(["mkdir", "-p", MOUNT_POINT + "/boot/efi"])
    dz.run(["mount", "-t", "vfat", plan.boot_device, MOUNT_POINT + "/boot/efi"])
