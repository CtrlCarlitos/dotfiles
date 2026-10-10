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

<!-- TODO: Windows plan Tasks 1-5 (docs/superpowers/plans/2026-10-10-mobile-dev-windows.md) fill this in: JDK, Android SDK, emulator, scrcpy, and the manual ADB-server command with its Firewall rule. -->


## WSL setup

<!-- TODO: WSL/Linux/macOS plan Tasks 2-5 (docs/superpowers/plans/2026-10-10-mobile-dev-wsl-linux-macos.md) fill this in: Maestro, the MCP registrations, and the ADB bridge client (ADB_SERVER_SOCKET). -->


## Linux and macOS

<!-- TODO: WSL/Linux/macOS plan Tasks 2 and 6 (docs/superpowers/plans/2026-10-10-mobile-dev-wsl-linux-macos.md) fill this in: the native install path and its parity notes. -->


## VS Code

<!-- TODO: WSL/Linux/macOS plan Task 6 (docs/superpowers/plans/2026-10-10-mobile-dev-wsl-linux-macos.md) fills this in: the React Native Tools extension recommendation and the vscode_overrides / extra_extensions wiring. -->


## Troubleshooting

<!-- TODO: no single owning task. The shared plan (2026-10-10-mobile-dev-shared.md, Task 6 handoff) lists troubleshooting as a skeleton output; the sibling plans add entries as they land. -->

