"""dzlib — shared helpers for the debian-zfs installer scripts.

Standard library only (runs on a plain Debian live system and inside the
debootstrapped target). Keep this file next to the scripts that import it.
"""

import os
import shlex
import shutil
import subprocess
import sys

###############################################################################
# Debian releases
###############################################################################

# Kernel modules for an md RAID root; imsm is mdadm metadata, not a module
MD_MODULES = ("vmd", "md_mod", "raid0", "raid1", "raid10")

MIRROR = "http://deb.debian.org/debian"
SECURITY_MIRROR = "http://deb.debian.org/debian-security"
COMPONENTS = "main contrib non-free non-free-firmware"
KEYRING = "/usr/share/keyrings/debian-archive-keyring.gpg"

RELEASES = {
    "stable": {"codename": "trixie", "security": True, "updates": True,
               "label": "Debian 13 'trixie' (stable) — recommended"},
    "sid": {"codename": "sid", "security": False, "updates": False,
            "label": "Debian sid (unstable) — rolling, can break; ZFS DKMS may lag new kernels"},
}
RELEASE_ALIASES = {"trixie": "stable", "13": "stable", "unstable": "sid"}
DEFAULT_RELEASE = "stable"


def resolve_release(name):
    """'stable' / 'trixie' / '13' -> 'stable'; 'sid' / 'unstable' -> 'sid'."""
    key = RELEASE_ALIASES.get((name or "").lower(), (name or "").lower())
    if key not in RELEASES:
        raise Fatal("Unknown release '%s' — use: %s" % (name, ", ".join(sorted(RELEASES))))
    return key


def release_suites(key):
    """(main suites, security suites) for a release key."""
    rel = RELEASES[key]
    code = rel["codename"]
    suites = [code] + (["%s-updates" % code] if rel["updates"] else [])
    security = ["%s-security" % code] if rel["security"] else []
    return suites, security


def deb822_sources(key):
    """Contents for /etc/apt/sources.list.d/debian.sources."""
    suites, security = release_suites(key)
    text = ("Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n"
            % (MIRROR, " ".join(suites), COMPONENTS, KEYRING))
    if security:
        text += ("\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n"
                 % (SECURITY_MIRROR, " ".join(security), COMPONENTS, KEYRING))
    return text


def host_codename():
    """VERSION_CODENAME of the running system ('' if unknown)."""
    try:
        with open("/etc/os-release") as fh:
            for line in fh:
                if line.startswith("VERSION_CODENAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


###############################################################################
# Logging
###############################################################################

_TTY = sys.stdout.isatty()


def _c(code, text):
    return "\033[%sm%s\033[0m" % (code, text) if _TTY else text


def info(msg=""):
    print("%s %s" % (_c("0;32", "[INFO]"), msg), flush=True)


def warn(msg):
    print("%s %s" % (_c("1;33", "[WARN]"), msg), flush=True)


def error(msg):
    print("%s %s" % (_c("0;31", "[ERROR]"), msg), file=sys.stderr, flush=True)


def step(msg):
    print("\n%s %s" % (_c("0;34", "[STEP]"), msg), flush=True)


def banner(msg):
    line = "═" * 55
    warn(line)
    warn(msg)
    warn(line)


class Fatal(Exception):
    """Raised to abort with a message; caught in run_main()."""


def die(msg):
    raise Fatal(msg)


def run_main(main):
    """Call main() and turn Fatal/KeyboardInterrupt/CalledProcessError into exit codes."""
    try:
        rc = main()
        sys.exit(rc or 0)
    except Fatal as exc:
        error(str(exc))
        sys.exit(1)
    except subprocess.CalledProcessError as exc:
        cmd = exc.cmd if isinstance(exc.cmd, str) else shlex.join(exc.cmd)
        error("Command failed (exit %s): %s" % (exc.returncode, cmd))
        sys.exit(exc.returncode or 1)
    except KeyboardInterrupt:
        error("Interrupted")
        sys.exit(130)


def require_root():
    if os.geteuid() != 0:
        die("Run this script as root (sudo)")


###############################################################################
# Running commands
###############################################################################

DRY_RUN = False


def set_dry_run(value):
    global DRY_RUN
    DRY_RUN = bool(value)


def have(cmd):
    return shutil.which(cmd) is not None


def run(cmd, check=True, capture=False, input=None, env=None, chroot=None,
        quiet=False, always=False, stdout=None):
    """Run a command (list). Honors dry-run unless always=True.

    chroot=PATH runs it inside that root. capture=True returns stdout text.
    Returns CompletedProcess (stdout is '' in dry-run).
    """
    if chroot:
        cmd = ["chroot", chroot] + list(cmd)
    if DRY_RUN and not always:
        print("[DRY-RUN] %s" % shlex.join(cmd), flush=True)
        return subprocess.CompletedProcess(cmd, 0, "", "")
    full_env = None
    if env:
        full_env = dict(os.environ)
        full_env.update(env)
    kwargs = {"env": full_env, "text": True}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE if quiet else None
    elif stdout is not None:
        kwargs["stdout"] = stdout
        kwargs["stderr"] = subprocess.STDOUT
    elif quiet:
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL
    if input is not None:
        kwargs["input"] = input
    return subprocess.run(cmd, check=check, **kwargs)


def out(cmd, default=""):
    """Read-only query: return stripped stdout, or default on any failure.

    Always executes (also in dry-run)."""
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, check=False)
    except OSError:
        return default
    if res.returncode != 0:
        return default
    return res.stdout.strip()


def ok(cmd):
    """Return True if the (read-only) command exits 0. Always executes."""
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              check=False).returncode == 0
    except OSError:
        return False


def write_file(path, content, mode=None):
    if DRY_RUN:
        print("[DRY-RUN] write %s" % path, flush=True)
        return
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w") as fh:
        fh.write(content)
    if mode is not None:
        os.chmod(path, mode)


def append_line(path, line):
    """Append a line if it is not already present."""
    existing = []
    if os.path.exists(path):
        with open(path) as fh:
            existing = [l.rstrip("\n") for l in fh]
    if line in existing:
        return
    if DRY_RUN:
        print("[DRY-RUN] append to %s: %s" % (path, line), flush=True)
        return
    with open(path, "a") as fh:
        fh.write(line + "\n")


###############################################################################
# Prompts
###############################################################################

ASSUME_YES = False


def set_assume_yes(value):
    global ASSUME_YES
    ASSUME_YES = bool(value)


def _input(prompt):
    """input() that turns end-of-input (closed stdin) into a clean abort."""
    try:
        return input(prompt)
    except EOFError:
        print()
        raise Fatal("No answer (end of input) — cancelled")


def ask(prompt, default=None, secret=False):
    suffix = " [%s]" % default if default not in (None, "") and not secret else ""
    if secret:
        import getpass
        value = getpass.getpass("%s: " % prompt)
    else:
        value = _input("%s%s: " % (prompt, suffix)).strip()
    return value if value else (default or "")


def confirm(prompt):
    """Require the literal answer 'yes' (unless --yes was given)."""
    if ASSUME_YES:
        return True
    answer = _input("%s (yes/no): " % prompt).strip().lower()
    return answer == "yes"


def choose(title, labels, allow_cancel=True):
    """Numbered menu; returns the chosen index or None when cancelled."""
    if not labels:
        return None
    print()
    info(title)
    for i, label in enumerate(labels, 1):
        print("  %2d) %s" % (i, label))
    if allow_cancel:
        print("   q) cancel")
    while True:
        answer = _input("Select 1-%d%s: " % (len(labels), " or q" if allow_cancel else "")).strip()
        if allow_cancel and answer.lower() in ("q", "quit", ""):
            return None
        if answer.isdigit() and 1 <= int(answer) <= len(labels):
            return int(answer) - 1
        warn("Invalid choice")


def ask_passphrase(prompt="ZFS encryption passphrase", min_len=8):
    import getpass
    while True:
        p1 = getpass.getpass("%s (min %d chars): " % (prompt, min_len))
        if len(p1) < min_len:
            warn("Passphrase too short")
            continue
        p2 = getpass.getpass("Repeat: ")
        if p1 != p2:
            warn("Passphrases do not match")
            continue
        return p1


###############################################################################
# Sizes and lookups
###############################################################################

def human_size(num_bytes):
    num = float(num_bytes or 0)
    for unit in ("B", "K", "M", "G", "T", "P"):
        if num < 1024 or unit == "P":
            return ("%.0f%s" if unit == "B" else "%.1f%s") % (num, unit)
        num /= 1024.0
    return str(num_bytes)


def find_zbm_config_dir(script_dir):
    """config/zfsbootmenu next to the scripts (live ISO) or in the repository root."""
    for base in (script_dir, os.path.dirname(script_dir)):
        path = os.path.join(base, "config", "zfsbootmenu")
        if os.path.isdir(path):
            return path
    return ""


def default_root_dataset(pool, fallback="ROOT/trixie"):
    """Dataset below the pool from its bootfs property (e.g. 'ROOT/trixie')."""
    bootfs = out(["zpool", "get", "-H", "-o", "value", "bootfs", pool])
    if bootfs and bootfs != "-" and bootfs.startswith(pool + "/"):
        return bootfs[len(pool) + 1:]
    return fallback
