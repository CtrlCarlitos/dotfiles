#!/usr/bin/env python3
"""Local incoming-key contract adapter used by dot remote on every platform.

Effective remote_access JSON arrives on stdin. Only public source keys are read.
Transport/service activation remains in remote-access.ps1/sh.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tomllib

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from ssh_authorization import (FileSnapshot, PermissionPolicy, apply_removal,
    contract_names, load_declared_keys, parse_authorized, plan_authorization, replace_authorization, validate_sshd_config)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "sync", "remove", "validate", "count"])
    parser.add_argument("name", nargs="?")
    parser.add_argument("--public-key-dir", required=True, type=Path)
    parser.add_argument("--authorized-keys", required=True, type=Path)
    parser.add_argument("--platform", choices=["unix", "windows-admin", "windows-user"], required=True)
    parser.add_argument("--user-sid", default="")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--sshd-config", type=Path)
    args = parser.parse_intermixed_args()
    if args.sshd_config:
        validate_sshd_config(args.sshd_config)
    snapshot = FileSnapshot.read(args.authorized_keys)
    current = (snapshot.data or b"").decode("utf-8")
    if args.action == "count":
        print(len(parse_authorized(current)))
        return
    remote = json.load(sys.stdin)
    names = contract_names(remote)
    config_snapshot = None
    if args.action in ('sync', 'remove'):
        if not args.config:
            parser.error('mutating key operations require --config to detect concurrent edits')
        config_snapshot = FileSnapshot.read(args.config)
        local = tomllib.loads((config_snapshot.data or b'').decode('utf-8'))
        if contract_names(local.get('data', {}).get('remote_access')) != names:
            raise ValueError('effective key declaration differs from the local TOML; no changes made')
    policy = PermissionPolicy(args.platform, args.user_sid)
    if args.action == "remove":
        if not args.name or not args.config:
            parser.error("remove requires NAME and --config")
        plan = apply_removal(config_snapshot, snapshot, args.name, args.public_key_dir, policy, names)
    else:
        if args.name:
            parser.error("unexpected key name")
        plan = plan_authorization(load_declared_keys(names, args.public_key_dir), current)
        if args.action == "validate":
            return
        if args.action == "sync":
            backup = replace_authorization(snapshot, plan.text, policy, before_replace=config_snapshot.check)
            if backup: print(f"Authorization backup: {backup}")
    for key in plan.desired:
        print(f"declared {key.name}: {key.fingerprint}")
    for key in plan.additions:
        print(f"{'would add' if args.action == 'status' else 'added'} {key.name}: {key.fingerprint}")
    for entry in plan.removals:
        print(f"{'would revoke' if args.action == 'status' else 'revoked'} {entry.key.fingerprint}")
    state = "drift" if args.action == "status" and plan.changed else "in sync"
    print(f"SSH authorization {state}: {args.authorized_keys}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"remote keys: {error}", file=sys.stderr)
        sys.exit(1)
