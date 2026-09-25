# Security Policy

## Supported

Only the [`main` branch](https://github.com/CtrlCarlitos/dotfiles/tree/main)
receives security fixes. If you are running an older commit, update first
(`dot up`) and re-test before reporting.

## Reporting a vulnerability

Use GitHub's
[private vulnerability reporting](https://github.com/CtrlCarlitos/dotfiles/security/advisories/new)
for anything you believe is exploitable: a way the installers execute
untrusted code, a secret that ends up somewhere it shouldn't, a guardrail
bypass, or an SSH-key-handling flaw. Include reproduction steps and the
affected files. You will get a response before any fix is discussed
publicly.

Please do not open a public issue for:

- **Key material or passphrases.** The backup archive deliberately contains
  private keys (see [docs/backup-restore.md](docs/backup-restore.md)) and
  SSH config/passphrase handling is described in
  [docs/secrets.md](docs/secrets.md) and [docs/ssh-agents.md](docs/ssh-agents.md).
  Never paste keys, passphrases, `~/.ssh` listings of real machines, or
  `chezmoi.toml` contents that name real hosts/accounts into an issue — redact
  usernames, hostnames, and paths first.
- **Guardrail bypass details.** [guardrail](https://github.com/CtrlCarlitos/agent-guardrails)
  is the enforcement layer; report bypasses through its private channel, not
  here.
- **Anything in third-party tooling** (chezmoi, Chocolatey, Homebrew, the AI
  CLIs) that only reproduces upstream — report it there unless this repo's
  wiring is what makes it exploitable.

## What the repo ships, so you can assess exposure

- SSH **config** files are templated and deployed; private keys are never in
  the repo — they are generated per machine and only leave it via the
  encrypted `dot backup` archive.
- The guardrail pin and desired state are public
  ([docs/guardrail-install.md](docs/guardrail-install.md)); hooks.json
  enforcement is agent-guardrails' contract.
- CI runs a gitleaks scan on every PR; reports from it are treated as
  security-relevant.
