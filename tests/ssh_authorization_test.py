"""Incoming authorization contract tests; disposable public-key fixtures only."""
import pathlib
import os
import json
import io
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
try:
    import ssh_authorization as auth
except ModuleNotFoundError as error:
    if error.name != "ssh_authorization":
        raise
    auth = None


class AuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.public = {}
        for name in ("a", "b"):
            key = pathlib.Path(cls.fixture.name) / name
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", str(key)], check=True)
            cls.public[name] = key.with_suffix(".pub").read_text().strip()
            key.unlink()

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.assertIsNotNone(auth, "authorization implementation is missing")
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = pathlib.Path(self.scratch.name)
        for name, line in self.public.items():
            (self.directory / f"{name}.pub").write_text(line + "\n")

    def keys(self, names):
        return auth.load_declared_keys(names, self.directory)

    def test_add_missing(self):
        plan = auth.plan_authorization(self.keys(["a"]), "")
        self.assertEqual(plan.text, self.public["a"] + "\n")
        self.assertEqual(len(plan.additions), 1)
        self.assertTrue(plan.changed)

    def test_revoke_undeclared_manual_key(self):
        plan = auth.plan_authorization(self.keys(["a"]), self.public["a"] + "\n" + self.public["b"] + "\n")
        self.assertEqual(plan.text, self.public["a"] + "\n")
        self.assertEqual(len(plan.removals), 1)

    def test_empty_list_revokes_all(self):
        plan = auth.plan_authorization(self.keys([]), self.public["a"] + "\n")
        self.assertEqual(plan.text, "")
        self.assertEqual(len(plan.removals), 1)

    def test_missing_list_refused(self):
        for value in (None, "a", {"a": True}, [3]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.keys(value)

    def test_missing_or_invalid_source_preserves_input(self):
        (self.directory / "invalid.pub").write_text("not a public key\n")
        for name in ("missing", "invalid", "../a", "a/b", "a\\b"):
            with self.subTest(name=name), self.assertRaises((ValueError, OSError)):
                self.keys(["a", name])
        self.assertEqual((self.directory / "a.pub").read_text(), self.public["a"] + "\n")

    def test_comment_change_does_not_duplicate(self):
        original = self.public["a"].rsplit(" ", 1)[0] + " old-comment\n"
        plan = auth.plan_authorization(self.keys(["a"]), original)
        self.assertEqual(plan.text, original)
        self.assertFalse(plan.changed)

    def test_retained_options_preserved(self):
        original = 'command="echo hello world",from="10.0.0.*",no-pty ' + self.public["a"] + "\n"
        self.assertEqual(auth.plan_authorization(self.keys(["a"]), original).text, original)

    def test_multiple_entries_for_same_identity_preserve_restrictions(self):
        original = 'from="10.0.0.*" ' + self.public["a"] + '\nfrom="192.168.1.*" ' + self.public["a"] + "\n"
        self.assertEqual(auth.plan_authorization(self.keys(["a", "a"]), original).text, original)

    def test_comments_do_not_count_as_keys(self):
        self.assertEqual(auth.parse_authorized("# comment\n\n"), [])

    def test_custom_authorization_route_refused(self):
        self.assertTrue(hasattr(auth, 'validate_sshd_config'), 'sshd route validation is missing')
        config = self.directory / 'sshd_config'
        config.write_text('AuthorizedKeysFile /different/keys\n')
        with self.assertRaises(ValueError):
            auth.validate_sshd_config(config)

    def test_standard_include_can_be_checked(self):
        self.assertTrue(hasattr(auth, 'validate_sshd_config'), 'sshd route validation is missing')
        config = self.directory / 'sshd_config'
        included = self.directory / 'extra.conf'
        included.write_text('PasswordAuthentication yes\n')
        config.write_text(f'Include "{included.as_posix()}"\nAuthorizedKeysFile .ssh/authorized_keys\n')
        auth.validate_sshd_config(config)
        included.write_text('AuthorizedKeysCommand /custom/lookup\n')
        with self.assertRaises(ValueError):
            auth.validate_sshd_config(config)

    def test_malformed_existing_record_refused(self):
        with self.assertRaises(ValueError):
            auth.plan_authorization(self.keys([]), "unknown invalid line\n")

    def test_private_key_not_required(self):
        self.assertFalse((self.directory / "a").exists())
        self.assertEqual(len(self.keys(["a"])), 1)

    @unittest.skipIf(os.name == 'nt', 'Unix symlink fixture; Windows reparse handling is enforced by the same endpoint check')
    def test_public_source_symlink_refused(self):
        path = self.directory / 'a.pub'
        path.unlink()
        path.symlink_to(self.directory / 'b.pub')
        with self.assertRaises(ValueError):
            self.keys(['a'])

    def test_multiple_public_keys_in_source_refused(self):
        (self.directory / "a.pub").write_text(self.public["a"] + "\n" + self.public["b"] + "\n")
        with self.assertRaises(ValueError):
            self.keys(["a"])

    def snapshot(self, path):
        self.assertTrue(hasattr(auth, "FileSnapshot"), "recoverable writer is missing")
        return auth.FileSnapshot.read(path)

    def policy(self):
        return auth.PermissionPolicy("unix" if os.name != "nt" else "windows-user")

    def test_writer_keeps_backup_and_noop_mtime(self):
        path = self.directory / "authorized_keys"
        path.write_text(self.public["b"] + "\n")
        backup = auth.replace_authorization(self.snapshot(path), self.public["a"] + "\n", self.policy())
        self.assertEqual(backup.read_text(), self.public["b"] + "\n")
        stamp = path.stat().st_mtime_ns
        self.assertIsNone(auth.replace_authorization(self.snapshot(path), path.read_text(), self.policy()))
        self.assertEqual(path.stat().st_mtime_ns, stamp)

    def test_stale_authorization_refused(self):
        path = self.directory / "authorized_keys"
        path.write_text("old\n")
        snapshot = self.snapshot(path)
        path.write_text("edited concurrently\n")
        with self.assertRaises(ValueError):
            auth.replace_authorization(snapshot, "replacement\n", self.policy())
        self.assertEqual(path.read_text(), "edited concurrently\n")

    def test_write_failure_keeps_previous_authorization(self):
        path = self.directory / "authorized_keys"
        path.write_text("old\n")
        snapshot = self.snapshot(path)
        with patch.object(auth.os, "replace", side_effect=OSError("fixture replacement failure")):
            with self.assertRaises(OSError):
                auth.replace_authorization(snapshot, "new\n", self.policy())
        self.assertEqual(path.read_text(), "old\n")

    @unittest.skipIf(os.name == "nt", "POSIX metadata is covered by the Unix twin")
    def test_unix_modes_and_owner(self):
        path = self.directory / "authorized_keys"
        path.write_text("old\n")
        path.chmod(0o644)
        owner = path.stat().st_uid
        auth.replace_authorization(self.snapshot(path), "new\n", self.policy())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.stat().st_uid, owner)

    def test_remove_declaration_preserves_unrelated_toml(self):
        text = '# keep\n[data.remote_access.ssh]\nenabled = true\nlogin_keys = [\n "a", # phone\n "b",\n]\n[data.other]\nvalue = "unchanged"\n'
        self.assertTrue(hasattr(auth, "remove_key_declaration"), "TOML removal is missing")
        import tomllib
        result = auth.remove_key_declaration(text, "a")
        self.assertEqual(tomllib.loads(result)["data"]["remote_access"]["ssh"]["login_keys"], ["b"])
        self.assertIn('[data.other]\nvalue = "unchanged"', result)
        self.assertIn('# keep', result)
        with self.assertRaises(ValueError):
            auth.remove_key_declaration(text, "unknown")

    def test_remove_last_declaration(self):
        self.assertTrue(hasattr(auth, "remove_key_declaration"), "TOML removal is missing")
        result = auth.remove_key_declaration('[data.remote_access.ssh]\nlogin_keys = ["a"]\n', "a")
        self.assertIn('login_keys = []', result)

    def cli(self, action, *extra, names=None):
        if '--config' not in extra:
            config = self.directory / 'contract.toml'
            config.write_text('[data.remote_access.ssh]\nlogin_keys = ' + json.dumps(names if names is not None else ['a']) + '\n')
            extra = (*extra, '--config', str(config))
        return subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/remote_keys.py'), action,
            '--public-key-dir', str(self.directory), '--authorized-keys', str(self.directory / 'authorized_keys'),
            '--platform', 'windows-user' if os.name == 'nt' else 'unix', *extra],
            input=json.dumps({'enabled': True, 'ssh': {'enabled': True, 'login_keys': names if names is not None else ['a']}}),
            text=True, capture_output=True)

    def test_cli_status_is_read_only_then_sync_revokes(self):
        path = self.directory / 'authorized_keys'
        path.write_text(self.public['b'] + '\n')
        before = path.read_bytes()
        result = self.cli('status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), before)
        result = self.cli('sync')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), self.public['a'] + '\n')

    def test_cli_accepts_utf8_bom_independent_of_python_console_encoding(self):
        arguments = [sys.executable, '-B', str(ROOT / 'scripts/remote_keys.py'), 'status',
            '--public-key-dir', str(self.directory), '--authorized-keys', str(self.directory / 'authorized_keys'),
            '--platform', 'windows-user' if os.name == 'nt' else 'unix']
        payload = b'\xef\xbb\xbf' + json.dumps({'ssh': {'login_keys': []}}).encode('utf-8')
        result = subprocess.run(arguments, input=payload, capture_output=True,
            env={**os.environ, 'PYTHONIOENCODING': 'cp1252'})
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    def test_cli_remove_without_removed_public_file(self):
        path = self.directory / 'authorized_keys'
        path.write_text(self.public['a'] + '\n' + self.public['b'] + '\n')
        (self.directory / 'a.pub').unlink()
        config = self.directory / 'chezmoi.toml'
        config.write_text('[data.remote_access.ssh]\nenabled = true\nlogin_keys = ["a", "b"]\n')
        result = self.cli('remove', 'a', '--config', str(config), names=['a', 'b'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), self.public['b'] + '\n')
        import tomllib
        self.assertEqual(tomllib.loads(config.read_text())['data']['remote_access']['ssh']['login_keys'], ['b'])

    def test_remove_recovers_authorization_if_config_write_fails(self):
        self.assertTrue(hasattr(auth, 'apply_removal'), 'two-file removal is missing')
        path = self.directory / 'authorized_keys'
        before = self.public['a'] + '\n' + self.public['b'] + '\n'
        path.write_text(before)
        config = self.directory / 'chezmoi.toml'
        original = '[data.remote_access.ssh]\nlogin_keys = ["a", "b"]\n'
        config.write_text(original)
        replace = os.replace
        def fail_config(source, destination):
            if pathlib.Path(destination) == config:
                raise OSError('fixture config replacement failure')
            return replace(source, destination)
        with patch.object(auth.os, 'replace', side_effect=fail_config):
            with self.assertRaises(OSError):
                auth.apply_removal(self.snapshot(config), self.snapshot(path), 'a', self.directory, self.policy(), ['a', 'b'])
        self.assertEqual(path.read_text(), before)
        self.assertEqual(config.read_text(), original)

    def test_remove_detects_concurrent_edit_between_files(self):
        path = self.directory / 'authorized_keys'
        path.write_text(self.public['a'] + '\n' + self.public['b'] + '\n')
        config = self.directory / 'chezmoi.toml'
        original = '[data.remote_access.ssh]\nlogin_keys = ["a", "b"]\n'
        config.write_text(original)
        writer = auth.replace_authorization
        def edit_after_write(snapshot, text, policy, **kwargs):
            result = writer(snapshot, text, policy, **kwargs)
            if snapshot.path == path:
                path.write_text('# concurrent editor\n')
            return result
        with patch.object(auth, 'replace_authorization', side_effect=edit_after_write):
            with self.assertRaises((ValueError, OSError)):
                auth.apply_removal(self.snapshot(config), self.snapshot(path), 'a', self.directory, self.policy(), ['a', 'b'])
        self.assertEqual(path.read_text(), '# concurrent editor\n')
        self.assertEqual(config.read_text(), original)

    def test_sync_rejects_configuration_changed_during_planning(self):
        path = self.directory / 'authorized_keys'
        before = self.public['a'] + '\n'
        path.write_text(before)
        config = self.directory / 'contract.toml'
        config.write_text('[data.remote_access.ssh]\nlogin_keys = []\n')
        spec = importlib.util.spec_from_file_location('remote_keys_under_test', ROOT / 'scripts/remote_keys.py')
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        loader = cli.load_declared_keys
        def changed(names, directory):
            config.write_text('[data.remote_access.ssh]\nlogin_keys = ["a"]\n')
            return loader(names, directory)
        arguments = ['remote_keys', 'sync', '--config', str(config), '--authorized-keys', str(path),
                     '--public-key-dir', str(self.directory), '--platform', self.policy().platform]
        stream = io.TextIOWrapper(io.BytesIO(b'{"ssh":{"login_keys":[]}}'), encoding='utf-8')
        with patch.object(sys, 'argv', arguments), patch.object(sys, 'stdin', stream), patch.object(cli, 'load_declared_keys', side_effect=changed):
            with self.assertRaises((ValueError, OSError)):
                cli.main()
        self.assertEqual(path.read_text(), before)

    def test_remove_detects_edit_during_config_staging(self):
        path = self.directory / 'authorized_keys'
        before = self.public['a'] + '\n'
        path.write_text(before)
        config = self.directory / 'contract.toml'
        original = '[data.remote_access.ssh]\nlogin_keys = ["a"]\n'
        config.write_text(original)
        apply = auth.PermissionPolicy.apply
        edited = []
        def external_edit(policy, target, reference):
            apply(policy, target, reference)
            if reference.path == config and not edited:
                edited.append(True)
                path.write_text(before)
        with patch.object(auth.PermissionPolicy, 'apply', new=external_edit):
            with self.assertRaises((ValueError, OSError)):
                auth.apply_removal(self.snapshot(config), self.snapshot(path), 'a', self.directory, self.policy(), ['a'])
        self.assertEqual(path.read_text(), before)
        self.assertEqual(config.read_text(), original)

    def test_remove_recovers_both_files_after_config_verification_read_fails(self):
        path = self.directory / 'authorized_keys'
        before = self.public['a'] + '\n'
        path.write_text(before)
        config = self.directory / 'contract.toml'
        original = '[data.remote_access.ssh]\nlogin_keys = ["a"]\n'
        updated = '[data.remote_access.ssh]\nlogin_keys = []\n'
        config.write_text(original)
        read_bytes = pathlib.Path.read_bytes
        failed = []
        def transient_failure(target):
            data = read_bytes(target)
            if target == config and data.decode().replace('\r\n', '\n') == updated and not failed:
                failed.append(True)
                raise OSError('fixture post-replacement read failure')
            return data
        with patch.object(pathlib.Path, 'read_bytes', new=transient_failure):
            with self.assertRaises(OSError):
                auth.apply_removal(self.snapshot(config), self.snapshot(path), 'a', self.directory, self.policy(), ['a'])
        self.assertEqual(path.read_text(), before)
        self.assertEqual(config.read_text(), original)


if __name__ == "__main__":
    unittest.main()
