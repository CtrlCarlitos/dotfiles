"""Fixtures only: no real configuration or keys are read."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sync", ROOT / "scripts/ssh_fingerprints.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class FingerprintTests(unittest.TestCase):
    text = '''# retain me
[data.packages]
core = true
[[data.accounts]] # account
username = "a"
key = "id_a"
email = "a@example.test"
[[data.ssh_hosts]]
name = "server"
hostname = "example.test"
identity = "id_server"
[data.remote_access]
enabled = false
'''

    def test_preserves_unrelated_and_idempotent(self):
        accounts = {("github", "a"): {"auth_fingerprint": "SHA256:a", "signing_fingerprint": "SHA256:b"}}
        hosts = {"id_server": "SHA256:c"}
        result = sync.update_text(self.text, accounts, hosts)
        self.assertIn("# retain me", result)
        self.assertIn("# account", result)
        self.assertEqual(tomllib.loads(result)["data"]["remote_access"], {"enabled": False})
        self.assertEqual(sync.update_text(result, accounts, hosts), result)
        self.assertEqual(tomllib.loads(result)["data"]["ssh_hosts"][0]["identity_fingerprint"], "SHA256:c")

    def test_unknown_mapping_refused(self):
        with self.assertRaises(ValueError):
            sync.update_text(self.text, {}, {})

    def test_crlf_and_fingerprint_comment_preserved(self):
        text = self.text.replace('email = "a@example.test"', 'email = "a@example.test"\nauth_fingerprint = "SHA256:old" # account selector').replace("\n", "\r\n")
        accounts = {("github", "a"): {"auth_fingerprint": "SHA256:new", "signing_fingerprint": "SHA256:sign"}}
        result = sync.update_text(text, accounts, {"id_server": "SHA256:host"})
        self.assertIn('"SHA256:new" # account selector\r\n', result)
        self.assertNotIn("\n", result.replace("\r\n", ""))

    def test_collect_roles_and_shared_host_identity(self):
        config = tomllib.loads(self.text)
        config["data"]["accounts"][0]["signingKey"] = "id_sign"
        with patch.object(sync, "run", side_effect=["256 SHA256:auth x\n256 SHA256:sign x\n4096 SHA256:host x", "256 SHA256:auth x", "256 SHA256:sign x", "4096 SHA256:host x"]):
            accounts, hosts = sync.collect(config, Path("fixture"), "keygen", "agent")
        self.assertEqual(accounts[("github", "a")], {"auth_fingerprint": "SHA256:auth", "signing_fingerprint": "SHA256:sign"})
        self.assertEqual(hosts, {"id_server": "SHA256:host"})

    def test_not_loaded_refused(self):
        with patch.object(sync, "run", side_effect=["256 SHA256:other comment", "256 SHA256:missing comment"]):
            with self.assertRaises(ValueError):
                sync.collect(tomllib.loads(self.text), Path("fixture"), "keygen", "agent")

    def test_selector_hashes_blob_not_comment(self):
        import base64
        import hashlib
        blob = base64.b64encode(b"fixture-public-blob").decode()
        fp = "SHA256:" + base64.b64encode(hashlib.sha256(b"fixture-public-blob").digest()).decode().rstrip("=")
        result = subprocess.run([sys.executable, str(ROOT / "dot_local/lib/ssh_agent_key.py"), fp, "blob"], input=f"ssh-ed25519 {blob} changed-comment\n", text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), blob)


if __name__ == "__main__":
    unittest.main()
