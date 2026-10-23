import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "provider" / "t3" / "tests"))

from fake_t3 import FakeT3

TOKEN = "cli-token-xyz"
ENV = "00000000-0000-4000-8000-000000000001"
CLI = ROOT / "scripts" / "dockrail_t3.py"


def make_env(home: Path, bin_dir: Path, t3_home: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env.pop("XDG_DATA_HOME", None)
    env["T3CODE_HOME"] = str(t3_home)
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    return env


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False)
        )
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.t3home = self.tmp / "t3home"
        (self.t3home / "userdata").mkdir(parents=True)
        (self.t3home / "userdata" / "environment-id").write_text(ENV)
        self.env = make_env(self.home, self.bin, self.t3home)
        self.fake: FakeT3 | None = None

    def tearDown(self) -> None:
        if self.fake is not None:
            self.fake.stop()
            self.fake = None

    def write_fake_t3(self, credential: str = "cred-1") -> None:
        script = self.bin / "t3"
        script.write_text(
            "#!/bin/sh\n"
            f'printf \'%s\' \'{{"credential":"{credential}","expiresAt":"2030-01-01T00:00:00Z"}}\'\n'
        )
        script.chmod(0o755)

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-B", str(CLI), *args],
            capture_output=True,
            text=True,
            timeout=60,
            env=self.env,
        )

    def conn_path(self) -> Path:
        return self.home / ".local" / "share" / "dockrail" / "t3" / "connection.json"

    def start_fake(self, **kwargs) -> FakeT3:
        self.fake = FakeT3(token=TOKEN, environment_id=ENV, **kwargs).start()
        return self.fake

    def test_pair_writes_0600_and_hides_token(self) -> None:
        self.write_fake_t3()
        fake = self.start_fake()
        result = self.run_cli("pair", "--url", fake.url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Paired with T3 Code", result.stdout)
        self.assertNotIn(TOKEN, result.stdout)
        self.assertNotIn(TOKEN, result.stderr)
        self.assertNotIn("cred-1", result.stdout + result.stderr)
        target = self.conn_path()
        self.assertTrue(target.exists())
        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o600)
        record = json.loads(target.read_bytes())
        self.assertEqual(record["version"], 1)
        self.assertEqual(record["environmentId"], ENV)
        self.assertEqual(record["url"], fake.url)
        self.assertEqual(record["token"], TOKEN)
        self.assertGreater(record["expiresAt"], record["pairedAt"])

    def test_pair_json(self) -> None:
        self.write_fake_t3()
        fake = self.start_fake()
        result = self.run_cli("pair", "--url", fake.url, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["environmentId"], ENV)
        self.assertNotIn(TOKEN, result.stdout)

    def test_pair_environment_mismatch_refuses(self) -> None:
        self.write_fake_t3()
        fake = self.start_fake()
        (self.t3home / "userdata" / "environment-id").write_text("other-env")
        result = self.run_cli("pair", "--url", fake.url)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.conn_path().exists())

    def test_pair_without_t3_cli(self) -> None:
        fake = self.start_fake()
        env = make_env(self.home, self.bin, self.t3home)
        env["PATH"] = str(self.bin)
        result = subprocess.run(
            [sys.executable, "-B", str(CLI), "pair", "--url", fake.url],
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("t3", result.stderr)

    def test_status_flow(self) -> None:
        result = self.run_cli("status", "--json")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.write_fake_t3()
        fake = self.start_fake()
        paired = self.run_cli("pair", "--url", fake.url, "--json")
        self.assertEqual(paired.returncode, 0)
        status = self.run_cli("status", "--json")
        self.assertEqual(status.returncode, 0, status.stderr)
        payload = json.loads(status.stdout)
        self.assertTrue(payload["paired"])
        self.assertEqual(payload["environmentId"], ENV)
        self.assertNotIn(TOKEN, status.stdout)

    def test_status_rejects_untrusted_and_invalid_connection(self) -> None:
        self.write_fake_t3()
        fake = self.start_fake()
        self.assertEqual(self.run_cli("pair", "--url", fake.url).returncode, 0)
        target = self.conn_path()
        target.chmod(0o644)
        rejected = self.run_cli("status", "--json")
        self.assertEqual(rejected.returncode, 1)
        self.assertEqual(json.loads(rejected.stdout)["reason"], "store_untrusted")
        target.chmod(0o600)
        record = json.loads(target.read_text())
        record.pop("token")
        target.write_text(json.dumps(record))
        malformed = self.run_cli("status", "--json")
        self.assertEqual(malformed.returncode, 1)
        self.assertEqual(json.loads(malformed.stdout)["reason"], "store_invalid")

    def test_unpair_deletes_and_hints_revoke(self) -> None:
        self.write_fake_t3()
        fake = self.start_fake()
        self.assertEqual(self.run_cli("pair", "--url", fake.url).returncode, 0)
        result = self.run_cli("unpair")
        self.assertEqual(result.returncode, 0)
        self.assertIn("revoke", result.stdout)
        self.assertFalse(self.conn_path().exists())
        again = self.run_cli("unpair", "--json")
        self.assertEqual(again.returncode, 0)
        self.assertTrue(json.loads(again.stdout)["ok"])
        status = self.run_cli("status", "--json")
        self.assertEqual(status.returncode, 1)


if __name__ == "__main__":
    unittest.main()
