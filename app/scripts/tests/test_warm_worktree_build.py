"""Run with python3 -m unittest discover -s scripts/tests (no database needed)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "warm_worktree_build.sh"


class WarmWorktreeBuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.main = self.root / "main checkout"
        self.tree = self.root / "clinical review"
        self.git("init", "-b", "main", str(self.main))
        self.git("-C", str(self.main), "-c", "user.name=Sample",
                 "-c", "user.email=sample@example.com", "commit", "--allow-empty", "-m", "Initial")
        self.git("-C", str(self.main), "worktree", "add", "-b", "clinical-review", str(self.tree))
        scripts = self.tree / "app/scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / SCRIPT.name
        shutil.copy2(SCRIPT, self.script)

    def git(self, *args):
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True)

    def write(self, root, path, content="warm cache"):
        target = root / "app" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return target

    def run_script(self, env=None):
        result = subprocess.run(["bash", str(self.script)], cwd="/", env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_copies_independent_caches_preserving_links_modes_and_timestamps(self):
        source = self.write(self.main, "deps/primary_care/priv/helper")
        source.chmod(0o755)
        os.utime(source, (1000000000, 1000000000))
        self.write(self.main, "_build/dev/lib/primary_care/ebin/module.beam")
        self.write(self.main, "_build/test/lib/primary_care/ebin/module.beam")
        link = self.main / "app/_build/dev/lib/primary_care/priv"
        link.symlink_to("../../../../deps/primary_care/priv", target_is_directory=True)
        self.run_script()
        copied = self.tree / "app/deps/primary_care/priv/helper"
        self.assertEqual(copied.stat().st_mode & 0o777, 0o755)
        self.assertEqual(copied.stat().st_mtime_ns, source.stat().st_mtime_ns)
        self.assertNotEqual(copied.stat().st_ino, source.stat().st_ino)
        copied_link = self.tree / "app/_build/dev/lib/primary_care/priv"
        self.assertTrue(copied_link.is_symlink())
        self.assertEqual(copied_link.resolve(), copied.parent)
        self.assertTrue((self.tree / "app/_build/test/lib/primary_care/ebin/module.beam").is_file())
        copied.write_text("branch change")
        self.assertEqual(source.read_text(), "warm cache")

    def test_missing_caches_are_optional(self):
        self.run_script()
        self.assertFalse((self.tree / "app/deps").exists())
        self.assertFalse((self.tree / "app/_build/dev").exists())

    def test_rerun_preserves_existing_worktree_caches(self):
        self.write(self.main, "deps/primary_care/value", "main")
        self.write(self.main, "_build/dev/value", "main")
        self.run_script()
        for path in ["deps/primary_care/value", "_build/dev/value"]:
            self.write(self.tree, path, "branch")
        self.run_script()
        for path in ["deps/primary_care/value", "_build/dev/value"]:
            self.assertEqual((self.tree / "app" / path).read_text(), "branch")

    def test_running_in_main_checkout_is_a_noop(self):
        scripts = self.main / "app/scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        self.script = scripts / SCRIPT.name
        self.write(self.main, "deps/primary_care/value")
        self.run_script()
        self.assertEqual((self.main / "app/deps/primary_care/value").read_text(), "warm cache")

    def test_failed_copy_discards_partial_cache_and_allows_normal_setup(self):
        self.write(self.main, "deps/primary_care/value")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        cp = bin_dir / "cp"
        cp.write_text('#!/usr/bin/env bash\ntouch "${@: -1}/partial"\nexit 1\n')
        cp.chmod(0o755)
        result = self.run_script(dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}"))
        self.assertIn("could not copy", result.stderr)
        self.assertFalse((self.tree / "app/deps").exists())
        self.assertEqual(list((self.tree / "app").glob(".workie-cache.*")), [])
