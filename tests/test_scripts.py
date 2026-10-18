import _path  # noqa: F401
import os
import subprocess
import sys
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCRIPTS = ["install/debian_zfs_install.py", "install/zbm_setup.py", "install/zram_config.py",
           "install/zbm_check_kernels.py", "install/zfs_kernel_guard.py", "install/mdraid_rescue.py",
           "scripts/build_iso.py", "scripts/test-vm.py", "scripts/usb-write.py"]


class ScriptsTest(unittest.TestCase):
    def test_every_script_answers_help(self):
        for rel in SCRIPTS:
            res = subprocess.run([sys.executable, "-W", "ignore", os.path.join(ROOT, rel), "--help"],
                                 capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, "%s: %s" % (rel, res.stderr))
            self.assertIn("usage", res.stdout.lower(), rel)

    def test_installer_modules_import_without_a_cycle(self):
        import importlib
        for name in ("dzlib", "devices", "plan", "target", "zfsops", "system", "debian_zfs_install", "mdraid_rescue"):
            importlib.import_module(name)

    def test_files_copied_into_the_chroot_exist(self):
        import system
        for name in system.ZBM_STAGE_FILES + (os.path.basename(system.KERNEL_GUARD),):
            self.assertTrue(os.path.exists(os.path.join(ROOT, "install", name)), name)


if __name__ == "__main__":
    unittest.main()
