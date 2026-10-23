import os
import stat
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class T3LifecycleContractTests(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_install_copies_t3_provider(self) -> None:
        install = self.read("install.sh")
        self.assertIn('"$source_dir/provider/t3"', install)
        self.assertIn('"$app_dir/provider/t3"', install)
        self.assertIn("dockrail-t3-provider", install)
        self.assertIn("install_client_bundle", install)

    def test_install_client_bundle_ships_pairing_cli(self) -> None:
        install = self.read("install.sh")
        self.assertIn("scripts/dockrail_t3.py", install)
        self.assertIn("dockrail_paths.py", install)

    def test_ci_runs_t3_provider_tests(self) -> None:
        ci = self.read(".github/workflows/ci.yml")
        self.assertIn("provider/t3/tests", ci)

    def test_dockrail_dispatches_t3(self) -> None:
        dockrail = self.read("scripts/dockrail")
        self.assertIn("t3)", dockrail)
        self.assertIn("dockrail_t3.py", dockrail)

    def test_provider_entry_is_executable(self) -> None:
        provider = ROOT / "provider" / "t3" / "bin" / "dockrail-t3-provider"
        self.assertTrue(provider.exists())
        self.assertTrue(os.access(provider, os.X_OK))
        self.assertNotEqual(stat.S_IMODE(os.stat(provider).st_mode) & 0o111, 0)

    def test_cli_and_provider_keep_token_off_argv(self) -> None:
        cli = self.read("scripts/dockrail_t3.py")
        self.assertIn("capture_output=True", cli)
        stdout_uses = [
            line.strip()
            for line in cli.splitlines()
            if "completed.stdout" in line or "completed.stderr" in line
        ]
        self.assertEqual(stdout_uses, ["pairing = json.loads(completed.stdout)"])
        provider = self.read("provider/t3/bin/dockrail-t3-provider")
        self.assertIn("connection-file", provider)
        self.assertIn("--proc-root", provider)


if __name__ == "__main__":
    unittest.main()
