import _path  # noqa: F401
import unittest

import dzlib as dz


class ReleasesTest(unittest.TestCase):
    def test_aliases(self):
        for name in ("stable", "trixie", "13", "STABLE"):
            self.assertEqual(dz.resolve_release(name), "stable")
        for name in ("sid", "unstable"):
            self.assertEqual(dz.resolve_release(name), "sid")

    def test_unknown_release_is_fatal(self):
        with self.assertRaises(dz.Fatal):
            dz.resolve_release("bookworm")

    def test_stable_has_updates_and_security(self):
        text = dz.deb822_sources("stable")
        self.assertIn("Suites: trixie trixie-updates", text)
        self.assertIn("Suites: trixie-security", text)

    def test_sid_has_a_single_suite(self):
        text = dz.deb822_sources("sid")
        self.assertIn("Suites: sid\n", text)
        self.assertNotIn("security", text)


class HelpersTest(unittest.TestCase):
    def test_human_size(self):
        self.assertEqual(dz.human_size(0), "0B")
        self.assertEqual(dz.human_size(512 * 1024 ** 2), "512.0M")
        self.assertEqual(dz.human_size(3 * 1024 ** 4), "3.0T")

    def test_dry_run_prints_and_does_not_execute(self):
        import contextlib
        import io
        dz.set_dry_run(True)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                res = dz.run(["false"])
            self.assertEqual(res.returncode, 0)
            self.assertIn("[DRY-RUN] false", buf.getvalue())
        finally:
            dz.set_dry_run(False)

    def test_die_raises_fatal(self):
        with self.assertRaises(dz.Fatal):
            dz.die("boom")


if __name__ == "__main__":
    unittest.main()
