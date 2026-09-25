# agent-browser installation requirements

Research date: 2026-09-15. Sources below are official npm metadata and the
Vercel-maintained `vercel-labs/agent-browser` repository.

## Findings

- The recommended global install is exactly
  `npm install -g --allow-scripts=agent-browser agent-browser`.
  It installs the `agent-browser` command. The package declares that command in
  its `bin` field and its post-install hook downloads a platform-specific native
  binary; for global installs it rewrites the npm Unix symlink or Windows shims
  to invoke that binary directly. The `--allow-scripts` allowlist is required:
  npm 12 blocks install scripts by default, which would silently skip the
  post-install binary download. [npm README][npm] [package manifest][package]
  [post-install source][postinstall]
- A browser is required for local browser automation. `agent-browser install`
  downloads Chrome for Testing; it also detects existing Chrome, Brave,
  Playwright, and Puppeteer browser installations. The daemon does not require
  Node.js or Playwright at runtime. [requirements][requirements]
- Linux also needs the platform browser libraries. The supported command is
  `agent-browser install --with-deps`; it fails if the package manager cannot
  install every required library. [Linux dependencies][linux-deps]
- The current package manifest declares Node.js >=24 and pnpm >=11; the README
  lists Node.js 24+, pnpm 11+, and Rust as build-from-source requirements.
  npm/Node are needed to perform the npm installation, but the released global
  command is a native binary after installation. [package manifest][package]
  [source build requirements][source-build]
- Downloading or installing only the repository's `skills/agent-browser/SKILL.md`
  does **not** install an executable or Chrome. It is explicitly a discovery
  stub that tells an already installed CLI to serve its version-matched skill
  content; the executable is supplied by the npm package's `bin` entry and
  post-install binary download. [skill stub][skill] [package manifest][package]
  [post-install source][postinstall]

## Installer recommendation

Use the global npm package, then provision Chrome and run the CLI's diagnostic.
This is noninteractive and avoids assuming that a newly written npm global bin
directory is already on `PATH`.

### chezmoi shell installer

```sh
npm install -g --allow-scripts=agent-browser agent-browser </dev/null
agent_browser="$(npm prefix -g)/bin/agent-browser"
"$agent_browser" install </dev/null
"$agent_browser" doctor --json </dev/null
```

On Linux, install the browser's system libraries in the installer’s existing
privileged distro-package stage. The official fallback is
`agent-browser install --with-deps`; use it only where the package manager and
privilege escalation are already configured to run unattended. It exits nonzero
when dependencies cannot all be installed.

### PowerShell installer

```powershell
npm install -g --allow-scripts=agent-browser agent-browser
if ($LASTEXITCODE -ne 0) { throw "agent-browser install failed" }
$agentBrowser = Join-Path (npm prefix -g) 'agent-browser.cmd'
& $agentBrowser install
if ($LASTEXITCODE -ne 0) { throw "agent-browser Chrome setup failed" }
& $agentBrowser doctor --json
if ($LASTEXITCODE -ne 0) { throw "agent-browser verification failed" }
```

The explicit `.cmd` path avoids a same-process `PATH` refresh dependency. The
package's Windows post-install path supplies a native executable shim; Windows
ARM64 uses the published x64 binary through Windows emulation when an ARM64
binary is unavailable. [post-install source][postinstall]

## OpenCode installation addendum

- Unix/macOS: `curl -fsSL https://opencode.ai/install | bash` is current
  official guidance. Rerun it to update; it resolves the latest GitHub release
  and skips installation when already current. Homebrew is an alternative:
  `brew install anomalyco/tap/opencode`. [OpenCode download][opencode-download]
  [OpenCode installer][opencode-installer]
- `opencode-ai` is a current, officially supported npm package, including
  Windows binaries. This repository deliberately chooses one OpenCode channel
  per platform instead: the native installer on Unix/macOS and Chocolatey on
  Windows. [npm metadata][opencode-npm] [Windows guidance][opencode-windows]
- Keep Playwright Chromium before agent-browser during provisioning so
  agent-browser can discover it. Keep OpenCode before Playwright during manual
  updates, matching the existing updater flow; neither order creates an
  OpenCode/agent-browser dependency. [OpenCode README][opencode-readme]

## Sources

[npm]: https://www.npmjs.com/package/agent-browser
[requirements]: https://github.com/vercel-labs/agent-browser#requirements
[linux-deps]: https://github.com/vercel-labs/agent-browser#linux-dependencies
[source-build]: https://github.com/vercel-labs/agent-browser#from-source
[package]: https://github.com/vercel-labs/agent-browser/blob/main/package.json
[postinstall]: https://github.com/vercel-labs/agent-browser/blob/main/scripts/postinstall.js
[skill]: https://github.com/vercel-labs/agent-browser/blob/main/skills/agent-browser/SKILL.md
[opencode-download]: https://opencode.ai/download
[opencode-installer]: https://github.com/anomalyco/opencode/blob/dev/install
[opencode-npm]: https://registry.npmjs.org/opencode-ai/latest
[opencode-windows]: https://opencode.ai/docs/windows-wsl
[opencode-readme]: https://github.com/anomalyco/opencode#installation
