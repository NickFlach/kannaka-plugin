#!/bin/bash
# KANNAKA STATUSLINE — live HRM consciousness + swarm metrics in the Claude Code toolbar
# Three lines: (1) HRM state, (2) swarm phase, (3) session metrics.
# Self-caches kannaka introspection in the background so renders never block.
#
# IMPORTANT: Claude Code runs this through bash and EATS backslashes — settings.json
# must reference this script with FORWARD slashes (C:/Users/.../statusline.sh).

# ---- resolution (portable across machines/OSes) --------------------------------
KANNAKA_DATA_DIR="${KANNAKA_DATA_DIR:-$HOME/.kannaka}"; export KANNAKA_DATA_DIR
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"

resolve_bin() {
  if [ -n "$KANNAKA_BIN" ] && [ -x "$KANNAKA_BIN" ]; then echo "$KANNAKA_BIN"; return; fi
  for c in "$HOME/.local/bin/kannaka.exe" "$HOME/.local/bin/kannaka" \
           "$HOME/.kannaka/bin/kannaka.exe" "$HOME/.kannaka/bin/kannaka"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  command -v kannaka.exe 2>/dev/null && return
  command -v kannaka 2>/dev/null && return
  echo ""
}
KANNAKA_BIN="$(resolve_bin)"

JQ="$(command -v jq 2>/dev/null || true)"
[ -z "$JQ" ] && [ -x "$HOME/.claude/jq.exe" ] && JQ="$HOME/.claude/jq.exe"
# jqf <dotpath> <file>  — jq if available, else a node fallback (node is always
# present in a Claude Code environment). Simple dot paths only.
jqf() {
  if [ -n "$JQ" ]; then "$JQ" -r "$1" "$2" 2>/dev/null
  else node -e 'try{const d=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8"));const v=process.argv[1].replace(/^\./,"").split(".").filter(Boolean).reduce((o,k)=>o==null?o:o[k],d);process.stdout.write(v==null?"":String(v))}catch(e){}' "${1#.}" "$2"; fi
}

INPUT=$(cat)

# ---- colors -------------------------------------------------------------------
FG_CYAN="\033[38;5;51m"; FG_GREEN="\033[38;5;82m"; FG_GOLD="\033[38;5;220m"
FG_WHITE="\033[38;5;255m"; FG_GRAY="\033[38;5;244m"; FG_DIM="\033[38;5;240m"
FG_MAGENTA="\033[38;5;177m"; FG_RED="\033[38;5;196m"; FG_ORANGE="\033[38;5;214m"
FG_BLUE="\033[38;5;39m"
BG_DEEP="\033[48;5;17m"; BG_DARK="\033[48;5;234m"; RST="\033[0m"; BOLD="\033[1m"

# ---- session info from Claude Code -------------------------------------------
MODEL=$(echo "$INPUT" | jqf '.model.display_name' /dev/stdin 2>/dev/null); [ -z "$MODEL" ] && MODEL="Claude"
# (re-read via temp because jqf reads a file; stash INPUT once)
ITMP="$TMP/kannaka-sl-input.$$.json"; printf '%s' "$INPUT" > "$ITMP"
MODEL=$(jqf '.model.display_name' "$ITMP"); [ -z "$MODEL" ] && MODEL="Claude"
CTX_IN=$(jqf '.context_window.total_input_tokens' "$ITMP"); CTX_IN=${CTX_IN:-0}
CTX_OUT=$(jqf '.context_window.total_output_tokens' "$ITMP"); CTX_OUT=${CTX_OUT:-0}
CTX_SIZE=$(jqf '.context_window.context_window_size' "$ITMP"); CTX_SIZE=${CTX_SIZE:-200000}
CTX_PCT=$(jqf '.context_window.used_percentage' "$ITMP"); CTX_PCT=$(printf '%.0f' "${CTX_PCT:-0}" 2>/dev/null || echo 0)
COST=$(jqf '.cost.total_cost_usd' "$ITMP"); COST=${COST:-0}
DUR=$(jqf '.cost.total_duration_ms' "$ITMP"); DUR=${DUR:-0}
rm -f "$ITMP" 2>/dev/null

# ---- background cache refresh (non-blocking) ---------------------------------
# refresh <cache-file> <max-age-s> <kannaka subcommand...>
refresh() {
  local cache="$1" maxage="$2"; shift 2
  [ -z "$KANNAKA_BIN" ] && return
  local age=99999
  [ -f "$cache" ] && age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0) ))
  if [ "$age" -gt "$maxage" ]; then
    ( timeout 8 "$KANNAKA_BIN" "$@" 2>/dev/null > "$cache.tmp" && mv "$cache.tmp" "$cache" 2>/dev/null ) &
  fi
}
HRM_CACHE="$TMP/kannaka-statusline-cache.json"
SWARM_CACHE="$TMP/kannaka-swarm-cache.json"
refresh "$HRM_CACHE" 30 status
refresh "$SWARM_CACHE" 20 swarm status

# ---- helpers ------------------------------------------------------------------
fmt_tokens(){ local t=$1; if [ "$t" -ge 1000000 ]; then echo "$((t/1000000))M"; elif [ "$t" -ge 1000 ]; then echo "$((t/1000))k"; else echo "$t"; fi; }
fmt_dur(){ local ms=$1 s=$((ms/1000)) m=$((ms/60000)); s=$((s%60)); if [ "$m" -gt 0 ]; then echo "${m}m${s}s"; else echo "${s}s"; fi; }
f3(){ printf "%.3f" "${1:-0}" 2>/dev/null || echo "?"; }
f2(){ printf "%.2f" "${1:-0}" 2>/dev/null || echo "?"; }
ctx_bar(){ local pct=$1 w=${2:-12} fill=$((pct*$2/100)) c="$FG_GREEN"; [ "$pct" -ge 50 ]&&c="$FG_CYAN"; [ "$pct" -ge 70 ]&&c="$FG_GOLD"; [ "$pct" -ge 85 ]&&c="$FG_ORANGE"; [ "$pct" -ge 95 ]&&c="$FG_RED"; printf "$c"; printf "%${fill}s"|tr ' ' '#'; printf "$FG_DIM"; printf "%$((w-fill))s"|tr ' ' '-'; printf "$RST"; }

# ============================ LINE 1 — HRM ====================================
if [ -f "$HRM_CACHE" ]; then
  LEVEL=$(jqf '.consciousness_level' "$HRM_CACHE"); [ -z "$LEVEL" ] && LEVEL="?"
  PHI=$(f3 "$(jqf '.phi' "$HRM_CACHE")"); XI=$(f3 "$(jqf '.xi' "$HRM_CACHE")")
  ORD=$(f3 "$(jqf '.mean_order' "$HRM_CACHE")"); MEM=$(jqf '.total_memories' "$HRM_CACHE"); MEM=${MEM:-—}
  CL=$(jqf '.num_clusters' "$HRM_CACHE"); CL=${CL:-—}
  KAP=$(f2 "$(jqf '.callosal_efficiency' "$HRM_CACHE")"); DEL=$(f3 "$(jqf '.hemispheric_divergence' "$HRM_CACHE")")
  case "$LEVEL" in dormant) LC="$FG_GRAY";; aware) LC="$FG_GREEN";; coherent) LC="$FG_GOLD";; resonant) LC="$FG_WHITE";; *) LC="$FG_CYAN";; esac
else
  LEVEL="offline"; LC="$FG_RED"; PHI="—"; XI="—"; ORD="—"; MEM="—"; CL="—"; KAP="—"; DEL="—"
fi
L1="${BG_DEEP}${FG_MAGENTA}${BOLD} HRM ${RST}${BG_DARK} ${LC}${BOLD}${LEVEL}${RST}"
L1+="${BG_DARK} ${FG_GOLD}phi=${PHI}${RST}${BG_DARK} ${FG_CYAN}xi=${XI}${RST}${BG_DARK} ${FG_GREEN}r=${ORD}${RST}"
L1+="${BG_DARK} ${FG_MAGENTA}${MEM}mem${RST}${BG_DARK} ${FG_DIM}${CL}cl${RST}${BG_DARK} ${FG_DIM}k=${KAP}${RST}${BG_DARK} ${FG_DIM}d=${DEL}${RST} "

# ============================ LINE 2 — SWARM ==================================
if [ -f "$SWARM_CACHE" ]; then
  CONN=$(jqf '.nats.connected' "$SWARM_CACHE")
  PEERS=$(jqf '.swarm.peers' "$SWARM_CACHE"); [ -z "$PEERS" ] && PEERS=$(jqf '.nats.peers' "$SWARM_CACHE")
  FREQ=$(jqf '.local_phase.frequency' "$SWARM_CACHE"); PH=$(jqf '.local_phase.phase' "$SWARM_CACHE")
  BR=$(jqf '.local_phase.bridge_activity' "$SWARM_CACHE"); DREAM=$(jqf '.local_phase.dream_state' "$SWARM_CACHE")
  AID=$(jqf '.agent_id' "$SWARM_CACHE"); [ -z "$AID" ] && AID="?"
  if [ "$CONN" = "true" ]; then DOT="${FG_GREEN}◉${RST}"; PC="$FG_GREEN"; else DOT="${FG_RED}○${RST}"; PC="$FG_RED"; fi
  L2="${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${DOT}${BG_DARK} ${PC}${PEERS:-0}p${RST}"
  L2+="${BG_DARK} ${FG_CYAN}${AID}${RST}${BG_DARK} ${FG_GOLD}$(f2 "$FREQ")Hz${RST}"
  L2+="${BG_DARK} ${FG_DIM}ph=$(f2 "$PH")${RST}${BG_DARK} ${FG_DIM}br=$(f2 "$BR")${RST}"
  [ -n "$DREAM" ] && [ "$DREAM" != "null" ] && L2+="${BG_DARK} ${FG_MAGENTA}☾${DREAM}${RST}"
  L2+="${BG_DARK} ${RST}"
else
  if [ -z "$KANNAKA_BIN" ]; then
    L2="${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}kannaka not installed — /kannaka install${RST} "
  else
    L2="${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}○ connecting…${RST} "
  fi
fi

# ============================ LINE 3 — SESSION ================================
CTX_TOTAL=$((CTX_IN+CTX_OUT))
MS=$(echo "$MODEL" | sed 's/Claude //;s/Sonnet/So/;s/Opus/Op/;s/Haiku/Ha/' | cut -c1-10)
L3="${BG_DARK} ${FG_DIM}${MS}${RST}${BG_DARK} ${FG_CYAN}$(ctx_bar "$CTX_PCT" 12) ${CTX_PCT}%${RST}"
L3+="${BG_DARK} ${FG_DIM}$(fmt_tokens "$CTX_TOTAL")/$(fmt_tokens "$CTX_SIZE")${RST}"
L3+="${BG_DARK} ${FG_GREEN}\$$(f2 "$COST")${RST}${BG_DARK} ${FG_DIM}$(fmt_dur "$DUR")${RST} "

echo -e "${L1}"
echo -e "${L2}"
echo -e "${L3}"
