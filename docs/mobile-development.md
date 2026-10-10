# Mobile development

The opt-in `mobile_dev` package group installs the Expo and Android tooling
for building and testing mobile apps: the Android SDK, ADB, the emulator,
scrcpy, a standalone JDK, and the Maestro CLI and MCP server. It is the 17th
package group and defaults to off. Selecting it also forces `agent_toolkit`
on, because the mobile flows rely on Serena and Playwright already being
present. The design, the decisions behind it, and the parity requirements
are in [the mobile-dev design doc](superpowers/specs/2026-10-10-mobile-dev-design.md),
tracked in #336.

## Windows setup

`Install-MobileDev` (in `run_onchange_install_packages.ps1.tmpl`) installs a
standalone JDK 17+, the Android SDK command-line tools, platform-tools, the
emulator, a default Pixel-like AVD, and scrcpy, then adds a Windows Firewall
rule scoped to the WSL vEthernet subnet for the ADB bridge. It warns rather
than aborts when Windows Hypervisor Platform (WHPX) is disabled, and asks
for explicit confirmation before accepting the Android SDK licenses and
before downloading the multi-GB system image.

The ADB server itself is never started or registered as a service - run it
yourself, each session, before using Maestro/agent-device from WSL:

```
adb -a -P 5037 nodaemon server
```

Leave that terminal open for the session, or background it yourself; this
repo never automates it (design doc section 3.3). The Firewall rule only
allows that server's port 5037 from the WSL vEthernet subnet, never a
LAN-wide opening.


## WSL setup

<!-- TODO: WSL/Linux/macOS plan Tasks 2-5 (docs/superpowers/plans/2026-10-10-mobile-dev-wsl-linux-macos.md) fill this in: Maestro, the MCP registrations, and the ADB bridge client (ADB_SERVER_SOCKET). -->


## Linux and macOS

<!-- TODO: WSL/Linux/macOS plan Tasks 2 and 6 (docs/superpowers/plans/2026-10-10-mobile-dev-wsl-linux-macos.md) fill this in: the native install path and its parity notes. -->


## VS Code

<!-- TODO: WSL/Linux/macOS plan Task 6 (docs/superpowers/plans/2026-10-10-mobile-dev-wsl-linux-macos.md) fills this in: the React Native Tools extension recommendation and the vscode_overrides / extra_extensions wiring. -->


## Troubleshooting

<!-- TODO: no single owning task. The shared plan (2026-10-10-mobile-dev-shared.md, Task 6 handoff) lists troubleshooting as a skeleton output; the sibling plans add entries as they land. -->

