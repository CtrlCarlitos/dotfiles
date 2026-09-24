# CI config fixtures

Every CI job that needs a `chezmoi.toml` composes it from here:

```sh
bash tests/fixtures/chezmoi/compose.sh <accounts> <packages> [--source-dir DIR] [--out FILE]
```

`accounts` is one of `single`, `multi`, `minimal`; `packages` is `on` or `off`.
The pieces are concatenated in TOML order: an optional top-level `sourceDir`,
then the accounts file, then the packages file.

## Why one source

The workflows used to carry **nine** hand-written `chezmoi.toml` heredocs. They
were supposed to be equivalent and were not: the Unix single-account fixture
had no `username`/`provider`, the Windows one did. A template that reached for
`.username` without a guard therefore passed `Test (Windows)` and failed Ubuntu
and macOS — a real bug made to look platform-specific by fixture drift, at the
cost of a CI round-trip to discover the platform was irrelevant. See the note
on #83.

With one source, a failure means the code, never the fixture.

## The three account shapes

| file | shape | used by | why it exists |
|---|---|---|---|
| `accounts-single.toml` | one identity with **every** optional key set | `test-unix`, `test-windows` | The canonical "fully described account". Carries `username` and `provider` on purpose — their absence was the drift. |
| `accounts-multi.toml` | two identities, `alice` and `bob` | `smoke-test`, `integration-test` | `integration-test` asserts on these exact names in `.gitconfig` and `.ssh/config` (`github-alice`, `projects/bobcorp`, `id_bob`). Change them there too or not at all. |
| `accounts-minimal.toml` | `name` + `email`, **nothing else** | `minimal-config-test`, `test-windows-install`, all three `full-install-*` | Backward compatibility: every optional key absent. `minimal-config-test` asserts on the name and email. Adding a key here silently weakens that test. |

## The two package knobs

| file | used by |
|---|---|
| `packages-off.toml` | every job that only renders and dry-runs |
| `packages-on.toml` | the three `full-install-*` jobs |

`packages-on` keeps `remote_access_server = false` (manual SSH setup) and
`guardrail = false` (its `plane enable` needs an interactive WebAuthn approval
CI cannot give). Both are commented in the file.

`tests/ci_fixture_contract.sh` checks that the package files carry exactly the
groups `.chezmoi.toml.tmpl` prompts for, that each account shape still has the
property it exists for, and that **no workflow carries an inline fixture
anymore** — the guarantee is that these files are the only place a fixture can
live.
