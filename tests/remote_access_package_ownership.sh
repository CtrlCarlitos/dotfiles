#!/usr/bin/env bash
set -euo pipefail

# Rendering with each platform fixture proves that package-group ownership is
# enforced by template gates, rather than by comments or source layout.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/run_onchange_install_packages.sh.tmpl"
windows_template="$repo_root/run_onchange_install_packages.ps1.tmpl"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
config="$tmp/chezmoi.toml"
: >"$config"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

render() { # $1 = fixture JSON, $2 = output filename
    chezmoi execute-template --config "$config" --source "$repo_root" --override-data "$1" \
        <"$template" >"$tmp/$2"
}

render_windows() { # $1 = fixture JSON, $2 = output filename
    chezmoi execute-template --config "$config" --source "$repo_root" --override-data "$1" \
        <"$windows_template" >"$tmp/$2"
}

contains() { # $1 = output filename, $2 = fixed text, $3 = assertion label
    grep -Fq -- "$2" "$tmp/$1" || fail "$3"
}

omits() { # $1 = output filename, $2 = fixed text, $3 = assertion label
    if grep -Fq -- "$2" "$tmp/$1"; then
        fail "$3"
    fi
}

linux_remote='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"remote_access":true}}'
wsl_remote='{"chezmoi":{"os":"linux","kernel":{"osrelease":"5.15.153.1-microsoft-standard-WSL2"}},"packages":{"remote_access":true}}'
mac_remote='{"chezmoi":{"os":"darwin","kernel":{"osrelease":"23.6.0"}},"packages":{"remote_access":true}}'
linux_desktop='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"dev_desktop":true}}'
linux_server='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"remote_access_server":true}}'
mac_server='{"chezmoi":{"os":"darwin","kernel":{"osrelease":"23.6.0"}},"packages":{"remote_access_server":true}}'
windows_remote='{"chezmoi":{"os":"windows"},"packages":{"remote_access":true}}'
windows_desktop='{"chezmoi":{"os":"windows"},"packages":{"dev_desktop":true}}'
windows_server='{"chezmoi":{"os":"windows"},"packages":{"remote_access_server":true}}'

render "$linux_remote" linux-remote
render "$wsl_remote" wsl-remote
render "$mac_remote" mac-remote
render "$linux_desktop" linux-desktop
render "$linux_server" linux-server
render "$mac_server" mac-server
render_windows "$windows_remote" windows-remote
render_windows "$windows_desktop" windows-desktop
render_windows "$windows_server" windows-server

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
omits linux-server 'apt)  install_apt ;;' 'server-only Linux must bypass the generic package manager'
omits linux-server '    setup_shell' 'server-only Linux must not set up the login shell'
contains mac-server 'Remote Login is built in to macOS' 'server-only macOS must explain Remote Login'
omits mac-server 'brew) install_brew ;;' 'server-only macOS must bypass Homebrew setup'
omits mac-server '    setup_shell' 'server-only macOS must not set up the login shell'
for prohibited in 'tailscale up' 'tailscale set --ssh' 'systemctl' 'launchctl' 'sshd_config' 'authorized_keys' 'portproxy'; do
    omits linux-server "$prohibited" "remote_access_server must not contain $prohibited"
done

contains windows-remote '$packages += @("tailscale", "cloudflared")' 'Windows remote_access must install both remote tools'
omits windows-desktop '"tailscale", "cloudflared"' 'Windows dev_desktop must not install remote tools'
contains windows-server 'Administrator rights are required' 'Windows server prerequisite must warn about administrator rights'
contains windows-server "Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'" 'Windows server prerequisite must install OpenSSH Server capability'
omits windows-server 'choco list --exact' 'Windows server-only must bypass generic package installation'
for prohibited in 'Start-Service' 'Set-Service' 'New-NetFirewallRule' 'sshd_config' 'authorized_keys' 'portproxy' 'tailscale up' 'tailscale set --ssh'; do
    omits windows-server "$prohibited" "Windows server prerequisite must not contain $prohibited"
done

printf 'PASS: remote access package ownership\n'
