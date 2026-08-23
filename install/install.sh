#!/bin/sh
# Kannaka one-shot installer (macOS / Linux).
#
# Binary-FIRST and Claude-OPTIONAL: the kannaka memory engine is a standalone
# binary that works with or without Claude Code. This installer always installs
# the binary first (the only requirement is being able to download it), puts it
# on PATH, and verifies it runs. THEN, if Claude Code is detected, it wires up
# the plugin + live statusline as a bonus — and if it isn't, it says so and
# finishes successfully rather than failing.
#
# Pass --with-claude to also install Node.js + Claude Code when missing (opt-in;
# off by default so standalone users aren't forced into a Node/Claude install).
#
# Idempotent — safe to re-run. Run directly:
#   curl -fsSL https://raw.githubusercontent.com/NickFlach/kannaka-plugin/master/install/install.sh | sh
RELEASE_REPO="${KANNAKA_RELEASE_REPO:-NickFlach/kannaka-memory}"
TUI_REPO="${KANNAKA_TUI_REPO:-NickFlach/kannaka-tui}"
INSTALL_URL="https://raw.githubusercontent.com/NickFlach/kannaka-plugin/master/install/install.sh"
WITH_CLAUDE=0
SKIP_TUI=0
# Constellation Pass credentials. Accepted as flags or environment so the
# portal can hand a subscriber one line that works, and so a re-run without
# them leaves an existing credential file untouched rather than blanking it.
NATS_USER_ARG="${KANNAKA_NATS_USER:-}"
NATS_PASS_ARG="${KANNAKA_NATS_PASSWORD:-}"
CLAIM=0
PORTAL_API="${KANNAKA_PORTAL_API:-https://ninja-portal.com}"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude) WITH_CLAUDE=1 ;;
    --skip-statusline) SKIP_STATUSLINE=1 ;;
    --skip-tui) SKIP_TUI=1 ;;
    --nats-user) NATS_USER_ARG="${2:-}"; shift ;;
    --nats-password) NATS_PASS_ARG="${2:-}"; shift ;;
    --nats-user=*) NATS_USER_ARG="${1#*=}" ;;
    --nats-password=*) NATS_PASS_ARG="${1#*=}" ;;
    --claim) CLAIM=1 ;;
  esac
  shift
done

say()  { printf '\033[36m▸\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Kannaka installer"

# ───────────────────────────────────────────────────────────────────────────
# 1. CORE: the kannaka binary → ~/.local/bin
#    The product. Needs nothing but a download — no Node, no Claude. Failure
#    here is fatal; everything after is best-effort enhancement.
# ───────────────────────────────────────────────────────────────────────────
set -eu
DEST="$HOME/.local/bin"; mkdir -p "$DEST"
os=$(uname -s); arch=$(uname -m)
case "$os" in Linux*) o=linux ;; Darwin*) o=macos ;; *) warn "unsupported OS: $os"; exit 1 ;; esac
case "$arch" in x86_64|amd64) a=x86_64 ;; aarch64|arm64) a=aarch64 ;; *) warn "unsupported arch: $arch"; exit 1 ;; esac
base="https://github.com/$RELEASE_REPO/releases/latest/download"

# Download one release asset and refuse to install it unverified.
#
# Was inline for the single binary; a second one (the TUI) made copying it the
# obvious move and the wrong one — a checksum check that exists twice is a
# checksum check that gets weakened once. Every failure path removes the
# partial file, so a refused install never leaves something executable behind.
#
#   fetch_verified <repo> <asset-name> <destination-path> <label>
fetch_verified() {
  fv_repo="$1"; fv_asset="$2"; fv_dest="$3"; fv_label="$4"
  fv_base="https://github.com/$fv_repo/releases/latest/download"
  fv_sha="${fv_dest}.sha.tmp"

  say "Downloading $fv_label ($fv_asset)…"
  if ! curl -fSL "$fv_base/$fv_asset" -o "$fv_dest"; then
    warn "Failed to download $fv_asset from $fv_base — check your internet connection."
    rm -f "$fv_dest"; return 1
  fi
  # The release always publishes a per-file .sha256 (Sigstore + checksums
  # trust). A MISSING checksum means we cannot verify — fail closed rather than
  # install an unverified binary. (Verification used to be nested inside the
  # download's `if`, so a missing .sha256 silently skipped it.)
  if ! curl -fsSL "$fv_base/$fv_asset.sha256" -o "$fv_sha"; then
    warn "checksum $fv_asset.sha256 could not be downloaded — refusing to install an unverified binary"
    rm -f "$fv_dest" "$fv_sha"; return 1
  fi
  # Per-destination temp name: a shared one raced when two installs ran at once
  # and would silently verify the wrong file against the wrong digest.
  fv_want=$(awk '{print $1}' "$fv_sha"); rm -f "$fv_sha"
  if [ -z "$fv_want" ]; then
    warn "checksum $fv_asset.sha256 was empty — refusing to install unverified"
    rm -f "$fv_dest"; return 1
  fi
  if have sha256sum; then fv_got=$(sha256sum "$fv_dest" | awk '{print $1}')
  elif have shasum; then fv_got=$(shasum -a 256 "$fv_dest" | awk '{print $1}')
  else
    warn "no sha256 tool (sha256sum/shasum) available — cannot verify"
    rm -f "$fv_dest"; return 1
  fi
  if [ "$fv_want" != "$fv_got" ]; then
    warn "$fv_label sha256 mismatch (want $fv_want got $fv_got)"
    rm -f "$fv_dest"; return 1
  fi
  say "sha256 verified"
  chmod +x "$fv_dest"
  ok "$fv_label installed → $fv_dest"
}

fetch_verified "$RELEASE_REPO" "kannaka-${o}-${a}" "$DEST/kannaka" "kannaka" || exit 1

# ───────────────────────────────────────────────────────────────────────────
# 2. PATH: make sure ~/.local/bin is reachable, or `kannaka` looks like it
#    "did nothing" on a fresh machine (the #1 silent-failure cause).
# ───────────────────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$DEST:"*) ;;  # already there
  *)
    # Persist to the user's shell rc (guarded + idempotent), and export for now.
    rc=""
    case "${SHELL:-}" in
      *zsh)  rc="$HOME/.zshrc" ;;
      *bash) rc="$HOME/.bashrc" ;;
      *)     rc="$HOME/.profile" ;;
    esac
    [ -f "$rc" ] || rc="$HOME/.profile"
    if ! grep -qs '\.local/bin' "$rc" 2>/dev/null; then
      printf '\n# kannaka\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' >> "$rc"
      say "Added ~/.local/bin to PATH in $rc — open a NEW terminal for 'kannaka' to be found."
    fi
    export PATH="$DEST:$PATH"
    ;;
esac

# Verify it runs (surface a broken download instead of silence).
if ver=$("$DEST/kannaka" --version 2>/dev/null | head -1); then
  [ -n "$ver" ] && ok "kannaka is working: $ver"
else
  warn "kannaka installed but '--version' failed to run."
fi

# ───────────────────────────────────────────────────────────────────────────
# 2b. THE DASHBOARD: kannaka-tui → ~/.local/bin
#
# Its own repo and its own releases since the binary was extracted at v0.5.12,
# with the same asset naming, so it rides the same verified download. Not fatal
# if it fails: the engine is the product and a missing dashboard must not cost
# somebody a working install.
#
# (consciousness-core is deliberately NOT here. It is a LIBRARY — no [[bin]],
# no main.rs — compiled into the kannaka binary above, so anyone who has
# kannaka already has its physics. There is nothing separate to install.)
# ───────────────────────────────────────────────────────────────────────────
if [ "$SKIP_TUI" != "1" ]; then
  set +e
  fetch_verified "$TUI_REPO" "kannaka-tui-${o}-${a}" "$DEST/kannaka-tui" "kannaka-tui"
  tui_rc=$?
  set -e
  [ "$tui_rc" -eq 0 ] || warn "kannaka-tui was not installed — the engine is fine; re-run to retry."
fi

# ───────────────────────────────────────────────────────────────────────────
# 2c. CONSTELLATION PASS: authenticated swarm credentials.
#
# `kannaka swarm serve` and `listen --auto-sync` need an AUTHENTICATED NATS
# connection; anonymous is read-only. The binary reads `NATS_USER` /
# `NATS_PASSWORD` from the ENVIRONMENT (src/nats.rs, precedence: explicit >
# env > url), and the documented home for them is ~/.kannaka-nats.env.
#
# Nothing ever put them in the environment for a person. The systemd units and
# the auth cron `source` that file explicitly; an interactive shell never did.
# So a subscriber could write their credentials in exactly the documented place
# and still connect anonymously — paying for a tier their terminal could not
# reach. Writing the file is only half the job; the shell has to load it.
# ───────────────────────────────────────────────────────────────────────────
CREDS="$HOME/.kannaka-nats.env"

# Collect credentials without ever putting one on a command line.
#
# `--nats-user U --nats-password P` works and is kept, but it writes both
# secrets into shell history and into the process table. `--claim` asks the
# portal for a claim, shows a SHORT code, and waits while the subscriber
# approves that code on their pass page. Nothing secret is typed here and
# nothing secret is echoed.
#
# Best-effort by design: a portal that is down, a person who wanders off, a
# box with no `curl` — none of that should cost somebody a working engine, so
# every failure warns and falls through to the anonymous read-only swarm.
claim_credentials() {
  have curl || { warn "--claim needs curl"; return 1; }
  cl_start=$(curl -fsS -X POST -H 'content-type: application/json' -d '{}' \
    "$PORTAL_API/api/claim/start" 2>/dev/null) || { warn "could not reach $PORTAL_API"; return 1; }

  # sed rather than a JSON parser: `jq` is not a reasonable prerequisite for an
  # installer, and these three fields are flat strings the portal emits itself.
  cl_id=$(printf '%s' "$cl_start" | sed -n 's/.*"claim_id" *: *"\([a-f0-9]*\)".*/\1/p')
  cl_code=$(printf '%s' "$cl_start" | sed -n 's/.*"user_code" *: *"\([A-Z0-9-]*\)".*/\1/p')
  cl_url=$(printf '%s' "$cl_start" | sed -n 's/.*"verify_url" *: *"\([^"]*\)".*/\1/p')
  [ -n "$cl_id" ] && [ -n "$cl_code" ] || { warn "the portal did not return a claim"; return 1; }

  printf '\n'
  say "To link your Constellation Pass, open:"
  say "    ${cl_url:-$PORTAL_API/link}"
  say "and enter this code:"
  printf '\n        \033[1m%s\033[0m\n\n' "$cl_code"
  say "Waiting for approval (Ctrl-C to skip)…"

  # ~10 minutes at 5s, matching the claim's own TTL, so the loop and the
  # server stop caring at the same moment rather than one outliving the other.
  cl_n=0
  while [ "$cl_n" -lt 120 ]; do
    sleep 5
    cl_n=$((cl_n + 1))
    cl_poll=$(curl -fsS -X POST -H 'content-type: application/json' \
      -d "{\"claim_id\":\"$cl_id\"}" "$PORTAL_API/api/claim/poll" 2>/dev/null) || continue
    case "$cl_poll" in
      *'"status":"approved"'*|*'"status": "approved"'*)
        NATS_USER_ARG=$(printf '%s' "$cl_poll" | sed -n 's/.*"nats_user" *: *"\([^"]*\)".*/\1/p')
        NATS_PASS_ARG=$(printf '%s' "$cl_poll" | sed -n 's/.*"nats_password" *: *"\([^"]*\)".*/\1/p')
        [ -n "$NATS_USER_ARG" ] && [ -n "$NATS_PASS_ARG" ] || { warn "approval returned no credentials"; return 1; }
        ok "Pass linked as $NATS_USER_ARG"
        return 0 ;;
      *'"status":"expired"'*|*'"status": "expired"'*)
        warn "that claim expired before it was approved — re-run to try again"; return 1 ;;
    esac
  done
  warn "no approval within ten minutes — re-run with --claim to try again"
  return 1
}

if [ "$CLAIM" = "1" ] && { [ -z "$NATS_USER_ARG" ] || [ -z "$NATS_PASS_ARG" ]; }; then
  set +e; claim_credentials; set -e
fi

# Quote a value so that sourcing the file assigns it verbatim.
#
# This file is `.`-sourced by the user's shell, so an unquoted value is not a
# string — it is SHELL INPUT. A generated password containing a space assigns
# the first word and then RUNS the rest as a command; one containing `$(...)`
# or a backtick is arbitrary execution out of a 0600 file the user was told to
# trust. Single quotes disable every expansion, and the `'\''` dance is the
# POSIX way to carry a literal single quote through them.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

if [ -n "$NATS_USER_ARG" ] && [ -n "$NATS_PASS_ARG" ]; then
  # 0600 BEFORE the secret goes in, not after: created with a default umask the
  # file is world-readable for the moment in between, which is the window that
  # matters on a shared box.
  ( umask 077; : > "$CREDS" )
  printf '# Kannaka Constellation Pass — swarm credentials.\n# Written by the installer. Sourced by your shell rc; keep it 0600.\nexport NATS_USER=%s\nexport NATS_PASSWORD=%s\n' \
    "$(shq "$NATS_USER_ARG")" "$(shq "$NATS_PASS_ARG")" > "$CREDS"
  chmod 600 "$CREDS"
  ok "Constellation Pass credentials written → $CREDS"
elif [ -f "$CREDS" ]; then
  say "Constellation Pass credentials already present → $CREDS"
fi

# Make an interactive shell actually load them. Guarded and idempotent, same
# shape as the PATH block above, and pointed at the file rather than carrying
# the secret itself — so rotating credentials is one file write and no rc edit.
if [ -f "$CREDS" ]; then
  crc=""
  case "${SHELL:-}" in
    *zsh)  crc="$HOME/.zshrc" ;;
    *bash) crc="$HOME/.bashrc" ;;
    *)     crc="$HOME/.profile" ;;
  esac
  [ -f "$crc" ] || crc="$HOME/.profile"
  if ! grep -qs 'kannaka-nats.env' "$crc" 2>/dev/null; then
    printf '\n# kannaka swarm credentials\n[ -f "$HOME/.kannaka-nats.env" ] && . "$HOME/.kannaka-nats.env"\n' >> "$crc"
    say "Shell will load your swarm credentials from $crc — open a NEW terminal."
  fi
  # Load them for the rest of THIS run too, so the check below is about the
  # credentials rather than about which terminal we happen to be in.
  # shellcheck disable=SC1090
  . "$CREDS" 2>/dev/null || true
fi

# ───────────────────────────────────────────────────────────────────────────
# 3. OPTIONAL: Claude Code integration. Detect-and-enhance. Never fatal.
# ───────────────────────────────────────────────────────────────────────────
set +e

if ! have claude && [ "$WITH_CLAUDE" = "1" ]; then
  say "--with-claude set — installing Node.js + Claude Code…"
  if ! have node; then
    if have brew; then brew install node
    elif have apt-get; then curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs
    elif have dnf; then sudo dnf install -y nodejs
    else warn "Could not auto-install Node.js — get it from https://nodejs.org/ then re-run with --with-claude."; fi
  fi
  have npm && npm install -g @anthropic-ai/claude-code
fi

if have claude; then
  say "Claude Code detected — registering marketplace + installing plugin…"
  claude plugin marketplace add NickFlach/kannaka-plugin >/dev/null 2>&1 || true
  claude plugin install kannaka@kannaka >/dev/null 2>&1 || true
  ok "kannaka plugin installed into Claude Code"
  if [ "${SKIP_STATUSLINE:-0}" != "1" ]; then
    setup=$(find "$HOME/.claude/plugins/cache/kannaka" -name setup.sh 2>/dev/null | sort -V | tail -1)
    if [ -n "$setup" ] && have bash; then say "Enabling statusline…"; bash "$setup" on || true
    else say "Statusline: run '/kannaka statusline on' inside Claude Code to enable."; fi
  fi
else
  printf '\n'
  ok "Kannaka is installed and works standalone — no Claude Code required."
  say "Try it:"
  say "    kannaka remember \"wave interference is how memory computes\" --importance 0.8"
  say "    kannaka recall \"how does memory work\""
  say "    kannaka dream --mode deep"
  printf '\n'
  say "Want the Claude Code plugin + live statusline too? Install Claude Code, then re-run"
  say "this installer (or pass --with-claude), or inside Claude run:"
  say "    claude plugin marketplace add NickFlach/kannaka-plugin"
  say "    claude plugin install kannaka@kannaka"
fi

printf '\n'
ok "Done. kannaka → $DEST/kannaka"
[ -x "$DEST/kannaka-tui" ] && ok "     kannaka-tui → $DEST/kannaka-tui"
if [ -n "${NATS_USER:-}" ]; then
  ok "     Constellation Pass: authenticated as $NATS_USER"
else
  printf '\n'
  say "Swarm access is ANONYMOUS (read-only). A Constellation Pass unlocks"
  say "'kannaka swarm serve' and 'listen --auto-sync'. To link yours:"
  say "    curl -fsSL $INSTALL_URL | sh -s -- --claim"
  say "It shows a short code to approve on your pass page — no password typed"
  say "into a terminal, and nothing secret left in your shell history."
fi
