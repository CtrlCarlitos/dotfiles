"""Local incoming public-key authorization contract, shared by both shell twins.

Parsing/planning are read-only. Public identities are validated with OpenSSH;
comments never establish identity, and retained authorization options survive.
"""
from dataclasses import dataclass
from pathlib import Path
import base64
import hashlib
import re
import shlex
import subprocess
import os
import stat
import tempfile
import shutil
import uuid
import copy
import json
import tomllib
import glob


@dataclass(frozen=True)
class PublicKey:
    name: str
    key_type: str
    blob: str
    fingerprint: str
    source_line: str

    @property
    def identity(self):
        return self.key_type, self.blob


@dataclass(frozen=True)
class AuthorizedEntry:
    raw: str
    key: PublicKey
    options: tuple[str, ...]


@dataclass(frozen=True)
class AuthorizationPlan:
    desired: tuple[PublicKey, ...]
    retained: tuple[AuthorizedEntry, ...]
    additions: tuple[PublicKey, ...]
    removals: tuple[AuthorizedEntry, ...]
    text: str
    changed: bool


def _parse_line(line: str, name: str = "") -> AuthorizedEntry:
    tokens = shlex.shlex(line, posix=True)
    tokens.whitespace_split = True
    tokens.commenters = ""
    options = []
    try:
        kind = next(tokens)
        if not re.fullmatch(r"(?:ssh-|ecdsa-|sk-)[A-Za-z0-9@._+-]+", kind):
            options.append(kind)
            kind = next(tokens)
        blob = next(tokens)
        raw = base64.b64decode(blob, validate=True)
    except (ValueError, StopIteration) as error:
        raise ValueError("malformed public-key record") from error
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(raw).digest()).decode().rstrip("=")
    probe = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", "-"],
                           input=line + "\n", text=True, capture_output=True, timeout=15)
    fields = probe.stdout.split()
    if probe.returncode or len(fields) < 2 or fields[1] != fingerprint:
        raise ValueError("OpenSSH rejected a public-key record")
    return AuthorizedEntry(line, PublicKey(name, kind, blob, fingerprint, line), tuple(options))


def load_declared_keys(names: list[str], public_dir: Path) -> list[PublicKey]:
    if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
        raise ValueError("ssh.login_keys must be an explicit list (use [] to revoke all keys)")
    keys = {}
    for name in names:
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", name):
            raise ValueError(f"invalid public-key name: {name!r}")
        path = public_dir / (name + ".pub")
        _reject_links(path)
        if not stat.S_ISREG(path.stat().st_mode):
            raise ValueError(f"public source is not a regular file: {path}")
        lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        if len(lines) != 1 or lines[0].startswith("#"):
            raise ValueError(f"{name}.pub must contain exactly one public key")
        entry = _parse_line(lines[0], name)
        keys.setdefault(entry.key.identity, entry.key)
    return list(keys.values())


def parse_authorized(text: str) -> list[AuthorizedEntry]:
    entries = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            entries.append(_parse_line(line))
        except ValueError as error:
            raise ValueError(f"invalid authorization record at line {number}: {error}") from error
    return entries


def plan_authorization(desired: list[PublicKey], current_text: str) -> AuthorizationPlan:
    current = parse_authorized(current_text)
    wanted = {key.identity for key in desired}
    existing = {entry.key.identity for entry in current}
    retained = tuple(entry for entry in current if entry.key.identity in wanted)
    removals = tuple(entry for entry in current if entry.key.identity not in wanted)
    additions = tuple(key for key in desired if key.identity not in existing)
    if not additions and not removals:
        text = current_text
    else:
        keep = {entry.raw for entry in retained}
        lines = [line for line in current_text.splitlines()
                 if not line.strip() or line.lstrip().startswith("#") or line in keep]
        lines.extend(key.source_line for key in additions)
        text = "".join(line + "\n" for line in lines)
    return AuthorizationPlan(tuple(desired), retained, additions, removals, text, text != current_text)


def _reject_links(path: Path):
    # Refuse redirected endpoints while permitting OS-managed ancestor aliases
    # such as macOS /var -> /private/var (used by its temporary directory).
    for item in (path, path.parent):
        if item.is_symlink() or (item.exists() and getattr(item.lstat(), "st_file_attributes", 0) & 0x400):
            raise ValueError(f"refusing symlink/reparse path: {item}")


@dataclass(frozen=True)
class FileSnapshot:
    path: Path
    data: bytes | None
    metadata: os.stat_result | None

    @classmethod
    def read(cls, path: Path):
        _reject_links(path)
        if not path.exists():
            return cls(path, None, None)
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
            raise ValueError(f"not an independent regular file: {path}")
        return cls(path, path.read_bytes(), info)

    def check(self):
        now = FileSnapshot.read(self.path)
        if now.data != self.data or (now.metadata and self.metadata and
                (now.metadata.st_ino, now.metadata.st_mtime_ns, now.metadata.st_mode) !=
                (self.metadata.st_ino, self.metadata.st_mtime_ns, self.metadata.st_mode)):
            raise ValueError(f"file changed concurrently: {self.path}")


@dataclass(frozen=True)
class PermissionPolicy:
    platform: str
    user_sid: str = ""
    acl_helper: Path = Path(__file__).with_name("ssh_authorization_acl.ps1")

    def apply(self, path: Path, reference: FileSnapshot):
        if os.name == "nt":
            shell = shutil.which("pwsh") or shutil.which("powershell")
            if not shell:
                raise ValueError("PowerShell is required to secure authorization files")
            mode = "Copy" if self.platform == "copy" else ("Admin" if self.platform == "windows-admin" else "User")
            args = [shell, "-NoProfile", "-File", str(self.acl_helper), "-Path", str(path), "-Mode", mode]
            if reference.data is not None:
                args += ["-ReferencePath", str(reference.path)]
            if self.user_sid:
                args += ["-UserSid", self.user_sid]
            result = subprocess.run(args, text=True, capture_output=True, timeout=30)
            if result.returncode:
                raise OSError(f"could not secure {path}: {result.stderr.strip()}")
        else:
            if reference.metadata:
                info = path.stat()
                if (info.st_uid, info.st_gid) != (reference.metadata.st_uid, reference.metadata.st_gid):
                    os.chown(path, reference.metadata.st_uid, reference.metadata.st_gid)
            mode = stat.S_IMODE(reference.metadata.st_mode) if self.platform == "copy" and reference.metadata else 0o600
            path.chmod(mode)


class FileWriteError(OSError):
    def __init__(self, path, committed, backup, cause):
        self.path, self.committed, self.backup = path, committed, backup
        phase = 'after replacement' if committed else 'before replacement'
        super().__init__(f"write failed {phase}: {path}; backup: {backup}; {cause}")


def replace_authorization(snapshot: FileSnapshot, text: str, permissions: PermissionPolicy, before_replace=None) -> Path | None:
    snapshot.check()
    if before_replace:
        before_replace()
    data = text.encode("utf-8")
    path = snapshot.path
    if snapshot.data == data:
        permissions.apply(path, snapshot)
        if os.name != "nt" and permissions.platform != "copy":
            path.parent.chmod(0o700)
        return None
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name != "nt" and permissions.platform != "copy":
        path.parent.chmod(0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".remote-keys-", dir=path.parent)
    temporary = Path(temporary)
    backup = None
    committed = False
    try:
        os.close(descriptor)
        # Secure the staging file before it can hold configuration content.
        permissions.apply(temporary, snapshot)
        with temporary.open("wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if snapshot.data is not None:
            backup = path.with_name(path.name + ".remote-backup-" + uuid.uuid4().hex)
            backup.touch(mode=0o600, exist_ok=False)
            PermissionPolicy("copy", permissions.user_sid, permissions.acl_helper).apply(backup, snapshot)
            backup.write_bytes(snapshot.data)
        snapshot.check()
        if before_replace:
            before_replace()
        os.replace(temporary, path)
        committed = True
        if path.read_bytes() != data:
            raise OSError(f"authorization verification failed; backup: {backup}")
        return backup
    except Exception as error:
        raise FileWriteError(path, committed, backup, error) from error
    finally:
        temporary.unlink(missing_ok=True)


def contract_names(remote: dict) -> list[str]:
    if not isinstance(remote, dict):
        raise ValueError("remote_access is not configured")
    if "login_keys" in remote or any(isinstance(remote.get(os_name), dict) and
            any(field in remote[os_name] for field in ("ssh", "rdp")) for os_name in ("windows", "linux", "macos")):
        raise ValueError("obsolete remote_access schema: use ssh.enabled, ssh.login_keys and rdp.enabled; targets/generate were removed")
    ssh = remote.get("ssh", {})
    names = ssh.get("login_keys") if isinstance(ssh, dict) else None
    if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
        raise ValueError("ssh.login_keys must be explicitly configured as a list; [] revokes all keys")
    return names


def validate_sshd_config(path: Path, visited=None):
    """Unix routing check, including standard distro Include fragments."""
    if not path.exists():
        return
    visited = set() if visited is None else visited
    resolved = path.resolve()
    if resolved in visited or len(visited) >= 32:
        raise ValueError("recursive or excessive sshd Includes need manual review")
    visited.add(resolved)
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = shlex.split(line, comments=True)
        if not fields:
            continue
        directive, values = fields[0].lower(), fields[1:]
        if directive == 'include':
            for value in values:
                pattern = Path(value) if Path(value).is_absolute() else path.parent / value
                for included in sorted(glob.glob(str(pattern))):
                    validate_sshd_config(Path(included), visited)
        elif directive == 'authorizedkeysfile' and values != ['.ssh/authorized_keys']:
            raise ValueError('custom AuthorizedKeysFile is not managed by dot remote')
        elif directive in ('authorizedkeyscommand', 'trustedusercakeys') and values != ['none']:
            raise ValueError('custom SSH authorization source is not managed by dot remote')
    visited.remove(resolved)


def remove_key_declaration(text: str, name: str) -> str:
    document = tomllib.loads(text)
    remote = document.get("data", {}).get("remote_access", {})
    names = contract_names(remote)
    if name not in names:
        raise ValueError(f"key is not declared: {name}")
    expected = copy.deepcopy(document)
    remaining = [entry for entry in names if entry != name]
    expected["data"]["remote_access"]["ssh"]["login_keys"] = remaining
    header = re.search(r"(?m)^[ \t]*\[data\.remote_access\.ssh\][ \t]*(?:#[^\r\n]*)?\r?$", text)
    if not header:
        raise ValueError("use an explicit [data.remote_access.ssh] TOML table")
    match = re.search(r"(?m)^[ \t]*login_keys[ \t]*=[ \t]*\[", text[header.end():])
    if not match:
        raise ValueError("cannot locate ssh.login_keys array safely")
    start = header.end() + match.end() - 1
    quote = None
    escaped = False
    comment = False
    end = None
    for index in range(start + 1, len(text)):
        char = text[index]
        if comment:
            if char == "\n": comment = False
        elif quote:
            if escaped: escaped = False
            elif char == "\\" and quote == '"': escaped = True
            elif char == quote: quote = None
        elif char in "\"'": quote = char
        elif char == "#": comment = True
        elif char == "]":
            end = index + 1
            break
    if end is None:
        raise ValueError("cannot locate end of ssh.login_keys")
    result = text[:start] + json.dumps(remaining) + text[end:]
    if tomllib.loads(result) != expected:
        raise ValueError("TOML edit would change unrelated configuration; refused")
    return result


def apply_removal(config: FileSnapshot, authorization: FileSnapshot, name: str,
                  public_dir: Path, policy: PermissionPolicy, effective_names: list[str]) -> AuthorizationPlan:
    if config.data is None:
        raise ValueError("configuration file does not exist")
    original = config.data.decode("utf-8")
    if contract_names(tomllib.loads(original).get("data", {}).get("remote_access")) != effective_names:
        raise ValueError("effective configuration differs from the local TOML declaration")
    updated = remove_key_declaration(original, name)
    names = contract_names(tomllib.loads(updated)["data"]["remote_access"])
    plan = plan_authorization(load_declared_keys(names, public_dir), (authorization.data or b"").decode("utf-8"))
    config.check()
    authorization.check()
    backup = config_backup = None
    auth_committed = config_committed = False
    copy_policy = PermissionPolicy("copy", policy.user_sid, policy.acl_helper)
    try:
        try:
            backup = replace_authorization(authorization, plan.text, policy, before_replace=config.check)
            auth_committed = authorization.data != plan.text.encode('utf-8')
        except FileWriteError as error:
            backup, auth_committed = error.backup, error.committed
            raise
        written = FileSnapshot.read(authorization.path)
        if written.data != plan.text.encode('utf-8'):
            raise ValueError('authorization changed concurrently after replacement')
        try:
            config_backup = replace_authorization(config, updated, copy_policy, before_replace=written.check)
            config_committed = True
        except FileWriteError as error:
            config_backup, config_committed = error.backup, error.committed
            raise
        written.check()
        if config.path.read_bytes() != updated.encode('utf-8'):
            raise ValueError('configuration changed concurrently after replacement')
    except BaseException as error:
        failures = []
        for original, expected, changed in ((config, updated.encode('utf-8'), config_committed),
                                            (authorization, plan.text.encode('utf-8'), auth_committed)):
            if not changed:
                continue
            try:
                now = FileSnapshot.read(original.path)
                if now.data == original.data:
                    continue
                if now.data != expected:
                    raise ValueError(f'concurrent edit preserved: {original.path}')
                if original.data is None:
                    now.check()
                    original.path.unlink(missing_ok=True)
                else:
                    replace_authorization(now, original.data.decode('utf-8'), copy_policy)
            except BaseException as recovery:
                failures.append(str(recovery))
        state = 'PARTIAL removal; recovery failed: ' + '; '.join(failures) if failures else 'removal failed; own content changes restored'
        raise OSError(f'{state}; authorization backup: {backup}; configuration backup: {config_backup}; cause: {error}') from error
    if backup: print(f"Authorization backup: {backup}")
    if config_backup: print(f"Configuration backup: {config_backup}")
    return plan
