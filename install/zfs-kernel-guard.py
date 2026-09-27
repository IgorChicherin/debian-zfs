#!/usr/bin/env python3
"""zfs-kernel-guard — keep kernel updates from breaking a ZFS root system.

What it does once installed ('zfs-kernel-guard install'):

  1. BEFORE apt installs a kernel (APT Pre-Install-Pkgs hook): compares the
     kernel's version with the range OpenZFS supports (Linux-Maximum in the
     zfs-dkms META file, taken from the zfs-dkms package in the same apt run
     if it is being upgraded too). Too new -> the apt run is stopped before
     anything is installed (PREINSTALL=block) or only a warning is shown.

  2. AFTER apt/dpkg finishes (DPkg::Post-Invoke + /etc/kernel/postinst.d and
     postrm.d hooks): for every kernel in /boot checks that DKMS built zfs.ko
     and that the initramfs contains it. With AUTO_FIX=yes it retries the
     DKMS build and rebuilds an initramfs that is missing zfs.ko.

  3. If the newest kernel still has no working ZFS, ZFSBootMenu is pinned
     (org.zfsbootmenu:kernel on the root dataset) to the newest kernel that
     works, so the machine keeps booting. The pin is removed automatically as
     soon as the newest kernel works again. A pin set by hand is never touched.

Commands:
  zfs-kernel-guard install      install hooks + /etc/default/zfs-kernel-guard
  zfs-kernel-guard uninstall    remove hooks (keeps the config file)
  zfs-kernel-guard check        show the ZFS status of every kernel
  zfs-kernel-guard reconcile    fix/pin/unpin (what the hooks run)

Skip the guard for one command:  ZFS_KERNEL_GUARD=off apt upgrade
Standard library only; installed to /usr/local/sbin/zfs-kernel-guard.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tarfile

TARGET = "/usr/local/sbin/zfs-kernel-guard"
CONFIG = "/etc/default/zfs-kernel-guard"
STATE = "/var/lib/zfs-kernel-guard/state.json"
APT_CONF = "/etc/apt/apt.conf.d/80zfs-kernel-guard"
POSTINST = "/etc/kernel/postinst.d/zz-zfs-kernel-guard"
POSTRM = "/etc/kernel/postrm.d/zz-zfs-kernel-guard"
PIN_PROP = "org.zfsbootmenu:kernel"
OWN_PROP = "org.debian-zfs:kernel-guard-pin"   # remembers that we set the pin

DEFAULT_CONFIG = """\
# zfs-kernel-guard settings

# Before apt installs a kernel newer than OpenZFS supports:
#   block = stop the apt run (nothing is installed)   warn = only warn   off
PREINSTALL=block

# Retry the DKMS build of zfs.ko and rebuild an initramfs without zfs.ko: yes | no
AUTO_FIX=yes

# Pin ZFSBootMenu to the newest working kernel while the newest one lacks ZFS: yes | no
PIN_ZBM=yes
"""

HOOK_SH = """\
#!/bin/sh
# zfs-kernel-guard: verify OpenZFS for kernels (installed by zfs-kernel-guard install)
[ -x /usr/bin/python3 ] && [ -x {target} ] || exit 0
{target} {cmd} "$@" || true
exit 0
"""

APT_HOOKS = """\
// zfs-kernel-guard: stop kernel installs OpenZFS does not support, and verify
// zfs.ko + initramfs for every kernel after each dpkg run.
DPkg::Pre-Install-Pkgs {{ "if [ -x /usr/bin/python3 ] && [ -x {t} ]; then {t} apt-pre; else cat >/dev/null; fi"; }};
DPkg::Post-Invoke {{ "if [ -x /usr/bin/python3 ] && [ -x {t} ]; then {t} reconcile --quiet || true; fi"; }};
"""

TTY = sys.stdout.isatty()


def c(code, text):
    return "\033[%sm%s\033[0m" % (code, text) if TTY else text


def say(msg):
    print("zfs-kernel-guard: %s" % msg, flush=True)


def warn(msg):
    print(c("1;33", "zfs-kernel-guard: WARNING: ") + msg, file=sys.stderr, flush=True)


def box(lines):
    width = max(len(l) for l in lines) + 4
    bar = "!" * width
    print(c("1;31", bar), file=sys.stderr)
    for l in lines:
        print(c("1;31", "! ") + l.ljust(width - 4) + c("1;31", " !"), file=sys.stderr)
    print(c("1;31", bar), file=sys.stderr, flush=True)


def out(cmd):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def run(cmd):
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def load_config():
    cfg = {"PREINSTALL": "block", "AUTO_FIX": "yes", "PIN_ZBM": "yes"}
    try:
        with open(CONFIG) as fh:
            for line in fh:
                m = re.match(r"\s*([A-Z_]+)\s*=\s*\"?([^\"#\s]*)", line)
                if m:
                    cfg[m.group(1)] = m.group(2).lower()
    except OSError:
        pass
    if os.environ.get("ZFS_KERNEL_GUARD", "").lower() in ("off", "0", "no", "false"):
        cfg["PREINSTALL"] = "off"
        cfg["AUTO_FIX"] = "no"
        cfg["PIN_ZBM"] = "no"
    return cfg


###############################################################################
# Versions
###############################################################################

def vkey(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", v)]


def major_minor(v):
    m = re.match(r"(\d+)\.(\d+)", v)
    return (int(m.group(1)), int(m.group(2))) if m else None


def parse_meta(text):
    meta = {}
    for line in text.splitlines():
        m = re.match(r"\s*([A-Za-z-]+):\s*(\S+)", line)
        if m:
            meta[m.group(1)] = m.group(2)
    return meta


def installed_zfs_meta():
    """META of the newest installed zfs-dkms source (/usr/src/zfs-*/META)."""
    metas = sorted(glob.glob("/usr/src/zfs-*/META"), key=vkey)
    if not metas:
        return {}
    with open(metas[-1]) as fh:
        return parse_meta(fh.read())


def deb_field(deb, field):
    return out(["dpkg-deb", "-f", deb, field])


def deb_zfs_meta(deb):
    """META from a zfs-dkms .deb about to be installed."""
    try:
        proc = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", deb], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
            for member in tar:
                if re.search(r"usr/src/zfs-[^/]+/META$", member.name):
                    data = tar.extractfile(member).read().decode(errors="replace")
                    proc.stdout.close()
                    proc.wait()
                    return parse_meta(data)
        proc.wait()
    except (OSError, tarfile.TarError):
        pass
    return {}


###############################################################################
# Kernel status
###############################################################################

def kernels():
    vers = [os.path.basename(p)[len("vmlinuz-"):] for p in glob.glob("/boot/vmlinuz-*")]
    return sorted(vers, key=vkey)


def has_zfs_module(ver):
    return bool(glob.glob("/lib/modules/%s/**/zfs.ko*" % ver, recursive=True))


def initrd_has_zfs(ver, state):
    initrd = "/boot/initrd.img-%s" % ver
    if not os.path.exists(initrd):
        return False
    mtime = str(os.path.getmtime(initrd))
    cache = state.setdefault("initrd", {}).get(ver)
    if cache and cache.get("mtime") == mtime:
        return cache["zfs"]
    listing = out(["lsinitramfs", initrd])
    result = bool(re.search(r"/zfs\.ko(\.\w+)?$", listing, re.M))
    state["initrd"][ver] = {"mtime": mtime, "zfs": result}
    return result


def zfs_dkms_version():
    return installed_zfs_meta().get("Version", "")


def try_fix(ver, state, cfg, log):
    """Retry DKMS once per zfs-dkms version, rebuild an initramfs that lacks zfs."""
    if cfg.get("AUTO_FIX") != "yes":
        return
    if not has_zfs_module(ver) and os.path.exists("/lib/modules/%s/build" % ver):
        attempt = "%s|%s" % (ver, zfs_dkms_version())
        if attempt not in state.setdefault("dkms_attempts", []):
            state["dkms_attempts"].append(attempt)
            log("building zfs.ko for %s with DKMS..." % ver)
            run(["dkms", "autoinstall", "-k", ver])
    if has_zfs_module(ver) and not initrd_has_zfs(ver, state) and os.path.exists("/boot/initrd.img-%s" % ver):
        log("initramfs of %s lacks zfs.ko — rebuilding it" % ver)
        run(["update-initramfs", "-u", "-k", ver])


def status_of(ver, state):
    if not has_zfs_module(ver):
        if not os.path.exists("/lib/modules/%s/build" % ver):
            return "BROKEN", "no zfs.ko, linux-headers-%s not installed" % ver
        return "BROKEN", "no zfs.ko — DKMS build failed (dkms status)"
    if not os.path.exists("/boot/initrd.img-%s" % ver):
        return "BROKEN", "no initramfs"
    if not initrd_has_zfs(ver, state):
        return "BROKEN", "initramfs without zfs.ko"
    return "OK", "zfs.ko %s" % (out(["modinfo", "-k", ver, "-F", "version", "zfs"]) or "present")


###############################################################################
# ZFSBootMenu pin
###############################################################################

def root_dataset():
    src = out(["findmnt", "-n", "-o", "SOURCE", "/"])
    fstype = out(["findmnt", "-n", "-o", "FSTYPE", "/"])
    return src if fstype == "zfs" and src else ""


def zget(prop, ds):
    v = out(["zfs", "get", "-H", "-o", "value", prop, ds])
    return "" if v in ("", "-") else v


def apply_pin(latest_ok, newest, cfg, log, loud):
    ds = root_dataset()
    if not ds or cfg.get("PIN_ZBM") != "yes":
        return
    current, ours = zget(PIN_PROP, ds), zget(OWN_PROP, ds)
    manual = current and current != ours
    if newest == latest_ok or latest_ok is None:
        if current and not manual:
            run(["zfs", "inherit", PIN_PROP, ds])
            run(["zfs", "inherit", OWN_PROP, ds])
            log("newest kernel %s works — ZFSBootMenu pin removed" % newest)
        return
    want = "vmlinuz-%s" % latest_ok
    if manual:
        if loud:
            warn("%s is set by hand on %s (%s) — not changing it" % (PIN_PROP, ds, current))
        return
    if current != want:
        run(["zfs", "set", "%s=%s" % (PIN_PROP, want), ds])
        run(["zfs", "set", "%s=%s" % (OWN_PROP, want), ds])
        log("ZFSBootMenu pinned to %s on %s" % (want, ds))


###############################################################################
# Commands
###############################################################################

def load_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w") as fh:
            json.dump(state, fh, indent=1)
    except OSError:
        pass


def cmd_reconcile(args, check_only=False):
    cfg = load_config()
    state = load_state()
    quiet = getattr(args, "quiet", False)
    messages = []
    log = messages.append if quiet else say

    vers = kernels()
    if not vers:
        return 0
    if not check_only:
        for v in vers:
            try_fix(v, state, cfg, log)
    results = {v: status_of(v, state) for v in vers}
    newest = vers[-1]
    working = [v for v in vers if results[v][0] == "OK"]
    latest_ok = working[-1] if working else None

    previous = state.get("results", {})
    changed = {v: r for v, r in results.items() if previous.get(v) != list(r)}
    if not check_only:
        state["results"] = {v: list(r) for v, r in results.items()}

    if check_only or not quiet:
        ds = root_dataset() or "(root is not on ZFS)"
        print("Root dataset: %s   ZFS pin: %s" % (ds, zget(PIN_PROP, ds) or "none"))
        print("zfs-dkms: %s (supports Linux %s - %s)" % (
            zfs_dkms_version() or "not installed", installed_zfs_meta().get("Linux-Minimum", "?"),
            installed_zfs_meta().get("Linux-Maximum", "?")))
        for v in vers:
            st, why = results[v]
            mark = c("0;32", "OK    ") if st == "OK" else c("1;31", "BROKEN")
            print("  %s  %-32s %s%s" % (mark, v, why, "   <- newest" if v == newest else ""))
    if not check_only:
        apply_pin(latest_ok, newest, cfg, log, loud=not quiet)
    for m in messages:
        say(m)

    if results[newest][0] != "OK" and (changed or not quiet):
        lines = ["Kernel %s has NO working OpenZFS: %s." % (newest, results[newest][1]),
                 "Booting it would fail to import the root pool."]
        ds = root_dataset()
        pinned = ds and zget(PIN_PROP, ds) == "vmlinuz-%s" % latest_ok
        if latest_ok and pinned:
            lines.append("ZFSBootMenu is pinned to %s until this is fixed." % latest_ok)
        elif latest_ok and check_only and cfg.get("PIN_ZBM") == "yes" and ds:
            lines.append("Run 'zfs-kernel-guard reconcile' to pin ZFSBootMenu to %s." % latest_ok)
        elif latest_ok:
            lines.append("Pick %s in ZFSBootMenu (Ctrl+K) when booting." % latest_ok)
        else:
            lines.append("NO kernel has working ZFS — do not reboot!")
        lines.append("Details: zfs-kernel-guard check   |   dkms status")
        box(lines)

    save_state(state)
    return 0 if results[newest][0] == "OK" else 1


def cmd_apt_pre(args):
    """APT Pre-Install-Pkgs hook: .deb paths on stdin."""
    debs = [l.strip() for l in sys.stdin if l.strip().endswith(".deb")]
    cfg = load_config()
    if cfg.get("PREINSTALL") == "off" or not debs:
        return 0
    new_kernels, zfs_meta = [], {}
    for deb in debs:
        name = os.path.basename(deb)
        if not (name.startswith("linux-image-") or name.startswith("zfs-dkms_")):
            continue
        pkg = deb_field(deb, "Package")
        if pkg == "zfs-dkms":
            zfs_meta = deb_zfs_meta(deb)
        m = re.match(r"linux-image-(\d+\.\d+.*?)(-unsigned)?$", pkg)
        if m and not pkg.endswith("-dbg"):
            new_kernels.append(m.group(1))
    if not new_kernels:
        return 0
    meta = zfs_meta or installed_zfs_meta()
    maximum, minimum = major_minor(meta.get("Linux-Maximum", "")), major_minor(meta.get("Linux-Minimum", ""))
    if not maximum:
        return 0
    bad = [k for k in new_kernels
           if (major_minor(k) and major_minor(k) > maximum) or (minimum and major_minor(k) and major_minor(k) < minimum)]
    if not bad:
        say("kernel(s) %s are within OpenZFS %s support (Linux %s - %s) ✓" % (
            ", ".join(new_kernels), meta.get("Version", "?"), meta.get("Linux-Minimum", "?"),
            meta.get("Linux-Maximum")))
        return 0
    lines = ["Kernel %s is outside what OpenZFS %s supports (Linux %s - %s)." % (
                ", ".join(bad), meta.get("Version", "?"), meta.get("Linux-Minimum", "?"),
                meta.get("Linux-Maximum")),
             "Its zfs.ko will most likely fail to build and the root pool would not import."]
    if cfg.get("PREINSTALL") == "block":
        lines += ["The apt run was STOPPED — nothing has been installed.",
                  "Options: wait for a newer zfs-dkms, or keep the current kernel:",
                  "  apt-mark hold linux-image-amd64 linux-headers-amd64",
                  "Install anyway:  ZFS_KERNEL_GUARD=off apt ...   (PREINSTALL in %s)" % CONFIG]
        box(lines)
        return 1
    box(lines + ["PREINSTALL=warn — continuing."])
    return 0


def cmd_kernel_hook(args):
    """/etc/kernel/postinst.d and postrm.d: under apt, Post-Invoke does the check."""
    if os.environ.get("DPKG_FRONTEND_LOCKED") or os.environ.get("APT_HOOK_INFO_FD"):
        if args.cmd == "kernel-postinst":
            say("will verify OpenZFS for %s when apt finishes" % (args.version or "the new kernel"))
        return 0
    args.quiet = True
    return cmd_reconcile(args) and 0


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, mode)


def cmd_install(args):
    src = os.path.abspath(__file__)
    if os.path.realpath(src) != os.path.realpath(TARGET):
        with open(src) as fh:
            write(TARGET, fh.read(), 0o755)
    if not os.path.exists(CONFIG):
        write(CONFIG, DEFAULT_CONFIG)
    write(POSTINST, HOOK_SH.format(target=TARGET, cmd="kernel-postinst"), 0o755)
    write(POSTRM, HOOK_SH.format(target=TARGET, cmd="kernel-postrm"), 0o755)
    write(APT_CONF, APT_HOOKS.format(t=TARGET))
    say("installed: %s, %s, %s, %s" % (TARGET, APT_CONF, POSTINST, POSTRM))
    say("settings: %s" % CONFIG)
    args.quiet = False
    cmd_reconcile(args)
    return 0


def cmd_uninstall(args):
    for path in (APT_CONF, POSTINST, POSTRM, TARGET):
        if os.path.exists(path):
            os.remove(path)
            say("removed %s" % path)
    ds = root_dataset()
    if ds and zget(OWN_PROP, ds) and zget(OWN_PROP, ds) == zget(PIN_PROP, ds):
        run(["zfs", "inherit", PIN_PROP, ds])
        run(["zfs", "inherit", OWN_PROP, ds])
        say("removed the ZFSBootMenu pin on %s" % ds)
    say("kept %s" % CONFIG)
    return 0


def main():
    ap = argparse.ArgumentParser(prog="zfs-kernel-guard", description=__doc__.split("\n\n")[0],
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install", help="install hooks and config")
    sub.add_parser("uninstall", help="remove hooks")
    sub.add_parser("check", help="show OpenZFS status of every kernel (exit 1 if the newest is broken)")
    r = sub.add_parser("reconcile", help="fix / pin / unpin (run by the hooks)")
    r.add_argument("--quiet", action="store_true", help="only print problems and changes")
    sub.add_parser("apt-pre", help="APT Pre-Install-Pkgs hook (reads .deb paths on stdin)")
    for name in ("kernel-postinst", "kernel-postrm"):
        k = sub.add_parser(name, help="/etc/kernel hook")
        k.add_argument("version", nargs="?")
        k.add_argument("image", nargs="?")
    args = ap.parse_args()

    if args.cmd not in ("check", "apt-pre") and os.geteuid() != 0:
        print("zfs-kernel-guard: run as root", file=sys.stderr)
        return 1
    if args.cmd == "install":
        return cmd_install(args)
    if args.cmd == "uninstall":
        return cmd_uninstall(args)
    if args.cmd == "check":
        return cmd_reconcile(args, check_only=True)
    if args.cmd == "reconcile":
        return cmd_reconcile(args)
    if args.cmd == "apt-pre":
        return cmd_apt_pre(args)
    return cmd_kernel_hook(args)


if __name__ == "__main__":
    sys.exit(main())
