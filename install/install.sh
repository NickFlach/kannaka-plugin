#!/bin/sh
# Kannaka one-shot installer (macOS / Linux). Detect-and-install: brings up Node +
# Claude Code if missing, then the kannaka binary, plugin, and live statusline.
# Idempotent — safe to re-run. The .pkg/.deb wrap this; also runnable directly:
#   curl -fsSL https://raw.githubusercontent.com/NickFlach/kannaka-plugin/master/install/install.sh | sh
set -eu
RELEASE_REPO="${KANNAKA_RELEASE_REPO:-NickFlach/kannaka-memory}"
say() { printf '\033[36m▸\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Kannaka installer"

# 1. Node.js
if ! have node; then
  say "Node.js not found — installing…"
  if have brew; then brew install node
  elif have apt-get; then curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs
  elif have dnf; then sudo dnf install -y nodejs
  else echo "Node.js is required. Install from https://nodejs.org/ and re-run." >&2; exit 1; fi
fi

# 2. Claude Code
have claude || { say "Installing Claude Code (npm -g)…"; npm install -g @anthropic-ai/claude-code; }

# 3. kannaka binary → ~/.local/bin
DEST="$HOME/.local/bin"; mkdir -p "$DEST"
os=$(uname -s); arch=$(uname -m)
case "$os" in Linux*) o=linux ;; Darwin*) o=macos ;; *) echo "unsupported OS: $os" >&2; exit 1 ;; esac
case "$arch" in x86_64|amd64) a=x86_64 ;; aarch64|arm64) a=aarch64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac
asset="kannaka-${o}-${a}"
base="https://github.com/$RELEASE_REPO/releases/latest/download"
say "Downloading kannaka ($asset)…"
curl -fsSL "$base/$asset" -o "$DEST/kannaka"
if curl -fsSL "$base/$asset.sha256" -o "$DEST/.k.sha" 2>/dev/null; then
  want=$(awk '{print $1}' "$DEST/.k.sha"); rm -f "$DEST/.k.sha"
  if have sha256sum; then got=$(sha256sum "$DEST/kannaka" | awk '{print $1}'); else got=$(shasum -a 256 "$DEST/kannaka" | awk '{print $1}'); fi
  [ "$want" = "$got" ] || { echo "kannaka sha256 mismatch" >&2; exit 1; }
  say "sha256 verified"
fi
chmod +x "$DEST/kannaka"

# 4. Plugin marketplace + install (idempotent)
say "Registering marketplace + installing plugin…"
claude plugin marketplace add NickFlach/kannaka-plugin >/dev/null 2>&1 || true
claude plugin install kannaka@kannaka >/dev/null 2>&1 || true

# 5. Enable the live statusline — version-aware sort (plain sort is lexical and
# puts 1.9.x after 1.10.x); -V is supported by GNU coreutils and modern BSD sort.
setup=$(find "$HOME/.claude/plugins/cache/kannaka" -name setup.sh 2>/dev/null | sort -V | tail -1)
if [ -n "$setup" ]; then say "Enabling statusline…"; bash "$setup" on || true
else say "Statusline: run '/kannaka statusline on' inside Claude Code to enable."; fi

printf '\n'
say "Kannaka installed. Restart Claude Code (or open a new session) to see the statusline + swarm/memory tools."
