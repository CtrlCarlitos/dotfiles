"""Resolve a SHA256 fingerprint against public identities streamed from ssh-add -L.

Used by the WSL relay and Git signing adapter. Nothing is written to disk.
"""
import base64
import hashlib
import sys


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("blob", "key"):
        raise ValueError("usage: ssh-agent-key SHA256:fingerprint {blob|key}")
    fingerprint, output = sys.argv[1:]
    if not fingerprint.startswith("SHA256:"):
        raise ValueError("expected an explicit SHA256 fingerprint; run fingerprint sync")
    matches = set()
    for line in sys.stdin:
        fields = line.split()
        if len(fields) < 2:
            continue
        try:
            raw = base64.b64decode(fields[1], validate=True)
        except ValueError:
            continue
        actual = "SHA256:" + base64.b64encode(hashlib.sha256(raw).digest()).decode().rstrip("=")
        if actual == fingerprint:
            matches.add((fields[0], fields[1]))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one agent key matching {fingerprint}; found {len(matches)}")
    kind, blob = matches.pop()
    print(blob if output == "blob" else f"key::{kind} {blob}")


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"ssh-agent-key: {error}", file=sys.stderr)
        sys.exit(1)
