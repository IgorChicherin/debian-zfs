import _path  # noqa: F401
import unittest

import dzlib as dz
import plan as pl

DOC = "Short description.\n\nLong epilog."


def build(*argv):
    return pl.build_plan(pl.parse_args(list(argv), DOC))


class PlanTest(unittest.TestCase):
    def test_disk_mode_defaults(self):
        plan = build("--disk", "/dev/sda")
        self.assertEqual(plan.mode, "disk")
        self.assertEqual(plan.root_ds, "zroot/ROOT/trixie")
        self.assertEqual(plan.key_file, "/etc/zfs/zroot.key")
        self.assertTrue(plan.kernel_guard)

    def test_modes(self):
        self.assertEqual(build("--disk", "/dev/sda", "--use-free-space").mode, "free-space")
        self.assertEqual(build("--pool-part", "/dev/sda5", "--efi-device", "/dev/sda1").mode, "partitions")
        self.assertEqual(build("--pool", "tank", "--efi-device", "/dev/sda1").mode, "existing-pool")

    def test_sid_names_the_boot_environment_after_the_codename(self):
        plan = build("--disk", "/dev/sda", "--release", "sid")
        self.assertEqual(plan.root_ds, "zroot/ROOT/sid")

    def test_boot_env_override(self):
        plan = build("--disk", "/dev/sda", "--boot-env", "work", "--pool-name", "tank")
        self.assertEqual(plan.root_ds, "tank/ROOT/work")

    def test_no_target_is_fatal(self):
        with self.assertRaises(dz.Fatal):
            build()

    def test_zbm_network_needs_a_key(self):
        with self.assertRaises(dz.Fatal):
            build("--disk", "/dev/sda", "--zbm-network")

    def test_no_kernel_guard(self):
        self.assertFalse(build("--disk", "/dev/sda", "--no-kernel-guard").kernel_guard)


if __name__ == "__main__":
    unittest.main()
