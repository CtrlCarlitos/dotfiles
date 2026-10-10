#!/usr/bin/env bash
set -euo pipefail

# mobile_dev's installer assumes agent_toolkit's Serena/Playwright already
# exist, so mobile_dev = true must force agent_toolkit on wherever packages
# are chosen (docs/package-groups.md):
#
#   - Template default: .chezmoi.toml.tmpl resolves mobile_dev's answer into
#     $mobileDev BEFORE agent_toolkit's line, and agent_toolkit's forced
#     override reads $mobileDev - NOT a re-read of the previous config's
#     .packages.mobile_dev. That ordering is what makes the override see a
#     mobile_dev answer from THIS SAME render (a fresh `chezmoi init`
#     answering both prompts in one pass, or an existing user flipping
#     mobile_dev on for the first time) instead of only a value already on
#     record from a previous render. It is also what keeps a non-interactive
#     (CI/devcontainer) render at agent_toolkit = false even when a prior
#     mobile_dev = true is on record, since $mobileDev is false in that mode
#     regardless of what is on record (every key defaults false when
#     non-interactive, by design).
#   - Menu: scripts/select-packages.sh and scripts/select-packages.ps1 both
#     auto-add agent_toolkit to the persisted [data.packages] selection
#     whenever mobile_dev ends up selected, regardless of preset or whether
#     the user explicitly checked agent_toolkit. This auto-add is NOT a soft
#     default the user can quietly override next run: unchecking
#     agent_toolkit while mobile_dev stays checked is undone again on the
#     very next run too - the install-time gate is a separate, last-resort
#     backstop for a hand-edited config that bypasses the menu entirely.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

# ======================================================================
# Part A: template-level forced default/override
# ======================================================================

tmpl="$repo_root/.chezmoi.toml.tmpl"
empty_config="$(mktemp -d)/empty.toml"
: >"$empty_config"

# The exact prompt text behind mobile_dev's promptBoolOnce call: --promptBool
# is keyed by this text, not by the "packages.mobile_dev" data key, so it is
# read straight out of the template rather than duplicated here (and risking
# drift from it).
mobile_dev_prompt="$(grep -oE 'promptBoolOnce \. "packages\.mobile_dev" "[^"]*"' "$tmpl" |
    sed -E 's/^promptBoolOnce \. "packages\.mobile_dev" "(.*)"$/\1/')"
[ -n "$mobile_dev_prompt" ] || fail "could not find mobile_dev's promptBoolOnce prompt text in $tmpl"

render_tmpl() { # $1 = --override-data JSON (non-interactive: CI=1)
    CI=1 chezmoi execute-template --init --config "$empty_config" --source "$repo_root" \
        --override-data "$1" <"$tmpl"
}

render_tmpl_interactive() { # $1 = --override-data JSON, $2 = mobile_dev's promptBool answer
    env -u CI -u DEVCONTAINER -u REMOTE_CONTAINERS \
        chezmoi execute-template --init --config "$empty_config" --source "$repo_root" \
        --promptBool "$mobile_dev_prompt=$2" \
        --override-data "$1" <"$tmpl"
}

agent_toolkit_line() { # $1 = rendered output
    printf '%s\n' "$1" | grep -E '^[[:space:]]*agent_toolkit[[:space:]]*=' | head -1
}

mobile_dev_line() { # $1 = rendered output
    printf '%s\n' "$1" | grep -E '^[[:space:]]*mobile_dev[[:space:]]*=' | head -1
}

# stat "/.dockerenv" always true inside a Docker container regardless of env
# vars, which would force $isDevcontainer true and make every interactive
# case below impossible to simulate - skip those cases there rather than
# produce a false failure.
can_simulate_interactive=true
[ -e /.dockerenv ] && can_simulate_interactive=false

# --- fresh single-pass render (the bug this contract exists for) ---------
# Prior agent_toolkit = false on record, mobile_dev freshly answered true IN
# THIS SAME RENDER (never before recorded) -> agent_toolkit must still come
# out true. Before the ordering fix, agent_toolkit's line rendered before
# mobile_dev's answer existed and read the stale/absent prior value instead.
if $can_simulate_interactive; then
    out="$(render_tmpl_interactive '{"packages":{"agent_toolkit":false}}' true)" ||
        fail "render (interactive, prior agent_toolkit=false, mobile_dev freshly answered true) failed"
    case "$(agent_toolkit_line "$out")" in
    *"= true"*) pass ;;
    *) fail "mobile_dev freshly answered true in the same render must force agent_toolkit = true, got: $(agent_toolkit_line "$out")" ;;
    esac
    case "$(mobile_dev_line "$out")" in
    *"= true"*) pass ;;
    *) fail "mobile_dev's freshly-answered value must itself render true, got: $(mobile_dev_line "$out")" ;;
    esac
else
    skip "running inside a container (/.dockerenv present): cannot simulate an interactive render"
fi

# --- non-interactive (CI/devcontainer) symptom: must be gone --------------
# mobile_dev already true ON RECORD, but the render itself is non-interactive
# -> agent_toolkit must default false too (every key defaults false when
# non-interactive), NOT get force-true'd off the stale record.
out="$(render_tmpl '{"packages":{"mobile_dev":true}}')" ||
    fail "render (non-interactive, mobile_dev=true on record, agent_toolkit unanswered) failed"
case "$(agent_toolkit_line "$out")" in
*"= false"*) pass ;;
*) fail "non-interactive render with mobile_dev=true on record must still render agent_toolkit = false, got: $(agent_toolkit_line "$out")" ;;
esac
case "$(mobile_dev_line "$out")" in
*"= false"*) pass ;;
*) fail "non-interactive render must render mobile_dev = false regardless of what is on record, got: $(mobile_dev_line "$out")" ;;
esac

# mobile_dev true on record, agent_toolkit PREVIOUSLY recorded false,
# non-interactive render -> both still default false (non-interactive floor
# wins over any prior record for every key, including agent_toolkit).
out="$(render_tmpl '{"packages":{"mobile_dev":true,"agent_toolkit":false}}')" ||
    fail "render (non-interactive, mobile_dev=true, agent_toolkit=false both on record) failed"
case "$(agent_toolkit_line "$out")" in
*"= false"*) pass ;;
*) fail "non-interactive render must render agent_toolkit = false even with mobile_dev=true on record, got: $(agent_toolkit_line "$out")" ;;
esac

# mobile_dev absent/false -> unchanged non-interactive behavior (false).
out="$(render_tmpl '{"packages":{}}')" || fail "render (no packages) failed"
case "$(agent_toolkit_line "$out")" in
*"= false"*) pass ;;
*) fail "mobile_dev absent must leave agent_toolkit's non-interactive render at false, got: $(agent_toolkit_line "$out")" ;;
esac

out="$(render_tmpl '{"packages":{"mobile_dev":false}}')" || fail "render (mobile_dev=false) failed"
case "$(agent_toolkit_line "$out")" in
*"= false"*) pass ;;
*) fail "mobile_dev=false must not force agent_toolkit, got: $(agent_toolkit_line "$out")" ;;
esac

# ======================================================================
# Part B: menu-level auto-add, scripts/select-packages.sh
# ======================================================================

case "${OSTYPE:-}" in
msys* | cygwin* | win32) ;; # select-packages.sh is Unix-only; skip this part below
*)
    sh_tmp="$(mktemp -d)"
    sh_bin="$sh_tmp/bin"
    mkdir -p "$sh_bin"
    gum_log="$sh_tmp/gum.log"

    # Fake gum: logs its argv, then serves canned results (same shape as
    # tests/select_packages.sh's fixture).
    cat >"$sh_bin/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:?}"
if [[ "$*" == *--no-limit* ]]; then
    [[ "$FAKE_MULTI" == "__FAIL__" ]] && exit 130
    tr ' ' '\n' <<<"${FAKE_MULTI:?}" | sed '/^$/d'
else
    printf '%s\n' "${FAKE_PRESET:-custom}"
fi
EOF
    chmod +x "$sh_bin/gum"

    sh_home="$sh_tmp/home"
    mkdir -p "$sh_home"
    sh_script="$repo_root/scripts/select-packages.sh"

    if command -v script >/dev/null 2>&1; then
        # mobile_dev checked, agent_toolkit NOT checked: the menu must still
        # persist agent_toolkit = true.
        timeout 30 script -qec \
            "HOME='$sh_home' PATH='$sh_bin:$PATH' FAKE_GUM_LOG='$gum_log' FAKE_MULTI='mobile_dev' FAKE_PRESET='custom' bash '$sh_script'" \
            /dev/null >/dev/null 2>&1 || fail "select-packages.sh: menu run exited non-zero"

        sh_cfg="$sh_home/.config/chezmoi/chezmoi.toml"
        if [ -f "$sh_cfg" ]; then
            if grep -Eq '^[[:space:]]*agent_toolkit[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$sh_cfg"; then
                pass
            else
                fail "select-packages.sh: mobile_dev selected alone did not force agent_toolkit = true: $(cat "$sh_cfg")"
            fi
            if grep -Eq '^[[:space:]]*mobile_dev[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$sh_cfg"; then
                pass
            else
                fail "select-packages.sh: mobile_dev itself was not persisted true"
            fi
        else
            fail "select-packages.sh: $sh_cfg was not created"
        fi
    else
        skip "no 'script' (pty wrapper) available to drive select-packages.sh interactively"
    fi
    ;;
esac

# ======================================================================
# Part C: menu-level auto-add, scripts/select-packages.ps1
# ======================================================================

if command -v pwsh >/dev/null 2>&1 && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }; then
    py="$(command -v python3 || command -v python)"
    ps_tmp="$(mktemp -d)"
    ps_bin="$ps_tmp/bin"
    mkdir -p "$ps_bin"
    ps_gum_log="$ps_tmp/gum.log"

    cat >"$ps_bin/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:?}"
if [[ "$*" == *--no-limit* ]]; then
    [[ "$FAKE_MULTI" == "__FAIL__" ]] && exit 130
    tr ' ' '\n' <<<"${FAKE_MULTI:?}" | sed '/^$/d'
else
    printf '%s\n' "${FAKE_PRESET:-custom}"
fi
EOF
    chmod +x "$ps_bin/gum"

    ptyrunner="$ps_tmp/ptyrun.py"
    cat >"$ptyrunner" <<'EOF'
import fcntl, os, pty, select, signal, struct, sys, termios, time
timeout = float(sys.argv[1])
cmd = sys.argv[2:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    try:
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    except OSError:
        pass
    os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
    if slave > 2:
        os.close(slave)
    try:
        os.execvp(cmd[0], cmd)
    finally:
        os._exit(127)
os.close(slave)
status = None
deadline = time.monotonic() + timeout
while status is None:
    try:
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid:
            status = st
            break
    except ChildProcessError:
        status = 0
        break
    if time.monotonic() > deadline:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        break
    try:
        ready, _, _ = select.select([master], [], [], 0.2)
    except OSError:
        continue
    if ready:
        try:
            data = os.read(master, 65536)
        except OSError:
            continue
        if data:
            sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
while True:
    try:
        data = os.read(master, 65536)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
sys.stdout.buffer.flush()
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
EOF

    ps_home="$ps_tmp/home"
    mkdir -p "$ps_home"
    ps_script="$repo_root/scripts/select-packages.ps1"

    HOME="$ps_home" USERPROFILE="$ps_home" PATH="$ps_bin:$PATH" \
        FAKE_GUM_LOG="$ps_gum_log" FAKE_MULTI="mobile_dev" FAKE_PRESET="custom" \
        "$py" "$ptyrunner" 30 pwsh -NoProfile -File "$ps_script" >/dev/null 2>&1 ||
        fail "select-packages.ps1: menu run exited non-zero"

    ps_cfg="$ps_home/.config/chezmoi/chezmoi.toml"
    if [ -f "$ps_cfg" ]; then
        if grep -Eq '^[[:space:]]*agent_toolkit[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$ps_cfg"; then
            pass
        else
            fail "select-packages.ps1: mobile_dev selected alone did not force agent_toolkit = true: $(cat "$ps_cfg")"
        fi
        if grep -Eq '^[[:space:]]*mobile_dev[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$ps_cfg"; then
            pass
        else
            fail "select-packages.ps1: mobile_dev itself was not persisted true"
        fi
    else
        fail "select-packages.ps1: $ps_cfg was not created"
    fi
else
    skip "pwsh or python3 not available to drive select-packages.ps1 interactively"
fi

# ======================================================================
# Part D: install-time safety net (Task 4) - the last-resort catch for a
# hand-edited chezmoi.toml that bypasses both Part A (template default) and
# Part B/C (menu auto-add): mobile_dev = true with agent_toolkit = false must
# warn loudly and skip rather than silently assume agent_toolkit's tools
# (Serena, Playwright) exist (design doc section 3.9a).
# ======================================================================

sh_tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
ps1_tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"

# Wiring: one Go template variable per package group, same hasKey pattern as
# every other group (e.g. $agent_toolkit right above it in both files).
for tmpl in "$sh_tmpl" "$ps1_tmpl"; do
    require "$tmpl" '{{- $mobile_dev := false -}}'
    require "$tmpl" '{{- if hasKey .packages "mobile_dev" }}{{- $mobile_dev = .packages.mobile_dev }}{{- end -}}'
    require "$tmpl" 'mobile_dev requires agent_toolkit (Serena/Playwright) - not installed; enable agent_toolkit and re-run'
    # Defensive, self-documenting addition to the aggregate "is anything
    # selected at all" gate: transitively covered already (docs/package-groups.md
    # forces agent_toolkit on whenever mobile_dev is true, and agent_toolkit is
    # already in this list), but every other group is listed explicitly too.
    require "$tmpl" '$agent_toolkit $mobile_dev $opencode_cli'
done

# Behavior: render both installer twins (render_to, tests/lib.sh) across the
# three states that matter.
d_groups() { # $1 = agent_toolkit bool, $2 = mobile_dev bool
    printf '{"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":%s,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":false,"dev_desktop":true,"vscode_settings":false,"mobile_dev":%s}' "$1" "$2"
}

d_out="$(mktemp -d)/rendered"
for platform in sh ps1; do
    # mobile_dev=true, agent_toolkit=false -> warn and skip (the safety net).
    render_to "$d_out" "$platform" "$(d_groups false true)"
    if grep -Fq 'mobile_dev requires agent_toolkit' "$d_out"; then
        pass
    else
        fail "$platform: mobile_dev=true/agent_toolkit=false did not render the warn-and-skip guard"
    fi

    # mobile_dev=true, agent_toolkit=true -> no warning (agent_toolkit's own
    # tools are present; a sibling task's install call plugs in here).
    render_to "$d_out" "$platform" "$(d_groups true true)"
    if grep -Fq 'mobile_dev requires agent_toolkit' "$d_out"; then
        fail "$platform: mobile_dev=true/agent_toolkit=true must not warn"
    else
        pass
    fi

    # mobile_dev=false -> never warn, regardless of agent_toolkit.
    render_to "$d_out" "$platform" "$(d_groups true false)"
    if grep -Fq 'mobile_dev requires agent_toolkit' "$d_out"; then
        fail "$platform: mobile_dev=false must never render the warning"
    else
        pass
    fi
done

finish
