import _path  # noqa: F401
import unittest
from unittest import mock

import dzlib as dz
import mdraid_rescue as mr

IMPORT_TEXT = """\
   pool: zroot
     id: 12345678901234567890
  state: ONLINE
 action: The pool can be imported using its name or numeric identifier, though
	some features are unavailable without an explicit 'zpool upgrade'.
 config:

	zroot       ONLINE
	  md126p2   ONLINE

   pool: tank
     id: 42
  state: ONLINE
 status: Some supported features are not enabled on the pool.
 action: The pool can be imported using its name or numeric identifier and
	the '-f' flag.
"""

LISTING = "\n".join("\t".join(r) for r in [
    ("zroot", "none", "on"),
    ("zroot/ROOT", "none", "on"),
    ("zroot/ROOT/trixie", "/mnt", "noauto"),
    ("zroot/ROOT/sid", "/mnt", "noauto"),
    ("zroot/home", "/mnt/home", "on"),
    ("zroot/var-log", "/mnt/var/log", "on"),
    ("zroot/scratch", "none", "on"),
])


class ParserTest(unittest.TestCase):
    def test_parse_zpool_import(self):
        pools = mr.parse_zpool_import(IMPORT_TEXT)
        self.assertEqual([p["name"] for p in pools], ["zroot", "tank"])
        self.assertEqual(pools[0]["id"], "12345678901234567890")
        self.assertFalse(pools[0]["force"])
        self.assertTrue(pools[1]["force"])
        self.assertEqual(pools[0]["state"], "ONLINE")

    def test_parse_zpool_import_empty(self):
        self.assertEqual(mr.parse_zpool_import(""), [])
        self.assertEqual(mr.parse_zpool_import("no pools available to import"), [])

    def test_parse_label_pool(self):
        self.assertEqual(mr.parse_label_pool("------\nLABEL 0\n    version: 5000\n    name: 'zroot'\n"), "zroot")
        self.assertEqual(mr.parse_label_pool("failed to unpack label 0"), "")

    def test_keys_locked(self):
        self.assertTrue(mr.keys_locked("zroot\tavailable\nzroot/ROOT/trixie\tunavailable\n"))
        self.assertFalse(mr.keys_locked("zroot\t-\nzroot/ROOT/trixie\tavailable\n"))

    def test_boot_environments_use_the_altroot(self):
        self.assertEqual(mr.boot_environments(LISTING), ["zroot/ROOT/trixie", "zroot/ROOT/sid"])
        self.assertEqual(mr.boot_environments(LISTING.replace("/mnt\t", "/\t"), "/mnt")[:1], ["zroot/ROOT/trixie"])

    def test_data_datasets_skip_other_boot_environments_and_unmounted(self):
        self.assertEqual(mr.data_datasets(LISTING, "zroot/ROOT/trixie"), ["zroot/home", "zroot/var-log"])


class FlowTest(unittest.TestCase):
    def test_find_pools_widens_the_search(self):
        answers = {("zpool", "import"): "", ("zpool", "import", "-d", "/dev"): IMPORT_TEXT}
        with mock.patch.object(dz, "out", lambda cmd, default="": answers.get(tuple(cmd), "")), \
                mock.patch.object(mr, "md_partitions", return_value=[]):
            args, pools = mr.find_pools([])
        self.assertEqual(args, ["-d", "/dev"])
        self.assertEqual(len(pools), 2)

    def test_pick_pool_refuses_a_pool_that_cannot_be_imported(self):
        bad = [{"name": "zroot", "id": "1", "state": "UNAVAIL", "action": "missing devices", "force": False}]
        with mock.patch.object(mr, "find_pools", return_value=([], bad)):
            with self.assertRaises(dz.Fatal):
                mr.pick_pool([])

    def test_repair_runs_zbm_setup_for_the_boot_environment(self):
        with mock.patch.object(mr.system, "mount_virtual_filesystems") as virtual, \
                mock.patch.object(mr.system, "run_zbm_setup") as run:
            mr.repair("zroot", "zroot/ROOT/trixie", "/dev/md126p1")
        virtual.assert_called_once_with()
        run.assert_called_once_with(["--yes", "--update", "--mdraid", "--pool", "zroot",
                                     "--dataset", "ROOT/trixie", "--boot-device", "/dev/md126p1"])


if __name__ == "__main__":
    unittest.main()
