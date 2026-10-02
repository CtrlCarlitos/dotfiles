#!/usr/bin/env python3
"""Explicit Windows fingerprint synchronization; preview unless --write is given.

Reads configured Windows public keys and confirms them against the Windows agent.
Patches fingerprint fields only, preserving the surrounding TOML and comments.
An optional --target-config applies the same mapping to existing WSL definitions.
Requires Python 3.11+. Never reads private keys, loads keys, or creates WSL .pub files.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=15)


def account_id(account):
    if not account.get("username"):
        raise ValueError("account with a key must have a username")
    return (account.get("provider", "github"), account["username"])


def collect(config, ssh_dir, keygen, ssh_add):
    loaded = set(re.findall(r"SHA256:[A-Za-z0-9+/]+", run(ssh_add, "-l", "-E", "sha256")))
    cache = {}

    def fingerprint(name):
        if not name or Path(name).name != name or "/" in name or "\\" in name:
            raise ValueError(f"expected a key filename, got {name!r}")
        if name not in cache:
            public = ssh_dir / (name + ".pub")
            match = re.search(r"SHA256:[A-Za-z0-9+/]+", run(keygen, "-E", "sha256", "-lf", str(public)))
            if not match or match[0] not in loaded:
                raise ValueError(f"{name}: key is not loaded in the Windows agent; run ssh-add manually")
            cache[name] = match[0]
        return cache[name]

    accounts = {}
    for account in config.get("data", {}).get("accounts", []):
        if not account.get("key"):
            continue
        identity = account_id(account)
        if identity in accounts:
            raise ValueError(f"duplicate account: {identity}")
        accounts[identity] = {
            "auth_fingerprint": fingerprint(account["key"]),
            "signing_fingerprint": fingerprint(account.get("signingKey") or account.get("signingkey") or account["key"]),
        }
    hosts = {}
    for host in config.get("data", {}).get("ssh_hosts", []):
        if host.get("identity"):
            hosts[host["identity"]] = fingerprint(host["identity"])
    return accounts, hosts


def update_text(text, accounts, hosts):
    original = tomllib.loads(text)
    expected = copy.deepcopy(original)
    changes = {}
    for table, mapping in (("accounts", accounts), ("ssh_hosts", hosts)):
        for index, row in enumerate(expected.get("data", {}).get(table, [])):
            if table == "accounts":
                if not row.get("key"):
                    continue
                fields = mapping.get(account_id(row))
            else:
                if not row.get("identity"):
                    continue
                fp = mapping.get(row["identity"])
                fields = {"identity_fingerprint": fp} if fp else None
            if fields is None:
                raise ValueError(f"no Windows mapping for target {table} entry {index + 1}")
            row.update(fields)
            changes[(table, index)] = fields

    # Work on narrow table sections, then compare the COMPLETE parsed result
    # against the intended data change. Exotic/misidentified TOML is refused,
    # rather than risking a rewrite of unrelated configuration.
    lines = text.splitlines(keepends=True)
    header = re.compile(r"^\s*\[\[data\.(accounts|ssh_hosts)\]\]\s*(?:#.*)?$")
    any_header = re.compile(r"^\s*\[.*\]\s*(?:#.*)?$")
    counters = {"accounts": 0, "ssh_hosts": 0}
    sections = []
    for start, line in enumerate(lines):
        match = header.match(line.rstrip("\r\n"))
        if match:
            table = match[1]
            fields = changes.get((table, counters[table]))
            counters[table] += 1
            if fields:
                end = next((i for i in range(start + 1, len(lines)) if any_header.match(lines[i].rstrip("\r\n"))), len(lines))
                sections.append((start, end, fields))
    newline = "\r\n" if "\r\n" in text else "\n"
    for start, end, fields in reversed(sections):
        body = lines[start + 1:end]
        for field, value in fields.items():
            pattern = re.compile(r"^(\s*)" + field + r"\s*=.*$")
            hits = [i for i, line in enumerate(body) if pattern.match(line.rstrip("\r\n"))]
            if len(hits) > 1:
                raise ValueError(f"ambiguous TOML field: {field}")
            replacement = f"  {field} = {json.dumps(value)}{newline}"
            if hits:
                old = body[hits[0]].rstrip("\r\n")
                comment = re.match(r"^\s*" + field + r'''\s*=\s*(?:"[^"\\]*"|'[^']*')(\s*#.*)?$''', old)
                if comment and comment[1]:
                    replacement = replacement.rstrip("\r\n") + comment[1] + newline
                body[hits[0]] = replacement
            else:
                body.insert(0, replacement)
        lines[start + 1:end] = body
    result = "".join(lines)
    if tomllib.loads(result) != expected:
        raise ValueError("cannot safely patch this TOML layout; no file was written")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / ".config/chezmoi/chezmoi.toml")
    parser.add_argument("--target-config", type=Path, help="optional existing WSL config; only fingerprint fields are synchronized")
    parser.add_argument("--ssh-dir", type=Path, default=Path.home() / ".ssh")
    parser.add_argument("--write", action="store_true", help="apply the previewed changes, keeping a unique backup beside each config")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("run on Windows, where the keys and agent are held")
    ssh_bin = Path(os.environ["WINDIR"]) / "System32/OpenSSH"
    original = args.config.read_bytes().decode("utf-8")
    accounts, hosts = collect(tomllib.loads(original), args.ssh_dir, str(ssh_bin / "ssh-keygen.exe"), str(ssh_bin / "ssh-add.exe"))
    planned = []
    for path in dict.fromkeys([args.config] + ([args.target_config] if args.target_config else [])):
        if path.is_symlink():
            raise ValueError(f"refusing to replace symlink: {path}")
        before = path.read_bytes()
        after = update_text(before.decode("utf-8"), accounts, hosts).encode("utf-8")
        planned.append((path, before, after))
    print(json.dumps({"accounts": {"-".join(k): v for k, v in accounts.items()}, "host_identities": hosts}, indent=2))
    for path, before, after in planned:
        if before == after:
            print(f"Unchanged: {path}")
            continue
        print(f"{'Updating' if args.write else 'Would update'}: {path}")
        if not args.write:
            continue
        if path.read_bytes() != before:
            raise ValueError(f"config changed during sync: {path}; retry")
        fd, backup = tempfile.mkstemp(prefix=path.name + ".fingerprints-backup-", dir=path.parent)
        os.close(fd)
        shutil.copy2(path, backup)
        # Preserve the existing file's ACL/inode rather than replacing it with
        # a differently permissioned temp file. A unique backup is retained.
        with path.open("r+b") as stream:
            stream.write(after)
            stream.truncate()
        print(f"Backup: {backup}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"ssh-fingerprints: {error}") from error
