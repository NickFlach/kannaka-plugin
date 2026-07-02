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
WITH_CLAUDE=0
for arg in "$@"; do
  case "$arg" in
    --with-claude) WITH_CLAUDE=1 ;;
    --skip-statusline) SKIP_STATUSLINE=1 ;;
  esac
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
asset="kannaka-${o}-${a}"
base="https://github.com/$RELEASE_REPO/releases/latest/download"

say "Downloading kannaka ($asset)…"
if ! curl -fSL "$base/$asset" -o "$DEST/kannaka"; then
  warn "Failed to download $asset from $base — check your internet connection."
  exit 1
fi
# The release always publishes a per-file .sha256 (Sigstore + checksums trust).
# A MISSING checksum means we cannot verify — fail closed rather than install an
# unverified binary. (Previously verification was nested in the download's `if`,
# so a missing .sha256 silently skipped it and installed unverified.)
if ! curl -fsSL "$base/$asset.sha256" -o "$DEST/.k.sha"; then
  warn "checksum $asset.sha256 could not be downloaded — refusing to install an unverified binary"
  rm -f "$DEST/kannaka" "$DEST/.k.sha"; exit 1
fi
want=$(awk '{print $1}' "$DEST/.k.sha"); rm -f "$DEST/.k.sha"
[ -n "$want" ] || { warn "checksum $asset.sha256 was empty — refusing to install unverified"; rm -f "$DEST/kannaka"; exit 1; }
if have sha256sum; then got=$(sha256sum "$DEST/kannaka" | awk '{print $1}')
elif have shasum; then got=$(shasum -a 256 "$DEST/kannaka" | awk '{print $1}')
else warn "no sha256 tool (sha256sum/shasum) available — cannot verify"; rm -f "$DEST/kannaka"; exit 1; fi
[ "$want" = "$got" ] || { warn "kannaka sha256 mismatch (want $want got $got)"; rm -f "$DEST/kannaka"; exit 1; }
say "sha256 verified"
chmod +x "$DEST/kannaka"
ok "kannaka binary installed → $DEST/kannaka"

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
