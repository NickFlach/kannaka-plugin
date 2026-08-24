#!/usr/bin/env bash
# shell-rc.test.sh — which file the installer writes PATH and credentials into.
#
# This is the test that would have caught a real subscriber being locked out on
# 2026-08-23. The installer picked ~/.zshrc correctly and then discarded it:
#
#     [ -f "$rc" ] || rc="$HOME/.profile"
#
# A fresh macOS account has no ~/.zshrc, so both the PATH line and the swarm
# credentials went into ~/.profile — which zsh never reads for interactive
# shells. The install printed success; `kannaka` was command-not-found forever.
#
# Every case below runs against a throwaway HOME so nothing touches the real one.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$SCRIPT_DIR/../install/install.sh"

fails=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok  %s\n' "$1"
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# Pull just the helper out of the installer and run it in isolation, so this
# never downloads a binary or edits a real machine.
extract_shell_rc() {
  sed -n '/^shell_rc() {/,/^}/p' "$INSTALLER"
}

run_case() { # run_case <SHELL> <uname> [pre-existing files...]
  shell_val="$1"; uname_val="$2"; shift 2
  home="$(mktemp -d)"
  for f in "$@"; do : > "$home/$f"; done
  out="$(
    HOME="$home" SHELL="$shell_val" bash -c "
      uname() { printf '%s' '$uname_val'; }
      $(extract_shell_rc)
      shell_rc
    "
  )"
  # Report the rc path relative to the temp HOME so cases are comparable.
  printf '%s' "${out#"$home"/}"
  rm -rf "$home"
}

echo "shell-rc.test.sh"

# THE REGRESSION: zsh with no ~/.zshrc must still get ~/.zshrc, created.
check "zsh with NO existing rc → ~/.zshrc (not ~/.profile)" \
  ".zshrc" "$(run_case /bin/zsh Darwin)"

check "zsh with an existing ~/.zshrc → ~/.zshrc" \
  ".zshrc" "$(run_case /bin/zsh Darwin .zshrc)"

# A stray ~/.profile must not lure the writer away from the shell's real rc.
check "zsh with ONLY a ~/.profile → still ~/.zshrc" \
  ".zshrc" "$(run_case /bin/zsh Darwin .profile)"

# macOS bash reads ~/.bash_profile for login shells (Terminal opens those) and
# ignores ~/.bashrc, so prefer it when the user already has one.
check "bash on macOS with ~/.bash_profile → ~/.bash_profile" \
  ".bash_profile" "$(run_case /bin/bash Darwin .bash_profile)"

check "bash on macOS with no ~/.bash_profile → ~/.bashrc" \
  ".bashrc" "$(run_case /bin/bash Darwin)"

check "bash on Linux → ~/.bashrc" \
  ".bashrc" "$(run_case /bin/bash Linux)"

# Only a shell we genuinely cannot identify falls back to ~/.profile.
check "an unknown shell → ~/.profile" \
  ".profile" "$(run_case /usr/bin/fish Linux)"

check "SHELL unset → ~/.profile" \
  ".profile" "$(run_case "" Linux)"

# The file must EXIST afterwards — an rc path that was never created means the
# appended line lands in a file the shell may not pick up on some systems, and
# it is the reason the old fallback existed at all.
home="$(mktemp -d)"
out="$(HOME="$home" SHELL=/bin/zsh bash -c "uname() { printf Darwin; }; $(extract_shell_rc); shell_rc")"
if [ -f "$out" ]; then printf '  ok  the chosen rc file is created when missing\n'
else printf '  FAIL the chosen rc file is created when missing (%s)\n' "$out"; fails=$((fails + 1)); fi
rm -rf "$home"

if [ "$fails" -eq 0 ]; then
  echo
  echo "All shell-rc tests passed"
  exit 0
fi
echo
echo "$fails shell-rc test(s) failed"
exit 1
