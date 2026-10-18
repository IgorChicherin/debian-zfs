#!/usr/bin/env python3
"""zbm_setup.py — install ZFSBootMenu on an installed ZFS-root system.

Run it on the installed system or inside its chroot (debian_zfs_install.py does this).

Without RAID the official prebuilt EFI image is downloaded. When the pool or
the ESP is on an md device (Intel RST RAID 0 etc.) — or with --mdraid — a
local image is built with generate-zbm that can assemble the array:
  * dracut 'mdraid' module + /etc/mdadm/mdadm.conf, drivers vmd md_mod raid0
  * rd.auto=1 on the ZBM command line (dracut skips md assembly without it)
  * early-setup hook running 'mdadm --assemble --scan' before pool import
  * Debian initramfs updated so the booted kernel assembles the array too

--macbook (for Apple MacBooks, e.g. A1398 MacBook Pro Retina 2012-2015) builds
a local image that loads the USB/HID drivers of the built-in keyboard and
trackpad early (xhci/ehci, usbhid, hid_apple, bcm5974, applespi) — the
prebuilt image may lack them — and installs the \EFI\BOOT\BOOTX64.EFI
fallback that Apple firmware boots ("EFI Boot" in the Option-key picker).
The choice is remembered: later runs keep it until --no-macbook.

--network adds wired networking + SSH to the boot menu: DHCP on any wired
adapter (Thunderbolt/USB Ethernet, USB phone tethering) and a dropbear SSH
server (port 222, key login only). Connect with  ssh -p 222 root@<ip>  and
run 'zfsbootmenu'. Wi-Fi is not available inside ZFSBootMenu.

Examples:
  zbm_setup.py                       # auto-detect everything
  zbm_setup.py --mdraid              # force the RAID-capable build
  zbm_setup.py --macbook             # MacBook keyboard drivers
  zbm_setup.py --network --ssh-key ~/.ssh/id_ed25519.pub
  zbm_setup.py --update              # rebuild / refresh the image
"""

import argparse
import glob
import os
import re
import shutil
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

import devices as dv  # noqa: E402
import dzlib as dz  # noqa: E402
from dzlib import die, info, step, warn  # noqa: E402

ESP_MOUNT = "/boot/efi"
ZBM_DIR = ESP_MOUNT + "/EFI/ZBM"
CONF_DIR = "/etc/zfsbootmenu"
DRACUT_DIR = CONF_DIR + "/dracut.conf.d"
HOOK_DIR = CONF_DIR + "/hooks"
PRE_DIR = CONF_DIR + "/generate-zbm.pre.d"
POST_DIR = CONF_DIR + "/generate-zbm.post.d"
SRC_DIR = "/usr/local/src/zfsbootmenu"
FALLBACK_DIR = ESP_MOUNT + "/EFI/BOOT"

# Firmware paths; FAT is case-insensitive so these match vmlinuz.EFI /
# vmlinuz-backup.EFI written by generate-zbm
LOADER = r"\EFI\ZBM\VMLINUZ.EFI"
BACKUP_LOADER = r"\EFI\ZBM\VMLINUZ-BACKUP.EFI"
IMAGE = ZBM_DIR + "/VMLINUZ.EFI"
BACKUP_IMAGE = ZBM_DIR + "/VMLINUZ-BACKUP.EFI"

APT_ENV = {"DEBIAN_FRONTEND": "noninteractive"}

MDRAID_DRACUT_CONF = """\
# Intel RST (imsm) / mdadm RAID support for ZFSBootMenu
add_dracutmodules+=" mdraid "
mdadmconf="yes"
force_drivers+=" vmd md_mod raid0 "
add_drivers+=" nvme ahci raid1 raid10 "
zfsbootmenu_hook_root="/etc/zfsbootmenu/hooks"
"""

BASE_DRACUT_CONF = """\
nofsck="yes"
add_dracutmodules+=" zfsbootmenu "
omit_dracutmodules+=" btrfs zfs resume systemd systemd-networkd dracut-systemd plymouth "
"""

ASSEMBLE_HOOK = """\
#!/bin/sh
# ZFSBootMenu early-setup hook: assemble Intel RST / mdadm arrays before
# ZFSBootMenu scans for pools. (ZBM's initramfs has no Python — keep this sh.)
command -v mdadm >/dev/null 2>&1 || exit 0
for mod in vmd md_mod raid0 raid1 raid10; do
    modprobe -q "$mod" 2>/dev/null || true
done
command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=20
mdadm --assemble --scan >/dev/null 2>&1 || true
mdadm --incremental --run --scan >/dev/null 2>&1 || true
if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=block --action=change
    udevadm settle --timeout=20
fi
exit 0
"""

BUILD_DEPS = ["libsort-versions-perl", "libboolean-perl", "libyaml-pp-perl", "git", "fzf", "make",
              "curl", "mbuffer", "kexec-tools", "dracut-core", "efibootmgr", "systemd-boot-efi",
              "bsdextrautils", "binutils"]
NETWORK_DEPS = ["dropbear-bin", "busybox"]

# Built-in keyboard/trackpad of Intel MacBooks: USB topcase (2008-2015 MacBook
# Pro incl. A1398) or SPI topcase (12" MacBook, MBP 2015 13"/2016+).
APPLE_FORCE = ["xhci_pci", "xhci_hcd", "ehci_pci", "ehci_hcd", "usbhid", "hid_generic", "hid_apple"]
APPLE_ADD = ["ohci_pci", "uhci_hcd", "bcm5974", "applesmc", "applespi", "intel_lpss_pci",
             "spi_pxa2xx_pci", "spi_pxa2xx_platform", "spi_pxa2xx_core", "thunderbolt"]
# Wired NICs for ZBM networking: Apple Thunderbolt Ethernet (tg3), common USB
# Ethernet adapters, phone USB tethering, typical onboard NICs
NET_DRIVERS = ["tg3", "thunderbolt", "r8152", "ax88179_178a", "asix", "cdc_ether", "cdc_ncm",
               "cdc_mbim", "rndis_host", "ipheth", "usbnet", "r8169", "e1000e", "igb", "igc",
               "atlantic", "bnx2", "bnxt_en"]
ZBM_SSH_DIR = CONF_DIR + "/dropbear"
DEFAULT_SSH_PORT = 222


class Ctx(object):
    pass


###############################################################################
# Detection
###############################################################################

def resolve_boot_device(c):
    if not c.boot_device and dz.ok(["mountpoint", "-q", ESP_MOUNT]):
        c.boot_device = dz.out(["findmnt", "-n", "-o", "SOURCE", ESP_MOUNT])
    if not c.boot_device and os.path.exists("/etc/fstab"):
        with open("/etc/fstab") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[1] == "/boot/efi" and not parts[0].startswith("#"):
                    spec = parts[0]
                    if spec.startswith("UUID="):
                        c.boot_device = dz.out(["blkid", "-U", spec[5:]])
                    elif spec.startswith("PARTUUID="):
                        c.boot_device = dz.out(["blkid", "-t", spec, "-o", "device"]).split("\n")[0]
                    else:
                        c.boot_device = spec
                    break
    if not c.boot_device or not os.path.exists(c.boot_device):
        dz.run(["lsblk", "-o", "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT"], check=False, always=True)
        die("Could not determine the EFI System Partition%s — pass --boot-device"
            % (" (%s)" % c.boot_device if c.boot_device else ""))
    c.boot_device = os.path.realpath(c.boot_device)
    c.boot_disk = c.boot_disk or "/dev/" + dv.parent_kname(c.boot_device)
    c.boot_part = c.boot_part or dv.part_number(c.boot_device)
    if not c.boot_part:
        die("%s is not a partition — pass --boot-disk and --boot-part" % c.boot_device)


def pool_md_vdevs(pool):
    vdevs = []
    for line in dz.out(["zpool", "status", "-P", "-L", pool]).splitlines():
        word = line.strip().split(" ")[0] if line.strip() else ""
        if word.startswith("/dev/md"):
            vdevs.append(word)
    return vdevs


def resolve_mdraid(c):
    if c.mdraid is not None:
        return
    c.mdraid = False
    if dv.is_md(c.boot_device):
        info("ESP %s is on an md RAID device" % c.boot_device)
        c.mdraid = True
    vdevs = pool_md_vdevs(c.pool)
    if vdevs:
        info("Pool %s uses md RAID vdev(s): %s" % (c.pool, " ".join(vdevs)))
        c.mdraid = True
    if c.mdraid:
        warn("Intel RST / mdadm RAID detected — enabling mdraid mode automatically")
        warn("(the prebuilt ZFSBootMenu image cannot assemble md arrays)")


APPLE_CONF = DRACUT_DIR + "/20-apple-input.conf"
NETWORK_CONF = DRACUT_DIR + "/30-network-ssh.conf"


def resolve_apple(c):
    """--macbook / --no-macbook; without either, keep what an earlier run chose."""
    if c.apple is None:
        c.apple = os.path.exists(APPLE_CONF)
        if c.apple:
            info("MacBook drivers were enabled before — keeping them (--no-macbook removes)")
    if not c.apple and dv.dmi("sys_vendor").startswith("Apple"):
        warn("Apple hardware (%s) detected — add --macbook if the built-in keyboard does not"
             " work in ZFSBootMenu" % dv.dmi("product_name"))


def resolve_network(c):
    if c.network is None:
        c.network = os.path.exists(NETWORK_CONF)
        if c.network:
            info("Network + SSH was enabled before — keeping it (--no-network removes)")


def zbm_kernel_version():
    """Kernel generate-zbm will use: the newest /boot/vmlinuz-* with modules."""
    def key(v):
        return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", v)]
    versions = [os.path.basename(k)[len("vmlinuz-"):] for k in glob.glob("/boot/vmlinuz-*")]
    versions = [v for v in versions if os.path.isdir("/lib/modules/" + v)]
    return sorted(versions, key=key)[-1] if versions else os.uname().release


def available_modules(mods, kver):
    """Only modules that exist for kver — dracut fails on unknown add_drivers."""
    found = [m for m in mods if dz.ok(["modinfo", "-k", kver, "-F", "filename", m])]
    missing = [m for m in mods if m not in found]
    if missing:
        info("  not in kernel %s (skipped): %s" % (kver, " ".join(missing)))
    return found


def check_prerequisites(c):
    step("Checking prerequisites")
    missing = [cmd for cmd in ("zfs", "zpool", "blkid", "findmnt", "lsblk", "curl", "efibootmgr")
               if not dz.have(cmd)]
    if missing:
        die("Missing commands: %s\n        apt install -y curl efibootmgr dosfstools util-linux"
            % " ".join(missing))
    if not dz.ok(["zpool", "list", c.pool]):
        die("Pool %s not found (zpool list)" % c.pool)
    if not dz.ok(["zfs", "list", c.root_ds]):
        die("Dataset %s not found (zfs list)" % c.root_ds)
    resolve_boot_device(c)
    resolve_mdraid(c)
    resolve_apple(c)
    resolve_network(c)
    info("Pool: %s ✓   Dataset: %s ✓" % (c.pool, c.root_ds))
    info("ESP: %s (disk %s, partition %s)" % (c.boot_device, c.boot_disk, c.boot_part))
    info("mdraid: %s | MacBook drivers: %s | network+SSH: %s" % (c.mdraid, c.apple, c.network))


###############################################################################
# Setup steps
###############################################################################

def set_dataset_properties(c):
    step("Configuring dataset properties")
    current = dz.out(["zfs", "get", "-H", "-o", "value", "org.zfsbootmenu:commandline", c.root_ds], "-")
    if current in ("-", ""):
        dz.run(["zfs", "set", "org.zfsbootmenu:commandline=quiet loglevel=0", c.root_ds])
    else:
        info("Keeping org.zfsbootmenu:commandline: %s" % current)
    if dz.out(["zfs", "get", "-H", "-o", "value", "encryption", c.root_ds], "off") != "off":
        dz.run(["zfs", "set", "org.zfsbootmenu:keysource=%s" % c.root_ds, c.pool])


def mount_esp(c):
    step("Mounting EFI System Partition")
    if dz.ok(["mountpoint", "-q", ESP_MOUNT]):
        info("ESP already mounted at %s" % ESP_MOUNT)
        return
    fstype = dz.out(["blkid", "-s", "TYPE", "-o", "value", c.boot_device])
    if fstype != "vfat":
        if not c.format_esp:
            die("%s is not FAT (found '%s'). Refusing to format it automatically (it may be\n"
                "        the Windows ESP); pass --format-esp if you really want that." % (c.boot_device, fstype))
        warn("Formatting %s as FAT32 (--format-esp)" % c.boot_device)
        dz.run(["mkfs.vfat", "-F", "32", c.boot_device])
    fstab = open("/etc/fstab").read() if os.path.exists("/etc/fstab") else ""
    if not re.search(r"\s/boot/efi\s", fstab):
        uuid = dz.out(["blkid", "-s", "UUID", "-o", "value", c.boot_device])
        spec = "UUID=%s" % uuid if uuid else c.boot_device
        dz.append_line("/etc/fstab", "%s  /boot/efi  vfat  defaults,umask=0077  0  0" % spec)
    dz.run(["mkdir", "-p", ESP_MOUNT])
    dz.run(["mount", "-t", "vfat", c.boot_device, ESP_MOUNT])


def download_prebuilt(c):
    step("Installing prebuilt ZFSBootMenu")
    dz.run(["mkdir", "-p", ZBM_DIR])
    if os.path.exists(IMAGE):
        info("Keeping the previous image as VMLINUZ-BACKUP.EFI")
        dz.run(["cp", IMAGE, BACKUP_IMAGE])
    tmp = IMAGE + ".new"
    if dz.run(["curl", "-fSL", "--connect-timeout", "10", "-m", "300", "-o", tmp,
               "https://get.zfsbootmenu.org/efi"], check=False).returncode != 0:
        dz.run(["rm", "-f", tmp], check=False)
        die("Download failed — get it from https://github.com/zbm-dev/zfsbootmenu/releases")
    dz.run(["mv", tmp, IMAGE])
    if not os.path.exists(BACKUP_IMAGE):
        dz.run(["cp", IMAGE, BACKUP_IMAGE])
    if not dz.DRY_RUN:
        info("VMLINUZ.EFI: %s" % dz.human_size(os.path.getsize(IMAGE)))


def install_generate_zbm(c):
    step("Installing ZFSBootMenu build tooling (generate-zbm)")
    if dz.have("generate-zbm") and not c.update:
        info("generate-zbm already installed")
        if c.network and not (dz.have("dropbear") or os.path.exists("/usr/sbin/dropbear")):
            dz.run(["apt-get", "install", "-y"] + NETWORK_DEPS, env=APT_ENV)
        return
    dz.run(["apt-get", "install", "-y"] + BUILD_DEPS + (NETWORK_DEPS if c.network else []), env=APT_ENV)
    dz.run(["rm", "-rf", SRC_DIR])
    dz.run(["mkdir", "-p", SRC_DIR])
    info("Downloading ZFSBootMenu source")
    tarball = os.path.join(tempfile.gettempdir(), "zfsbootmenu-src.tar.gz")
    dz.run(["curl", "-fsSL", "-o", tarball, "https://get.zfsbootmenu.org/source"])
    dz.run(["tar", "-zx", "--strip-components=1", "-C", SRC_DIR, "-f", tarball])
    dz.run(["make", "-C", SRC_DIR, "core", "dracut"])
    if not dz.DRY_RUN and not dz.have("generate-zbm"):
        die("generate-zbm was not installed")


def repo_file(*parts):
    base = dz.find_zbm_config_dir(SCRIPT_DIR)
    path = os.path.join(base, *parts) if base else ""
    return path if path and os.path.isfile(path) else None


def install_text(dest, repo_path, fallback, mode=0o644):
    text = fallback
    if repo_path:
        with open(repo_path) as fh:
            text = fh.read().replace("\r\n", "\n")
    dz.write_file(dest, text, mode=mode)


def write_mdadm_conf():
    info("Writing /etc/mdadm/mdadm.conf from the running arrays")
    arrays = dz.out(["mdadm", "--detail", "--scan"])
    if not arrays and not dz.DRY_RUN:
        die("No assembled md arrays. Assemble the RST array first:\n"
            "        mdadm --assemble --scan && cat /proc/mdstat")
    conf_path = "/etc/mdadm/mdadm.conf"
    if os.path.exists(conf_path) and not dz.DRY_RUN:
        shutil.copy(conf_path, conf_path + ".bak")
    conf = dz.out(["/usr/share/mdadm/mkconf"]) if os.access("/usr/share/mdadm/mkconf", os.X_OK) else ""
    if not conf:
        conf = "HOMEHOST <system>\nMAILADDR root\nDEVICE partitions containers\n"
    if "ARRAY" not in conf:
        conf = conf.rstrip("\n") + "\n" + arrays
    dz.write_file(conf_path, conf.rstrip("\n") + "\n")
    for line in conf.splitlines():
        if line.startswith("ARRAY"):
            print("    " + line)


def ensure_base_dracut_conf():
    dz.run(["mkdir", "-p", DRACUT_DIR])
    confs = glob.glob(DRACUT_DIR + "/*.conf")
    if not any("zfsbootmenu" in open(f).read() for f in confs):
        info("Writing base ZFSBootMenu dracut config")
        dz.write_file(DRACUT_DIR + "/zfsbootmenu.conf", BASE_DRACUT_CONF)
    # hooks from /etc/zfsbootmenu/hooks/*.d (mdraid assembly, network/SSH)
    dz.write_file(DRACUT_DIR + "/05-hooks.conf", 'zfsbootmenu_hook_root="%s"\n' % HOOK_DIR)


def setup_apple(c):
    step("Adding MacBook keyboard/trackpad support")
    kver = zbm_kernel_version()
    force = available_modules(APPLE_FORCE, kver)
    add = available_modules(APPLE_ADD, kver)
    dz.write_file(APPLE_CONF,
                  "# Apple MacBook built-in keyboard/trackpad (generated by zbm_setup.py)\n"
                  'force_drivers+=" %s "\nadd_drivers+=" %s "\n' % (" ".join(force), " ".join(add)))


UDHCPC_SCRIPT = """\
#!/bin/sh
# udhcpc event script for the ZFSBootMenu network hook
BB=@BUSYBOX@
case "$1" in
    deconfig)
        $BB ip addr flush dev "$interface"
        $BB ip link set "$interface" up
        ;;
    bound|renew)
        $BB ip addr flush dev "$interface"
        $BB ip addr add "$ip/${mask:-24}" dev "$interface"
        for r in $router; do
            $BB ip route replace default via "$r" dev "$interface"
            break
        done
        if [ -n "$dns" ]; then
            : > /etc/resolv.conf
            for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
        fi
        echo "$interface $ip" >> /run/zbm-network
        echo "<5>zbm-network: $interface $ip — ssh -p @PORT@ root@$ip" > /dev/kmsg 2>/dev/null
        ;;
esac
exit 0
"""

NETWORK_HOOK = """\
#!/bin/sh
# ZFSBootMenu early-setup hook: wired DHCP + dropbear SSH (key login only).
# Generated by zbm_setup.py --network. ZBM has no Python — keep sh.
D=@SSHDIR@
BB=@BUSYBOX@
DROPBEAR=@DROPBEAR@
[ -x "$BB" ] && [ -x "$DROPBEAR" ] || exit 0

for mod in @NETMODS@; do modprobe -q "$mod" 2>/dev/null || true; done

# root login environment for dropbear
mkdir -p /root/.ssh /etc/dropbear
cp "$D/authorized_keys" /root/.ssh/authorized_keys
chmod 700 /root /root/.ssh
chmod 600 /root/.ssh/authorized_keys
if grep -q '^root:' /etc/passwd 2>/dev/null; then
    $BB sed -i 's#^root:.*#root:x:0:0:root:/root:/bin/bash#' /etc/passwd
else
    echo 'root:x:0:0:root:/root:/bin/bash' >> /etc/passwd
fi
printf '/bin/sh\\n/bin/bash\\n' > /etc/shells
cat > /root/.profile << 'EOF'
export TERM=linux
echo
echo "ZFSBootMenu over SSH. Start the menu with:  zfsbootmenu"
echo "(if the local screen holds the menu, press ESC there first)"
EOF

# DHCP on every wired interface, in the background so the menu is not delayed
(
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10
    for dev in /sys/class/net/*; do
        n=${dev##*/}
        [ "$n" = lo ] && continue
        [ -d "$dev/wireless" ] && continue
        $BB ip link set "$n" up
        $BB udhcpc -i "$n" -b -t 10 -T 3 -A 20 -s "$D/udhcpc.script" >/dev/null 2>&1
    done
) &

$DROPBEAR -p @PORT@ -s -j -k -P /run/dropbear.pid \\
    -r "$D/dropbear_ed25519_host_key" -r "$D/dropbear_ecdsa_host_key" -r "$D/dropbear_rsa_host_key"
exit 0
"""


def setup_network(c):
    step("Adding wired network + SSH to ZFSBootMenu")
    busybox = shutil.which("busybox") or "/usr/bin/busybox"
    dropbear = shutil.which("dropbear") or "/usr/sbin/dropbear"
    dropbearkey = shutil.which("dropbearkey") or "/usr/bin/dropbearkey"
    if not dz.DRY_RUN:
        for tool in (busybox, dropbear, dropbearkey):
            if not os.path.exists(tool):
                die("%s missing — apt install dropbear-bin busybox" % tool)
        busybox, dropbear = os.path.realpath(busybox), os.path.realpath(dropbear)

    dz.run(["mkdir", "-p", ZBM_SSH_DIR])
    dz.run(["chmod", "700", ZBM_SSH_DIR])
    auth = ZBM_SSH_DIR + "/authorized_keys"
    if c.ssh_key:
        text = open(os.path.expanduser(c.ssh_key)).read() if not dz.DRY_RUN or os.path.exists(c.ssh_key) else ""
        if not dz.DRY_RUN and "ssh-" not in text and "ecdsa-" not in text:
            die("%s does not look like an SSH public key / authorized_keys file" % c.ssh_key)
        dz.write_file(auth, text, mode=0o600)
    elif not os.path.exists(auth):
        for cand in ("/root/.ssh/authorized_keys",):
            if os.path.exists(cand):
                info("Using %s for ZBM SSH logins" % cand)
                dz.run(["cp", cand, auth])
                break
        else:
            if not dz.DRY_RUN:
                die("--network needs an SSH public key: pass --ssh-key ~/.ssh/id_ed25519.pub "
                    "(password logins are disabled)")

    # Dedicated host keys: they end up inside the EFI image on the (FAT, world
    # readable) ESP, so never reuse the system's /etc/ssh keys
    for kt, extra in (("ed25519", []), ("ecdsa", []), ("rsa", ["-s", "3072"])):
        key = "%s/dropbear_%s_host_key" % (ZBM_SSH_DIR, kt)
        if not os.path.exists(key):
            dz.run([dropbearkey, "-t", kt, "-f", key] + extra, quiet=True)

    port = str(c.ssh_port)
    dz.write_file(ZBM_SSH_DIR + "/udhcpc.script",
                  UDHCPC_SCRIPT.replace("@BUSYBOX@", busybox).replace("@PORT@", port), mode=0o755)
    kver = zbm_kernel_version()
    netmods = available_modules(NET_DRIVERS, kver)
    hook = HOOK_DIR + "/early-setup.d/20-network-ssh.sh"
    dz.write_file(hook, NETWORK_HOOK.replace("@SSHDIR@", ZBM_SSH_DIR).replace("@BUSYBOX@", busybox)
                  .replace("@DROPBEAR@", dropbear).replace("@PORT@", port)
                  .replace("@NETMODS@", " ".join(netmods)), mode=0o755)
    items = [busybox, dropbear, auth, ZBM_SSH_DIR + "/udhcpc.script"] + \
        ["%s/dropbear_%s_host_key" % (ZBM_SSH_DIR, kt) for kt in ("ed25519", "ecdsa", "rsa")]
    dz.write_file(NETWORK_CONF,
                  "# Wired network + dropbear SSH in ZFSBootMenu (generated by zbm_setup.py)\n"
                  'add_drivers+=" %s "\ninstall_items+=" %s "\n' % (" ".join(netmods), " ".join(items)))
    info("SSH: port %s, key login only; host keys in %s" % (port, ZBM_SSH_DIR))


def disable_extra(name, *paths):
    for path in paths:
        if os.path.exists(path):
            info("Removing %s config: %s" % (name, path))
            dz.run(["rm", "-f", path])


def setup_mdraid(c):
    step("Configuring Intel RST / mdadm RAID support")
    if not dz.have("mdadm"):
        dz.run(["apt-get", "install", "-y", "mdadm"], env=APT_ENV)
    write_mdadm_conf()

    install_text(DRACUT_DIR + "/10-mdraid.conf", repo_file("dracut.conf.d", "10-mdraid.conf"),
                 MDRAID_DRACUT_CONF)
    hook = HOOK_DIR + "/early-setup.d/10-mdraid-assemble.sh"
    install_text(hook, repo_file("hooks", "early-setup.d", "10-mdraid-assemble.sh"), ASSEMBLE_HOOK, 0o755)
    info("ZBM early-setup hook: %s" % hook)

    if os.path.isdir("/etc/initramfs-tools"):
        info("Adding %s to /etc/initramfs-tools/modules" % "/".join(dz.MD_MODULES))
        for mod in dz.MD_MODULES:
            dz.append_line("/etc/initramfs-tools/modules", mod)
        # Older versions of this project wrote invalid module names here
        dz.run(["rm", "-f", "/etc/initramfs-tools/modules.d/mdraid"], check=False)
        dz.run(["update-initramfs", "-u", "-k", "all"])


def write_config(c):
    step("Writing ZFSBootMenu configuration")
    path = CONF_DIR + "/config.yaml"
    if os.path.exists(path) and not c.update and not (c.mdraid or c.apple or c.network):
        if not dz.confirm("%s exists. Overwrite?" % path):
            info("Keeping existing configuration")
            return
    for d in (CONF_DIR, PRE_DIR, POST_DIR):
        dz.run(["mkdir", "-p", d])
    if os.path.exists(path):
        dz.run(["cp", path, path + ".bak"])
    # rd.auto=1 is REQUIRED for md: without it (or rd.md.uuid=...) dracut's
    # mdraid module disables RAID assembly and ZBM never sees the pool
    cmdline = "quiet loglevel=4" + (" rd.auto=1" if c.mdraid else "")
    dz.write_file(path, """\
# ZFSBootMenu configuration — generated by zbm_setup.py
Global:
  ManageImages: true
  BootMountPoint: {esp}
  DracutConfDir: {dracut}
  PreHooksDir: {pre}
  PostHooksDir: {post}
  InitCPIOConfig: {conf}/mkinitcpio.conf
Components:
  ImageDir: {zbm}
  Versions: 3
  Enabled: false
EFI:
  ImageDir: {zbm}
  Versions: false
  Enabled: true
Kernel:
  Prefix: vmlinuz
  CommandLine: {cmdline}
""".format(esp=ESP_MOUNT, dracut=DRACUT_DIR, pre=PRE_DIR, post=POST_DIR, conf=CONF_DIR,
           zbm=ZBM_DIR, cmdline=cmdline))
    dz.write_file(POST_DIR + "/50-update-fallback.sh", """\
#!/bin/sh
# Refresh \\EFI\\BOOT\\BOOTX64.EFI if zbm_setup.py installed it
if [ -f "{fb}/.zfsbootmenu" ] && [ -f "{zbm}/vmlinuz.EFI" ]; then
    cp "{zbm}/vmlinuz.EFI" "{fb}/BOOTX64.EFI"
fi
""".format(fb=FALLBACK_DIR, zbm=ZBM_DIR), mode=0o755)
    info("ZBM kernel command line: %s" % cmdline)


def generate_image(c):
    step("Generating ZFSBootMenu image")
    dz.run(["mkdir", "-p", ZBM_DIR])
    dz.run(["generate-zbm"])
    if dz.DRY_RUN:
        return
    if not os.path.exists(IMAGE):
        die("generate-zbm finished but %s is missing" % IMAGE)
    if not os.path.exists(BACKUP_IMAGE):
        shutil.copy(IMAGE, BACKUP_IMAGE)
    info("Image: %s (%s)" % (IMAGE, dz.human_size(os.path.getsize(IMAGE))))


def verify_image(c):
    step("Verifying the ZFSBootMenu image")
    if dz.DRY_RUN:
        return
    if not dz.have("objcopy") or not dz.have("lsinitrd"):
        warn("objcopy/lsinitrd not available — skipping verification")
        return
    tmp = tempfile.mkdtemp()
    try:
        initrd, cmdline = os.path.join(tmp, "initrd"), os.path.join(tmp, "cmdline")
        dz.run(["objcopy", "-O", "binary", "--only-section=.initrd", IMAGE, initrd], check=False, quiet=True)
        dz.run(["objcopy", "-O", "binary", "--only-section=.cmdline", IMAGE, cmdline], check=False, quiet=True)
        if not os.path.exists(initrd) or os.path.getsize(initrd) == 0:
            warn("Could not extract the initrd from the image — skipping verification")
            return
        listing = dz.out(["lsinitrd", initrd])
        good = True
        items = []
        if c.mdraid:
            items += ["sbin/mdadm", "raid0.ko", "vmd.ko", "mdadm.conf", "10-mdraid-assemble.sh"]
        if c.apple:
            items += ["hid-apple.ko", "usbhid.ko", "xhci-pci.ko"]
        if c.network:
            items += ["bin/dropbear", "bin/busybox", "20-network-ssh.sh", "authorized_keys"]
        for item in items:
            if item in listing:
                info("  found: %s ✓" % item)
            else:
                warn("  MISSING: %s" % item)
                good = False
        text = open(cmdline, "rb").read().decode(errors="replace") if os.path.exists(cmdline) else ""
        if c.mdraid:
            if "rd.auto=1" in text:
                info("  cmdline: rd.auto=1 ✓")
            else:
                warn("  cmdline does not contain rd.auto=1")
                good = False
        if good:
            info("The image contains everything requested ✓")
        else:
            warn("Some requested pieces are missing from the image — see warnings above")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


###############################################################################
# EFI boot entries
###############################################################################

ENTRY_RE = re.compile(r"^Boot([0-9A-Fa-f]{4})[* ] (.*)$")


def efi_entry_nums(label):
    nums = []
    for line in dz.out(["efibootmgr"]).splitlines():
        m = ENTRY_RE.match(line)
        if not m:
            continue
        name = m.group(2).split("\t")[0]
        name = re.sub(r"\s+(HD|PciRoot|VenHw|File)\(.*$", "", name).strip()
        if name == label:
            nums.append(m.group(1))
    return nums


def ensure_efivars():
    if not dv.uefi_booted():
        warn("Not booted in UEFI mode — NVRAM boot entries cannot be created")
        return False
    if not dz.ok(["mountpoint", "-q", "/sys/firmware/efi/efivars"]):
        dz.run(["mount", "-t", "efivarfs", "efivarfs", "/sys/firmware/efi/efivars"], check=False, quiet=True)
    return dz.ok(["efibootmgr"])


def remove_entries(label):
    for num in efi_entry_nums(label):
        info("  Removing old entry Boot%s (%s)" % (num, label))
        dz.run(["efibootmgr", "-q", "-B", "-b", num], check=False)


def create_entry(c, label, loader):
    targets = [c.boot_disk]
    # efibootmgr often cannot resolve md devices. On RAID0 the GPT lives at the
    # start of raid-disk 0, so that member yields the same HD(partition GUID)
    # path the RST firmware driver exposes (needs chunk >= 32K for the GPT).
    if dv.is_md(c.boot_disk):
        member = dv.md_first_member(c.boot_disk)
        if member and dv.md_level(c.boot_disk) == "raid0" and dv.md_chunk_size(c.boot_disk) >= 32768:
            targets.append("/dev/" + member)
    remove_entries(label)
    for target in targets:
        res = dz.run(["efibootmgr", "-q", "-c", "-d", target, "-p", str(c.boot_part), "-L", label,
                      "-l", loader], check=False, capture=True, quiet=True)
        if res.returncode == 0 and (dz.DRY_RUN or efi_entry_nums(label)):
            info("  Created '%s' via %s partition %s ✓" % (label, target, c.boot_part))
            return True
        lines = (res.stderr or res.stdout or "").strip().splitlines()
        warn("  efibootmgr failed via %s: %s" % (target, lines[-1] if lines else "no entry created"))
        remove_entries(label)
    return False


def install_fallback():
    target = FALLBACK_DIR + "/BOOTX64.EFI"
    dz.run(["mkdir", "-p", FALLBACK_DIR])
    marker = FALLBACK_DIR + "/.zfsbootmenu"
    if os.path.exists(target) and not os.path.exists(marker) and not os.path.exists(target + ".pre-zbm"):
        info("  Backing up existing BOOTX64.EFI to BOOTX64.EFI.pre-zbm")
        dz.run(["cp", target, target + ".pre-zbm"])
    dz.run(["cp", IMAGE, target])
    dz.run(["touch", marker])
    info(r"  Installed fallback loader \EFI\BOOT\BOOTX64.EFI ✓")


def create_efi_entries(c):
    step("Creating EFI boot entries")
    ok = False
    if ensure_efivars():
        create_entry(c, "ZFSBootMenu (Backup)", BACKUP_LOADER)   # first, so main ends up first
        ok = create_entry(c, "ZFSBootMenu", LOADER)
    if not ok:
        warn("Could not create an NVRAM entry — installing the removable-media fallback loader.")
        warn("If the firmware does not offer it, add a boot option in the UEFI setup for %s" % LOADER)
        install_fallback()
    elif c.fallback or c.apple or os.path.exists(FALLBACK_DIR + "/.zfsbootmenu"):
        # Apple firmware often ignores NVRAM entries; the fallback loader shows
        # up as "EFI Boot" in the Option-key boot picker
        install_fallback()
    dz.run(["efibootmgr", "-v"], check=False)


###############################################################################
# Main
###############################################################################

def main():
    ap = argparse.ArgumentParser(prog="zbm_setup.py", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pool", default="zroot", help="ZFS pool (default: zroot)")
    ap.add_argument("--dataset", default="", help="root dataset inside the pool (default: from the pool's bootfs)")
    ap.add_argument("--boot-device", default="", help="ESP partition (default: from /boot/efi or fstab)")
    ap.add_argument("--boot-disk", default="", help="disk holding the ESP (default: derived)")
    ap.add_argument("--boot-part", default="", help="ESP partition number (default: derived)")
    md = ap.add_mutually_exclusive_group()
    md.add_argument("--mdraid", dest="mdraid", action="store_true", default=None,
                    help="build a local image with Intel RST / mdadm support")
    md.add_argument("--no-mdraid", dest="mdraid", action="store_false", help="never enable mdraid mode")
    mac = ap.add_mutually_exclusive_group()
    mac.add_argument("--macbook", "--apple", dest="apple", action="store_true", default=None,
                     help="MacBook keyboard/trackpad drivers + Apple fallback loader")
    mac.add_argument("--no-macbook", "--no-apple", dest="apple", action="store_false",
                     help="remove the MacBook drivers again")
    net = ap.add_mutually_exclusive_group()
    net.add_argument("--network", dest="network", action="store_true", default=None,
                     help="wired DHCP + SSH (dropbear) in the boot menu")
    net.add_argument("--no-network", dest="network", action="store_false",
                     help="remove network + SSH from the boot menu")
    ap.add_argument("--ssh-key", help="authorized_keys / public key file for --network logins")
    ap.add_argument("--ssh-port", type=int, default=DEFAULT_SSH_PORT, help="SSH port (default: 222)")
    ap.add_argument("--fallback", action="store_true", help=r"also install \EFI\BOOT\BOOTX64.EFI")
    ap.add_argument("--format-esp", action="store_true", help="format the ESP if it is not FAT")
    ap.add_argument("--update", action="store_true", help="update an existing installation")
    ap.add_argument("--yes", "-y", action="store_true", help="never prompt")
    ap.add_argument("--dry-run", action="store_true", help="print commands only")
    a = ap.parse_args()

    dz.set_dry_run(a.dry_run)
    dz.set_assume_yes(a.yes)
    dz.require_root()

    c = Ctx()
    c.pool = a.pool
    c.root_ds = "%s/%s" % (a.pool, a.dataset or dz.default_root_dataset(a.pool))
    c.boot_device, c.boot_disk, c.boot_part = a.boot_device, a.boot_disk, str(a.boot_part or "")
    c.mdraid, c.fallback, c.format_esp, c.update = a.mdraid, a.fallback, a.format_esp, a.update
    c.apple, c.ssh_key, c.ssh_port = a.apple, a.ssh_key, a.ssh_port
    c.network = True if (a.ssh_key and a.network is None) else a.network

    check_prerequisites(c)
    set_dataset_properties(c)
    mount_esp(c)
    # Drop options that are switched off (also remembered choices)
    if not c.apple:
        disable_extra("MacBook", APPLE_CONF)
    if not c.network:
        disable_extra("network/SSH", NETWORK_CONF, HOOK_DIR + "/early-setup.d/20-network-ssh.sh")

    if c.mdraid or c.apple or c.network:
        install_generate_zbm(c)
        ensure_base_dracut_conf()
        if c.mdraid:
            setup_mdraid(c)
        if c.apple:
            setup_apple(c)
        if c.network:
            setup_network(c)
        write_config(c)
        generate_image(c)
        verify_image(c)
    else:
        download_prebuilt(c)
    create_efi_entries(c)

    print()
    dz.banner("ZFSBootMenu CONFIGURED")
    info("Images: %s, %s" % (IMAGE, BACKUP_IMAGE))
    info("ESP: %s (disk %s, partition %s)" % (c.boot_device, c.boot_disk, c.boot_part))
    if c.apple:
        info("MacBook keyboard/trackpad drivers: %s/20-apple-input.conf" % DRACUT_DIR)
        info("Mac: hold Option (⌥) at power-on and pick 'EFI Boot' if ZFSBootMenu does not start;")
    if c.network:
        info("Network + SSH in the boot menu: plug in a wired adapter BEFORE power-on, then")
        info("  ssh -p %s root@<ip>   and run: zfsbootmenu" % c.ssh_port)
        warn("The ZBM host keys live on the unencrypted ESP — anyone with the disk can read them")
    if c.mdraid:
        info("Intel RST / mdadm support: /etc/mdadm/mdadm.conf, %s/10-mdraid.conf," % DRACUT_DIR)
        info("  %s/early-setup.d/10-mdraid-assemble.sh" % HOOK_DIR)
        info("Rebuild after ZFS or mdadm upgrades with: generate-zbm")
    info("Press ESC during boot to open the ZFSBootMenu menu")


if __name__ == "__main__":
    dz.run_main(main)
