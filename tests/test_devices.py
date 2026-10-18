import _path  # noqa: F401
import os
import tempfile
import unittest

import devices as dv


class DevicesTest(unittest.TestCase):
    def test_partition_device(self):
        self.assertEqual(dv.partition_device("/dev/sda", 1), "/dev/sda1")
        self.assertEqual(dv.partition_device("/dev/nvme0n1", 2), "/dev/nvme0n1p2")
        self.assertEqual(dv.partition_device("/dev/md126", 1), "/dev/md126p1")

    def with_sysfs(self, dirs, fn):
        with tempfile.TemporaryDirectory() as tmp:
            for rel in dirs:
                os.makedirs(os.path.join(tmp, rel))
            old = dv.SYSFS
            dv.SYSFS = tmp
            try:
                fn(tmp)
            finally:
                dv.SYSFS = old

    def test_md_holders_of_partitions_and_disks(self):
        def check(_):
            self.assertEqual(dv.disk_md_holders("/dev/nvme0n1p3"), ["md126"])
            self.assertEqual(dv.disk_md_holders("/dev/sdb"), ["md0"])
            self.assertEqual(dv.disk_md_holders("/dev/sdb1"), [])
            self.assertEqual(dv.disk_md_holders("/dev/sdc"), [])
        self.with_sysfs(["block/nvme0n1p3/holders/md126", "block/sdb/sdb1/holders/md0", "block/sdc/holders"],
                        check)

    def test_uefi_booted_follows_sysfs(self):
        self.with_sysfs(["firmware/efi"], lambda _: self.assertTrue(dv.uefi_booted()))
        self.with_sysfs(["firmware"], lambda _: self.assertFalse(dv.uefi_booted()))

    def test_broadcom_wl_devices(self):
        def check(tmp):
            for name, vendor, device in (("0000:03:00.0", "0x14e4", "0x4331"),
                                         ("0000:04:00.0", "0x14e4", "0x1234"),
                                         ("0000:05:00.0", "0x8086", "0x4331")):
                path = os.path.join(tmp, "bus/pci/devices", name)
                os.makedirs(path)
                for fname, value in (("vendor", vendor), ("device", device)):
                    with open(os.path.join(path, fname), "w") as fh:
                        fh.write(value + "\n")
            self.assertEqual(dv.broadcom_wl_devices(), ["0000:03:00.0"])
        self.with_sysfs([], check)

    def test_describe_marks_esp_and_mountpoint(self):
        text = dv.describe({"path": "/dev/sda1", "size": 512 * 1024 ** 2, "type": "part", "fstype": "vfat",
                            "parttype": dv.ESP_GUID, "mountpoint": "/boot/efi"})
        self.assertIn("[EFI System]", text)
        self.assertIn("mounted:/boot/efi", text)


if __name__ == "__main__":
    unittest.main()
