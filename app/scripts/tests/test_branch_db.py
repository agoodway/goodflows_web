"""Run with python3 -m unittest discover -s scripts/tests (no database needed)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BranchDatabaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / "app"
        shutil.copytree(Path(__file__).resolve().parents[1], self.app / "scripts")
        (self.app / "deps").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        for command in ["mix", "createdb", "dropdb", "psql"]:
            stub = self.bin / command
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "' + command + ' $*" >> "$CALL_LOG"\n')
            stub.chmod(0o755)
        subprocess.run(["git", "init", "-b", "feat/clinical-review", str(self.root)],
                       check=True, capture_output=True)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", CALL_LOG=str(self.log))

    def run_script(self, name):
        return subprocess.run(["bash", str(self.app / "scripts" / name)],
                              env=self.env, capture_output=True, text=True)

    def test_setup_preserves_settings_and_reuses_saved_identifier(self):
        (self.app / ".env.dev.local").write_text("PORT=7901\nPOOL_SIZE=30\n")
        result = self.run_script("setup_branch_db.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        for filename in [".env.dev.local", ".env.test.local"]:
            self.assertIn("BRANCH_DB=clinical_review", (self.app / filename).read_text())
        self.assertIn("PORT=7901", (self.app / ".env.dev.local").read_text())
        self.assertIn("POOL_SIZE=30", (self.app / ".env.dev.local").read_text())
        self.assertFalse((self.app / ".branch").exists())
        subprocess.run(["git", "-C", str(self.root), "branch", "-m", "feat/verify-insurance"], check=True)
        self.assertEqual(self.run_script("setup_branch_db.sh").returncode, 0)
        self.assertEqual((self.app / ".env.test.local").read_text().count("BRANCH_DB="), 1)
        self.assertEqual(self.run_script("cleanup_branch_db.sh").returncode, 0)
        self.assertIn("dropdb --if-exists --force good_flows_clinical_review_dev", self.log.read_text())

    def test_cleanup_reads_quoted_identifier_without_executing_env(self):
        (self.app / ".env.dev.local").write_text('export BRANCH_DB="clinical_review"\nSECRET=$(touch unexpected)\n')
        (self.app / ".env.test.local").write_text("BRANCH_DB='clinical_review'\n")
        result = self.run_script("cleanup_branch_db.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("good_flows_clinical_review_test", self.log.read_text())
        self.assertFalse((self.app / "unexpected").exists())

    def test_main_server_forces_default_port_and_worktree_preserves_override(self):
        (self.bin / "mix").write_text('#!/bin/sh\nprintf "%s" "$PORT" > "$CALL_LOG"\n')
        self.env["PORT"] = "9000"
        result = self.run_script("start_dev.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(), "4000")
        (self.app / ".env.dev.local").write_text("BRANCH_DB=clinical_review\nPORT=7901\n")
        result = self.run_script("start_dev.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(), "9000")
        self.env.pop("PORT")
        result = self.run_script("start_dev.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(), "7901")

    def test_dev_port_follows_up_without_executing_env(self):
        self.env.pop("PORT", None)
        result = self.run_script("dev_port.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "4000\n")
        self.env["PORT"] = "9000"
        self.assertEqual(self.run_script("dev_port.sh").stdout, "4000\n")

        (self.app / ".env").write_text("PORT=4100\n")
        (self.app / ".env.local").write_text("PORT=4101 # ignored\n")
        (self.app / ".env.dev").write_text('export PORT="4102"\n')
        (self.app / ".env.dev.local").write_text(
            "BRANCH_DB=clinical_review\nPORT=7901\nSECRET=$(touch unexpected)\n"
        )
        self.env.pop("PORT")
        result = self.run_script("dev_port.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "7901\n")
        self.assertFalse((self.app / "unexpected").exists())

        (self.app / ".env.dev.local").write_text("BRANCH_DB=clinical_review\n")
        self.assertEqual(self.run_script("dev_port.sh").stdout, "4102\n")
        (self.app / ".env.dev").unlink()
        self.assertEqual(self.run_script("dev_port.sh").stdout, "4101\n")
        (self.app / ".env.local").unlink()
        self.assertEqual(self.run_script("dev_port.sh").stdout, "4100\n")
        (self.app / ".env").unlink()
        self.assertEqual(self.run_script("dev_port.sh").stdout, "4000\n")

        self.env["PORT"] = "9000"
        self.assertEqual(self.run_script("dev_port.sh").stdout, "9000\n")
        self.env.pop("PORT")
        (self.app / ".env.dev.local").write_text(
            "BRANCH_DB='clinical_review'\nPORT=1111\nexport PORT='7902'\n"
        )
        self.assertEqual(self.run_script("dev_port.sh").stdout, "7902\n")
        (self.app / ".env.dev.local").write_text("BRANCH_DB=../bad\nPORT=7901\n")
        result = self.run_script("dev_port.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_setup_retries_interrupted_fallback_initialization(self):
        (self.bin / "createdb").write_text('#!/bin/sh\n[ "$1" != "-T" ]\n')
        (self.bin / "psql").write_text('#!/bin/sh\n[ "${DB_EXISTS:-0}" != "1" ] || echo 1\n')
        (self.bin / "mix").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n'
            'if [ "${FAIL_STEP:-}" = "$*" ]; then exit 1; fi\n'
        )
        for failed_step in ["ecto.migrate", "run priv/repo/seeds.exs"]:
            with self.subTest(failed_step=failed_step):
                self.env["DB_EXISTS"] = "0"
                self.env["FAIL_STEP"] = failed_step
                self.assertNotEqual(self.run_script("setup_branch_db.sh").returncode, 0)
                self.env["DB_EXISTS"] = "1"
                self.env.pop("FAIL_STEP")
                self.log.write_text("")
                result = self.run_script("setup_branch_db.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("run priv/repo/seeds.exs", self.log.read_text())
                self.log.write_text("")
                self.assertEqual(self.run_script("setup_branch_db.sh").returncode, 0)
                self.assertNotIn("run priv/repo/seeds.exs", self.log.read_text())

    def test_cleanup_without_identifier_does_nothing(self):
        self.assertEqual(self.run_script("cleanup_branch_db.sh").returncode, 0)
        self.assertFalse(self.log.exists())

    def test_cleanup_rejects_invalid_or_conflicting_identifiers(self):
        for dev, test in [("clinical_review", "verify_insurance"), ("", ""), ("../bad", "../bad")]:
            with self.subTest(dev=dev, test=test):
                (self.app / ".env.dev.local").write_text(f"BRANCH_DB={dev}\n")
                (self.app / ".env.test.local").write_text(f"BRANCH_DB={test}\n")
                self.assertNotEqual(self.run_script("cleanup_branch_db.sh").returncode, 0)
                self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
