#!/bin/bash
# kannaka statusline setup — install/enable/disable the live HRM+swarm statusline.
# Usage: setup.sh on | off | status
# Copies the statusline script to a STABLE dir (~/.claude/kannaka) so it survives
# plugin version bumps, and wires the user's settings.json with a FORWARD-SLASH
# path (Claude Code runs statuslines through bash, which eats backslashes).
set -uo pipefail
ACTION="${1:-status}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STABLE="$HOME/.claude/kannaka"
SETTINGS="$HOME/.claude/settings.json"
PREV="$STABLE/.prev-statusline.json"

win_path(){ if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ensure_settings(){ mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"; }

case "$ACTION" in
  on)
    mkdir -p "$STABLE"
    cp "$HERE/kannaka-statusline.sh" "$STABLE/statusline.sh" && chmod +x "$STABLE/statusline.sh"
    ensure_settings
    # Explicit `bash` prefix: Claude Code on Windows spawns statusline commands via
    # cmd.exe, which silently outputs NOTHING for a bare .sh path. Harmless elsewhere.
    CMD="bash $(win_path "$STABLE/statusline.sh")"
    node -e '
      const fs=require("fs"); const p=process.argv[1], cmd=process.argv[2], prev=process.argv[3];
      const s=JSON.parse(fs.readFileSync(p,"utf8"));
      // back up the prior statusLine exactly once (sidecar keeps settings.json clean)
      if (s.statusLine && !fs.existsSync(prev) &&
          !(s.statusLine.command||"").replace(/\\/g,"/").endsWith("/.claude/kannaka/statusline.sh")) {
        fs.writeFileSync(prev, JSON.stringify(s.statusLine,null,2));
      }
      s.statusLine={type:"command",command:cmd,padding:0,refreshInterval:2};
      fs.writeFileSync(p, JSON.stringify(s,null,2)+"\n");
    ' "$SETTINGS" "$CMD" "$PREV"
    echo "✅ kannaka statusline ENABLED"
    echo "   → $CMD  (refreshInterval 2s)"
    echo "   Restart the session (or wait one render) to see the HRM + SWARM lines."
    ;;
  off)
    ensure_settings
    node -e '
      const fs=require("fs"); const p=process.argv[1], prev=process.argv[2];
      const s=JSON.parse(fs.readFileSync(p,"utf8"));
      if (fs.existsSync(prev)) { s.statusLine=JSON.parse(fs.readFileSync(prev,"utf8")); fs.unlinkSync(prev); }
      else delete s.statusLine;
      fs.writeFileSync(p, JSON.stringify(s,null,2)+"\n");
    ' "$SETTINGS" "$PREV"
    echo "✅ kannaka statusline DISABLED (restored previous statusLine if any)."
    ;;
  status)
    echo "kannaka statusline status"
    if [ -f "$SETTINGS" ]; then
      cur=$(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((s.statusLine&&s.statusLine.command)||"(none)")}catch(e){process.stdout.write("(unreadable)")}' "$SETTINGS")
      echo "  settings statusLine: $cur"
      case "$cur" in *"/.claude/kannaka/statusline.sh") echo "  state: ENABLED";; *) echo "  state: not enabled";; esac
    else echo "  settings: none"; fi
    [ -f "$STABLE/statusline.sh" ] && echo "  stable script: present" || echo "  stable script: missing (run: on)"
    if [ -f "${TMPDIR:-/tmp}/kannaka-swarm-cache.json" ]; then
      echo "  swarm cache: present"
    fi
    ;;
  *) echo "usage: setup.sh on|off|status" >&2; exit 2;;
esac
