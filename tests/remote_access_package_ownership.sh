#!/usr/bin/env bash
set -euo pipefail

# Rendering with each platform fixture proves that package-group ownership is
# enforced by template gates, rather than by comments or source layout.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/run_onchange_install_packages.sh.tmpl"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

render() { # $1 = fixture JSON, $2 = output filename
    chezmoi execute-template --source "$repo_root" --override-data "$1" \
        <"$template" >"$tmp/$2"
}

contains() { # $1 = output filename, $2 = fixed text, $3 = assertion label
    grep -Fq -- "$2" "$tmp/$1" || fail "$3"
}

omits() { # $1 = output filename, $2 = fixed text, $3 = assertion label
    grep -Fq -- "$2" "$tmp/$1" && fail "$3"
}

linux_remote='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"remote_access":true}}'
wsl_remote='{"chezmoi":{"os":"linux","kernel":{"osrelease":"5.15.153.1-microsoft-standard-WSL2"}},"packages":{"remote_access":true}}'
mac_remote='{"chezmoi":{"os":"darwin","kernel":{"osrelease":"23.6.0"}},"packages":{"remote_access":true}}'
linux_desktop='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"dev_desktop":true}}'
linux_server='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"remote_access_server":true}}'

render "$linux_remote" linux-remote
render "$wsl_remote" wsl-remote
render "$mac_remote" mac-remote
render "$linux_desktop" linux-desktop
render "$linux_server" linux-server

contains linux-remote 'tailscale.com/install.sh' 'Linux remote_access must install Tailscale'
contains linux-remote 'apt-get install -y cloudflared' 'Linux remote_access must install cloudflared'
contains mac-remote 'tailscale-app' 'macOS remote_access must install tailscale-app'
contains mac-remote 'brew install cloudflared' 'macOS remote_access must install cloudflared'
contains wsl-remote 'apt-get install -y cloudflared' 'WSL remote_access must install cloudflared'
contains wsl-remote 'Tailscale remains on Windows' 'WSL remote_access must explicitly skip Tailscale'

omits linux-desktop 'tailscale.com/install.sh' 'dev_desktop must not install Tailscale'
omits linux-desktop 'apt-get install -y cloudflared' 'dev_desktop must not install cloudflared'

contains linux-server 'openssh-server' 'remote_access_server must install OpenSSH Server prerequisites'
contains linux-server 'manual' 'remote_access_server must explain manual next steps'
for prohibited in 'tailscale up' 'tailscale set --ssh' 'systemctl' 'launchctl' 'sshd_config' 'authorized_keys' 'portproxy'; do
    omits linux-server "$prohibited" "remote_access_server must not contain $prohibited"
done

printf 'PASS: remote access package ownership\n'
