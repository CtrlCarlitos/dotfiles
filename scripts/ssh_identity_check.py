"""Warn when the config references an SSH key file that is not on this machine.

Shared checker for both `dot doctor` twins (dotfiles-doctor.sh and
dotfiles-doctor.ps1 print its output verbatim). Collects the same key
filenames scripts/ssh_fingerprints.py validates - [[data.accounts]] `key` /
`signingKey` and [[data.ssh_hosts]] `identity` - so `dot ssh-fingerprints
--write` can never die on a reference `dot doctor` called healthy first.

The incident (2026-11-17): two ssh_hosts entries named `id_penn-elcom`, the
key file did not exist, and `dot ssh-fingerprints --write` aborted on the
first validation while `dot doctor` reported nothing.

One doctor-format line per verdict (ok|warn|skip); exit code is always 0 -
a missing key is a warning, and on WSL the check skips entirely: keys live
in the Windows agent there by design (the relay serves them), so the
Windows twin is authoritative.

--config/--ssh-dir/--release exist for the contract test; defaults are the
real machine. Never reads private keys.
"""

import argparse
import platform
import sys
import tomllib
from pathlib import Path


def referenced_names(config):
    """Map every referenced key filename -> where it is referenced from."""
    names = {}

    for account in config.get("data", {}).get("accounts", []):
        key = account.get("key")
        if key:
            user = account.get("username", "?")
            names[key] = f"account {user} key"
            signing = account.get("signingKey") or account.get("signingkey") or key
            names[signing] = f"account {user} signingKey"

    for host in config.get("data", {}).get("ssh_hosts", []):
        identity = host.get("identity")
        if identity:
            names[identity] = f"ssh_host {host.get('name', '?')} identity"

    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(Path.home() / ".config/chezmoi/chezmoi.toml"))
    parser.add_argument("--ssh-dir", default=str(Path.home() / ".ssh"))
    parser.add_argument("--release", default=platform.release())
    args = parser.parse_args()

    def line(status, message):
        print(f"{status:<7}  {'ssh-identities':<16} {message}")

    if "microsoft" in args.release.lower():
        line("skip", "keys live in the Windows agent on WSL - the Windows dot doctor owns this check")
        return 0

    config_path = Path(args.config)
    if not config_path.is_file():
        line("skip", f"no config at {config_path}")
        return 0

    config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    ssh_dir = Path(args.ssh_dir)

    missing, malformed = [], []
    for name, where in sorted(referenced_names(config).items()):
        if not name or Path(name).name != name or "/" in name or "\\" in name:
            malformed.append(f"{name!r} ({where})")
            continue
        if not (ssh_dir / name).exists() and not (ssh_dir / (name + ".pub")).exists():
            missing.append(f"{name} ({where})")

    if malformed:
        line("warn", f"not a bare key filename:{' '.join(malformed)} - fix the chezmoi.toml reference")
    if missing:
        line(
            "warn",
            f"referenced key file(s) missing from {ssh_dir}:{' '.join(missing)}"
            " - dot ssh-fingerprints --write will fail on these",
        )
    if not missing and not malformed:
        line("ok", f"every referenced key file exists in {ssh_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
