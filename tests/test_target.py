import _path  # noqa: F401
import unittest
from unittest import mock

import devices as dv
import target

GIB = 1024 ** 3


def dev(path, **kw):
    d = {"path": path, "kname": path.split("/")[-1], "size": 100 * GIB, "type": "part", "fstype": "",
         "parttype": "", "mountpoint": "", "pkname": ""}
    d.update(kw)
    return d


class CandidatesTest(unittest.TestCase):
    def setUp(self):
        patches = [mock.patch.object(dv, "zfs_pool_members", return_value=set()),
                   mock.patch.object(dv, "disk_md_holders", return_value=[])]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_pool_candidates_skip_disks_esp_mounted_and_small(self):
        devices = [dev("/dev/sda", type="disk"),
                   dev("/dev/sda1", parttype=dv.ESP_GUID, size=GIB),
                   dev("/dev/sda2", mountpoint="/mnt"),
                   dev("/dev/sda3", size=2 * GIB),
                   dev("/dev/sda4")]
        self.assertEqual([d["path"] for d in target.pool_candidates(devices)], ["/dev/sda4"])

    def test_esp_candidates_take_esp_guid_or_vfat_and_exclude_the_pool(self):
        devices = [dev("/dev/sda1", parttype=dv.ESP_GUID, size=GIB),
                   dev("/dev/sda2", fstype="vfat", size=GIB),
                   dev("/dev/sda3", fstype="ext4")]
        self.assertEqual([d["path"] for d in target.esp_candidates(devices)], ["/dev/sda1", "/dev/sda2"])
        self.assertEqual([d["path"] for d in target.esp_candidates(devices, exclude="/dev/sda1")],
                         ["/dev/sda2"])

    def test_pool_label_warns_about_existing_data(self):
        self.assertIn("ERASED", target.pool_label(dev("/dev/sda4", fstype="zfs_member")))
        self.assertIn("ntfs", target.pool_label(dev("/dev/sda4", fstype="ntfs")))
        self.assertNotIn("ERASED", target.pool_label(dev("/dev/sda4")))


if __name__ == "__main__":
    unittest.main()
