# Mobile development

The opt-in `mobile_dev` package group installs the Expo and Android tooling
for building and testing mobile apps: the Android SDK, ADB, the emulator,
scrcpy, a standalone JDK, and the Maestro CLI and MCP server (which of these
each platform actually gets today differs - see the per-platform sections
below). It is the 17th package group and defaults to off. Selecting it also forces `agent_toolkit`
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
MCP server for all four agents: Claude Code (user scope), Codex, OpenCode,
and agy (see "MCP servers" below). What WSL cannot do is run an Android
device or emulator itself - that only exists on the Windows side (see
"Windows setup" above) - so Maestro and agent-device need a bridge to the
ADB server running on Windows.

WSL also gets a bare `adb` client: the Android SDK command-line tools
(pinned and checksum-verified) and `platform-tools` only, under
`~/.local/opt/android-sdk` - no emulator, system image or AVD, since the
device lives on Windows. `dot_zshrc` exports `ANDROID_HOME` and appends
`platform-tools` to `PATH` in every new shell, so `adb` talks to the
Windows-side ADB server through the bridge below. Two cases change that:

- If an `adb` is already on `PATH` (a distro package, say), the installer
  leaves it alone and installs nothing.
- Downloading `platform-tools` means accepting Google's Android SDK
  licenses. The installer asks first, and only in an interactive run. A
  non-interactive `dot up` skips the licenses and the download, and its
  warning tells you how to re-run from a terminal
  (`chezmoi state delete-bucket --bucket=scriptState && dot up`).

`dot_zshrc` provides that bridge: it detects WSL automatically (no chezmoi
templating involved - it is a plain file applied identically everywhere) and
exports `ADB_SERVER_SOCKET` in every new shell, pointed at the Windows host.
How it resolves that address depends on which WSL networking mode is active:

- **Mirrored networking** (`wslinfo --networking-mode` prints `mirrored`):
  the loopback interface is shared with Windows, so `ADB_SERVER_SOCKET` is
  set to `tcp:127.0.0.1:5037`.
- **NAT networking** (the default, or whenever `wslinfo` is unavailable or
  inconclusive): the Windows host is the default route's gateway
  (`ip route show default`), so `ADB_SERVER_SOCKET` is set to
  `tcp:<gateway>:5037`. It is deliberately *not* the nameserver in
  `/etc/resolv.conf`: with DNS tunneling, on by default on current WSL
  builds, that nameserver is `10.255.255.254`, a WSL-side DNS proxy, not the
  Windows host. `/etc/resolv.conf` is used only as a last resort when `ip`
  is missing.

This is recomputed fresh every time a new shell starts (the resolved address
can change across Windows reboots or network reconnects) and never clobbers
an `ADB_SERVER_SOCKET` you have exported yourself. It (and the `JAVA_HOME`
detection) only runs where `mobile_dev`'s installer has actually run, which
it records in the marker file `~/.local/state/dotfiles/mobile_dev`; on
machines without it, both blocks do nothing. The marker does not depend on
Maestro specifically: a Maestro you installed yourself beforehand, or a
failed Maestro download, still leaves the bridge and `JAVA_HOME` working.

The bridge only has something to reach once Carlos starts the ADB server on
the Windows side each session. That manual step - the exact
`adb -a -P 5037 nodaemon server` command and its Firewall rule - is
documented authoritatively in "Windows setup" above; this section only
covers the WSL side of the handshake.


## Linux and macOS

On native Linux and macOS, `mobile_dev` installs what it installs in WSL -
the Maestro CLI (pinned and checksum-verified, under
`~/.local/opt/maestro`, linked from `~/.local/bin`), agent-device (npm
global), and a standalone JDK 17 (apt's `openjdk-17-jdk` or brew's
`openjdk@17`), plus the same MCP registrations described under "MCP
servers" below - and the full Android SDK, because here everything runs on
a single host, with no Windows/WSL split:

- **SDK command-line tools** (`sdkmanager`, `avdmanager`): Google's zip for
  this OS (Linux, Mac Intel or Mac ARM), pinned in `.chezmoidata.yaml` and
  checksum-verified, installed to `~/.local/opt/android-sdk`.
- **platform-tools** (`adb`) and **the emulator**, through `sdkmanager`.
- **A default AVD**, `mobile_dev_pixel`: the `pixel_6` device profile on the
  `android-34` default system image (`x86_64`, or `arm64-v8a` on Apple
  Silicon and ARM Linux).

It also installs **scrcpy** (`command -v`-guarded, apt's `scrcpy` package
or brew's `scrcpy` formula) for mirroring and controlling a real device or
emulator's screen from the desktop.

`dot_zshrc` exports `ANDROID_HOME` and appends `platform-tools`, `emulator`
and `cmdline-tools/latest/bin` to `PATH` in every new shell. It appends
rather than prepends, so an `adb` already on your `PATH` keeps precedence.
The installer warns when it finds two different `adb` builds, because
mismatched versions kill each other's server.

The system image is several GB. Downloading it, `platform-tools` and the
emulator means accepting Google's Android SDK licenses, so the installer
asks first, and only in an interactive run. A non-interactive `dot up`
still installs the command-line tools, then skips the licenses and
everything behind them with a warning. To finish from a terminal, run
`chezmoi state delete-bucket --bucket=scriptState && dot up`.

If you already have an SDK (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, or Android
Studio's default `~/Android/Sdk` or `~/Library/Android/sdk`), the installer
uses it in place. It only adds what is missing, and never replaces it or
re-points `ANDROID_HOME`. `PATH` for that SDK stays yours to manage.

The emulator needs hardware acceleration. On Linux that is KVM: the
installer warns when `/dev/kvm` is missing (virtualization is off in the
firmware) or not accessible to you (fix with
`sudo usermod -aG kvm "$USER"`, then log out and back in). On macOS the
emulator uses Apple's built-in Hypervisor.framework. There is nothing to
enable there; if acceleration is unavailable anyway, the emulator says so
when it launches.

**Caveat:** no CI job ever performs a live `mobile_dev` install. The
real-install fixture (`tests/fixtures/chezmoi/packages-on.toml`, used by
`.github/workflows/full-install-test.yml`) sets `mobile_dev = false`, so
Maestro, agent-device, the JDK, scrcpy and the Android SDK are never
actually downloaded or installed on GitHub Actions' `ubuntu-latest` or
`macos-latest` runners. CI coverage for `mobile_dev` comes only from
`tests/mobile_dev_install_contract.sh` (and the MCP catalog checks in
`tests/mcp_autowire_contract.sh`), which `ci.yml` runs on every push via
`bash tests/run.sh`: they render the real installer template and execute
its functions against stub binaries, proving the install logic, gating and
MCP registration wiring - not that the real downloads, checksums or
installs succeed. Nor does CI boot an Android emulator or exercise a
Maestro flow against it - that would require multi-GB emulator images and
GUI virtualization that hosted CI doesn't provide. The
emulator-boot-and-Maestro-flow half of acceptance is therefore untested by
this repo's CI on both platforms. So is the license-gated half of the
Android SDK install (platform-tools, the emulator, the system image and the
AVD), which a non-interactive run skips by design and never downloads.
That's a real, stated gap, not a silent one - anyone relying on CI green
here should know both the live install and the device-automation path
still need a manual check on real hardware.


## MCP servers

- **Maestro MCP** (`maestro mcp`, a local server) is registered for all four
  agents whenever the Maestro binary is installed AND `mobile_dev` is on:
  Claude Code at user scope (`claude mcp add -s user`), Codex
  (`codex mcp add`), and OpenCode and agy from the `agents.mcp` catalog in
  `.chezmoidata/agents.yaml` (gated there via that catalog entry's own
  `group: mobile_dev` key, so an unrelated Maestro install elsewhere on
  `PATH` is never auto-registered with the group off).
- **Expo MCP** (`https://mcp.expo.dev/mcp`) is a hosted, remote server
  authenticated with OAuth. It is registered for **OpenCode and agy only**
  when `mobile_dev` is on - not for Claude Code or Codex, which is a
  deliberate scope boundary rather than an oversight. Authentication is a
  one-time step per machine: OpenCode prompts for it on first use, and in
  agy run `/mcp auth expo`.
- **agent-device MCP** (`agent-device mcp`, a local server) is registered
  for all four agents the same way Maestro is - binary present AND
  `mobile_dev` on, same `group: mobile_dev` catalog gate for OpenCode/agy.


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

