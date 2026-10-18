import _path  # noqa: F401
import contextlib
import io
import unittest
from unittest import mock

import debian_zfs_install as inst
import dzlib as dz


def dry_run(*argv):
    buf = io.StringIO()
    with mock.patch.object(inst.sys, "argv", ["debian_zfs_install.py", "--dry-run", "--yes", "--skip-packages",
                                              "--password", "x"] + list(argv)), \
            mock.patch.object(dz, "require_root"), contextlib.redirect_stdout(buf):
        try:
            inst.main()
        finally:
            dz.set_dry_run(False)
            dz.set_assume_yes(False)
    return buf.getvalue()


class DryRunTest(unittest.TestCase):
    def test_whole_disk_runs_every_stage_in_order(self):
        out = dry_run("--disk", "/dev/null")
        markers = ["sgdisk --zap-all", "zpool create", "zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/trixie",
                   "debootstrap", "update-initramfs", "zbm_setup.py", "umount -R /mnt"]
        positions = [out.index(m) for m in markers]
        self.assertEqual(positions, sorted(positions))

    def test_macbook_and_sid_reach_the_boot_menu_setup(self):
        out = dry_run("--disk", "/dev/null", "--release", "sid", "--macbook")
        self.assertIn("debootstrap --components=main,contrib,non-free-firmware sid /mnt", out)
        self.assertIn("--dataset ROOT/sid", out)
        self.assertIn("--macbook", out)

    def test_encryption_writes_a_key_file_and_sets_the_key_source(self):
        out = dry_run("--disk", "/dev/null", "--encrypt", "--passphrase", "longpassphrase")
        self.assertIn("encryption=aes-256-gcm", out)
        self.assertIn("org.zfsbootmenu:keysource=zroot/ROOT/trixie", out)

    def test_kernel_guard_is_optional(self):
        self.assertIn("zfs_kernel_guard.py install", dry_run("--disk", "/dev/null"))
        self.assertNotIn("zfs_kernel_guard.py", dry_run("--disk", "/dev/null", "--no-kernel-guard"))


if __name__ == "__main__":
    unittest.main()
