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

**If you decline a prompt** (the SDK licenses or the system-image
download), `Install-MobileDev` tells you to accept next time - but
`run_onchange_install_packages.ps1.tmpl` only re-runs when its own
rendered content changes, not on every `dot up`. To force it to run again:

```
chezmoi state delete-bucket --bucket=scriptState
dot up
```

**The first time** `adb -a -P 5037 nodaemon server` runs, Windows may show
an "Allow access" dialog for `adb.exe`. Clicking "Allow" there creates its
own Firewall rule for `adb.exe` scoped to whichever network profiles you
pick (Private/Public), separate from and broader than the `MobileDevAdbBridge`
rule this installer manages - which can undo the WSL-only scoping. Cancel
that dialog instead; the managed rule already allows exactly what the
bridge needs. Check what rules exist for `adb.exe` with:

```
Get-NetFirewallRule | Where-Object { (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $_).Program -like '*adb.exe' }
```

**If the bridge stops working after it has worked before**, a second,
different `adb.exe` may now be ahead of the SDK's own copy on `PATH` (a
prior manual Android SDK install, or scrcpy's bundled copy) - two adb
builds disagreeing over the ADB server protocol kill each other's
connections. `Install-MobileDev` warns when it detects this; `adb version`
on whichever `adb.exe` resolves first tells you which build is active.


## WSL setup

The `mobile_dev` group installs Maestro, agent-device, and a standalone JDK
inside WSL the same way it does on native Linux, and registers the Maestro
MCP server for Claude Code and Codex. What WSL cannot do is run an Android
device or emulator itself - that only exists on the Windows side (see
"Windows setup" above) - so WSL's `adb`, Maestro, and agent-device need a
bridge to the ADB server running on Windows.

`dot_zshrc` provides that bridge: it detects WSL automatically (no chezmoi
templating involved - it is a plain file applied identically everywhere) and
exports `ADB_SERVER_SOCKET` in every new shell, pointed at the Windows host.
How it resolves that address depends on which WSL networking mode is active:

- **Mirrored networking** (`wslinfo --networking-mode` prints `mirrored`):
  the loopback interface is shared with Windows, so `ADB_SERVER_SOCKET` is
  set to `tcp:127.0.0.1:5037`.
- **NAT networking** (the default on older WSL builds, or whenever
  `wslinfo` is unavailable or inconclusive): the Windows host is reached at
  the nameserver address in `/etc/resolv.conf`, so `ADB_SERVER_SOCKET` is
  set to `tcp:<that address>:5037`.

This is recomputed fresh every time a new shell starts (the resolved address
can change across Windows reboots or network reconnects) and never clobbers
an `ADB_SERVER_SOCKET` you have exported yourself.

The bridge only has something to reach once Carlos starts the ADB server on
the Windows side each session. That manual step - the exact
`adb -a -P 5037 nodaemon server` command and its Firewall rule - is
documented authoritatively in "Windows setup" above; this section only
covers the WSL side of the handshake.


## Linux and macOS

Both platforms get full native parity with WSL for everything this plan
installs: the Android SDK command-line tools, platform-tools, the emulator,
a standalone JDK, Maestro, and agent-device all run on a single host
natively, with no Windows/WSL split needed on either platform. macOS has a
clean brew path for all of it; native Linux uses the SDK command-line-tools
zip rather than an apt Android Studio package.

**Caveat:** only the installable half of the acceptance loop is covered by
this repo's hosted CI. GitHub Actions' `ubuntu-latest` and `macos-latest`
runners can verify that the SDK tools, Maestro, and agent-device install and
register correctly, but they do not boot an Android emulator or exercise a
Maestro flow against it - that would require multi-GB emulator images and
GUI virtualization that hosted CI doesn't provide. The
emulator-boot-and-Maestro-flow half of acceptance is therefore untested by
this repo's CI on both platforms. That's a real, stated gap, not a silent
one - anyone relying on CI green here should know the device-automation path
itself still needs a manual check on real hardware.


## VS Code

For React Native/Expo development, add Microsoft's `msjsdiag.vscode-react-native`
("React Native Tools") extension to your own `chezmoi.toml` via
`[data.vscode_overrides] extra_extensions`, the same machine-local override
mechanism documented in `.chezmoi.toml.tmpl`:

```toml
# [data.vscode_overrides]  (machine-local drift from the repo baseline;
#   extensions; settings are edited in [data.vscode.settings] above)
#   extra_extensions   = ["msjsdiag.vscode-react-native"]     # add to baseline
```

This extension is not part of the repo's own VS Code baseline, so machines
that never opt into `mobile_dev` never get it installed for free - add it
yourself, once, after selecting the `mobile_dev` package group.


## Stitch MCP

Stitch MCP stays optional, Antigravity-only, and manually authenticated - it
is not a hard prerequisite, and this plan's installer does not install or
wire it at all. #336 already scoped it that way; this section is a
documentation-only acknowledgment that the requirement exists and is
intentionally out of this plan's installer scope, not a silently dropped
feature.


## Troubleshooting

<!-- TODO: no single owning task. The shared plan (2026-10-10-mobile-dev-shared.md, Task 6 handoff) lists troubleshooting as a skeleton output; the sibling plans add entries as they land. -->

