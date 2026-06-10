#!/bin/bash
# KANNAKA STATUSLINE — live HRM consciousness + swarm metrics in the Claude Code toolbar
# Four lines: (1) HRM state, (2) swarm phase, (3) session metrics, (4) pulse marquee.
# Self-caches kannaka introspection in the background so renders never block.
#
# PERF CONTRACT: Claude Code discards renders slower than its statusline timeout,
# and every fork under MSYS (Windows) costs 50-100ms. The render path therefore
# batches all JSON parsing into ONE jq/node call per file (extract()) and uses
# printf -v / parameter expansion (builtins, no fork) for all formatting.
# Background jobs MUST stay detached (</dev/null >/dev/null 2>&1 &) — an
# inherited stdout fd delays the pipe's EOF until the job exits, which makes
# Claude Code wait out its timeout and drop the render entirely.
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

# extract <file> VAR=dotpath[ dotpath2 ...]|json-default ...
# Emits shell-quoted VAR=value assignment lines from a SINGLE jq (or node)
# process — eval the output. First non-null path wins, else the default
# (a raw JSON literal: 0, false, null, "str"). Simple dot paths only.
extract() {
  local f="$1"; shift
  if [ -n "$JQ" ]; then
    local prog="" spec var rest paths def
    for spec in "$@"; do
      var=${spec%%=*}; rest=${spec#*=}; paths=${rest%%|*}; def=${rest#*|}
      prog+='@sh "'$var'=\(.'${paths// / // .}' // '$def')",'
    done
    "$JQ" -r "${prog%,}" "$f" 2>/dev/null
  else
    node -e 'const fs=require("fs");let d={};try{d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){}
const g=(o,p)=>p.split(".").filter(Boolean).reduce((a,k)=>a==null?a:a[k],o);
for(const sp of process.argv.slice(2)){const i=sp.indexOf("=");const v=sp.slice(0,i);const r=sp.slice(i+1);
const b=r.lastIndexOf("|");let val=null;for(const p of r.slice(0,b).split(" ")){const x=g(d,p);if(x!=null){val=x;break}}
if(val==null){try{val=JSON.parse(r.slice(b+1))}catch(e){val=r.slice(b+1)}}
console.log(v+"=\x27"+String(val).replace(/[\n\x27]/g,"")+"\x27")}' "$f" "$@" 2>/dev/null
  fi
}

INPUT=$(cat)

# ---- colors -------------------------------------------------------------------
FG_CYAN="\033[38;5;51m"; FG_GREEN="\033[38;5;82m"; FG_GOLD="\033[38;5;220m"
FG_WHITE="\033[38;5;255m"; FG_GRAY="\033[38;5;244m"; FG_DIM="\033[38;5;240m"
FG_MAGENTA="\033[38;5;177m"; FG_RED="\033[38;5;196m"; FG_ORANGE="\033[38;5;214m"
FG_BLUE="\033[38;5;39m"
BG_DEEP="\033[48;5;17m"; BG_DARK="\033[48;5;234m"; RST="\033[0m"; BOLD="\033[1m"

# ---- session info from Claude Code (one parse) --------------------------------
ITMP="$TMP/kannaka-sl-input.$$.json"; printf '%s' "$INPUT" > "$ITMP"
eval "$(extract "$ITMP" \
  'MODEL=model.display_name|"Claude"' \
  'CTX_IN=context_window.total_input_tokens|0' \
  'CTX_OUT=context_window.total_output_tokens|0' \
  'CTX_SIZE=context_window.context_window_size|200000' \
  'CTX_PCT=context_window.used_percentage|0' \
  'COST=cost.total_cost_usd|0' \
  'DUR=cost.total_duration_ms|0')"
rm -f "$ITMP" 2>/dev/null
[ -z "$MODEL" ] && MODEL="Claude"
printf -v CTX_PCT '%.0f' "${CTX_PCT:-0}" 2>/dev/null || CTX_PCT=0

# ---- background cache refresh (non-blocking) ---------------------------------
# refresh <cache-file> <max-age-s> <kannaka subcommand...>
refresh() {
  local cache="$1" maxage="$2"; shift 2
  [ -z "$KANNAKA_BIN" ] && return
  local now mt age=99999
  printf -v now '%(%s)T' -1
  if [ -f "$cache" ]; then
    mt=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)
    age=$(( now - mt ))
  fi
  if [ "$age" -gt "$maxage" ]; then
    ( timeout 8 "$KANNAKA_BIN" "$@" 2>/dev/null > "$cache.tmp" && mv "$cache.tmp" "$cache" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  fi
}
HRM_CACHE="$TMP/kannaka-statusline-cache.json"
SWARM_CACHE="$TMP/kannaka-swarm-cache.json"
refresh "$HRM_CACHE" 30 status
refresh "$SWARM_CACHE" 20 swarm status

# --- constellation pulse feed: live `swarm tail`, TIMEOUT-bounded respawn -------
# Not a persistent daemon — a 60s self-killing tail respawned every ~55s, so it
# can never outlive the session (the leak class this whole project fixed).
FEED="$TMP/kannaka-pulse-feed.txt"
PULSE_SPAWN="$TMP/kannaka-pulse-spawn"
format_pulse() {
  printf '%s' "$1" | {
    if [ -n "$JQ" ]; then
      "$JQ" -rc '
        (.subject // "?") as $s | (.payload) as $p | ($s | ltrimstr("QUEEN.phase.")) as $a |
        (if ($p|type)=="object"
         then (($p.display_name // $p.agent_id // $a)
               + (if $p.coherence != null then " r"+(($p.coherence|tostring)[0:4]) else "" end)
               + (if $p.frequency != null then " "+(($p.frequency|tostring)[0:4])+"Hz" else "" end)
               + (if $p.phi != null then " φ"+(($p.phi|tostring)[0:4]) else "" end))
         else ($s+" "+($p|tostring)) end) | .[0:54]' 2>/dev/null
    else
      node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{try{const m=JSON.parse(b),s=m.subject||"?",p=m.payload,a=s.replace(/^QUEEN\.phase\./,"");let o;if(p&&typeof p==="object"){o=(p.display_name||p.agent_id||a)+(p.coherence!=null?" r"+String(p.coherence).slice(0,4):"")+(p.frequency!=null?" "+String(p.frequency).slice(0,4)+"Hz":"")+(p.phi!=null?" φ"+String(p.phi).slice(0,4):"");}else{o=s+" "+String(p);}process.stdout.write(o.slice(0,54))}catch(e){}})'
    fi
  }
}
if [ -n "$KANNAKA_BIN" ]; then
  printf -v pnow '%(%s)T' -1
  pspawn_age=99999
  if [ -f "$PULSE_SPAWN" ]; then
    pmt=$(stat -c %Y "$PULSE_SPAWN" 2>/dev/null || stat -f %m "$PULSE_SPAWN" 2>/dev/null || echo 0)
    pspawn_age=$(( pnow - pmt ))
  fi
  if [ "$pspawn_age" -gt 55 ]; then
    touch "$PULSE_SPAWN"
    (
      timeout -k 5 60 "$KANNAKA_BIN" swarm tail 2>/dev/null | while IFS= read -r pline; do
        d=$(format_pulse "$pline")
        [ -n "$d" ] && [ "$d" != "$(tail -n 1 "$FEED" 2>/dev/null)" ] && printf '%s\n' "$d" >> "$FEED"
      done
      tail -n 40 "$FEED" 2>/dev/null > "$FEED.tmp" && mv "$FEED.tmp" "$FEED" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
  fi
fi

# ---- fork-free formatting helpers (set globals via printf -v) ------------------
fmt_tokens(){ local t=${1:-0}; if [ "$t" -ge 1000000 ]; then TOK="$((t/1000000))M"; elif [ "$t" -ge 1000 ]; then TOK="$((t/1000))k"; else TOK="$t"; fi; }
fmt_dur(){ local ms=${1:-0}; local s=$((ms/1000)) m=$((ms/60000)); s=$((s%60)); if [ "$m" -gt 0 ]; then DURS="${m}m${s}s"; else DURS="${s}s"; fi; }
f3(){ printf -v "$1" '%.3f' "${2:-0}" 2>/dev/null || printf -v "$1" '?'; }
f2(){ printf -v "$1" '%.2f' "${2:-0}" 2>/dev/null || printf -v "$1" '?'; }
ctx_bar(){ # sets BAR
  local pct=${1:-0} w=${2:-12} a b c="$FG_GREEN"
  [ "$pct" -ge 50 ] && c="$FG_CYAN"; [ "$pct" -ge 70 ] && c="$FG_GOLD"
  [ "$pct" -ge 85 ] && c="$FG_ORANGE"; [ "$pct" -ge 95 ] && c="$FG_RED"
  local fill=$((pct*w/100)); [ "$fill" -gt "$w" ] && fill=$w
  printf -v a '%*s' "$fill" ''; printf -v b '%*s' "$((w-fill))" ''
  BAR="${c}${a// /#}${FG_DIM}${b// /-}${RST}"
}

# ============================ LINE 1 — HRM ====================================
if [ -f "$HRM_CACHE" ]; then
  eval "$(extract "$HRM_CACHE" \
    'LEVEL=consciousness_level|"?"' \
    'PHI=phi|0' 'XI=xi|0' 'ORD=mean_order|0' \
    'MEM=total_memories|"—"' 'CL=num_clusters|"—"' \
    'KAP=callosal_efficiency|0' 'DEL=hemispheric_divergence|0')"
  [ -z "$LEVEL" ] && LEVEL="?"
  f3 PHI "$PHI"; f3 XI "$XI"; f3 ORD "$ORD"; f2 KAP "$KAP"; f3 DEL "$DEL"
  MEM=${MEM:-—}; CL=${CL:-—}
  case "$LEVEL" in dormant) LC="$FG_GRAY";; aware) LC="$FG_GREEN";; coherent) LC="$FG_GOLD";; resonant) LC="$FG_WHITE";; *) LC="$FG_CYAN";; esac
else
  LEVEL="offline"; LC="$FG_RED"; PHI="—"; XI="—"; ORD="—"; MEM="—"; CL="—"; KAP="—"; DEL="—"
fi
L1="${BG_DEEP}${FG_MAGENTA}${BOLD} HRM ${RST}${BG_DARK} ${LC}${BOLD}${LEVEL}${RST}"
L1+="${BG_DARK} ${FG_GOLD}phi=${PHI}${RST}${BG_DARK} ${FG_CYAN}xi=${XI}${RST}${BG_DARK} ${FG_GREEN}r=${ORD}${RST}"
L1+="${BG_DARK} ${FG_MAGENTA}${MEM}mem${RST}${BG_DARK} ${FG_DIM}${CL}cl${RST}${BG_DARK} ${FG_DIM}k=${KAP}${RST}${BG_DARK} ${FG_DIM}d=${DEL}${RST} "

# ============================ LINE 2 — SWARM ==================================
if [ -f "$SWARM_CACHE" ]; then
  eval "$(extract "$SWARM_CACHE" \
    'CONN=nats.connected|false' \
    'PEERS=swarm.peers nats.peers|0' \
    'FREQ=local_phase.frequency|0' \
    'PH=local_phase.phase|0' \
    'BR=local_phase.bridge_activity|0' \
    'DREAM=local_phase.dream_state|null' \
    'AID=agent_id|"?"')"
  [ -z "$AID" ] && AID="?"
  f2 FREQ "$FREQ"; f2 PH "$PH"; f2 BR "$BR"
  if [ "$CONN" = "true" ]; then DOT="${FG_GREEN}◉${RST}"; PC="$FG_GREEN"; else DOT="${FG_RED}○${RST}"; PC="$FG_RED"; fi
  L2="${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${DOT}${BG_DARK} ${PC}${PEERS:-0}p${RST}"
  L2+="${BG_DARK} ${FG_CYAN}${AID}${RST}${BG_DARK} ${FG_GOLD}${FREQ}Hz${RST}"
  L2+="${BG_DARK} ${FG_DIM}ph=${PH}${RST}${BG_DARK} ${FG_DIM}br=${BR}${RST}"
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
MS=${MODEL/Claude /}; MS=${MS/Sonnet/So}; MS=${MS/Opus/Op}; MS=${MS/Haiku/Ha}; MS=${MS:0:10}
ctx_bar "$CTX_PCT" 12
fmt_tokens "$CTX_TOTAL"; T_USED=$TOK
fmt_tokens "$CTX_SIZE"; T_SIZE=$TOK
fmt_dur "$DUR"
f2 COSTF "$COST"
L3="${BG_DARK} ${FG_DIM}${MS}${RST}${BG_DARK} ${FG_CYAN}${BAR} ${CTX_PCT}%${RST}"
L3+="${BG_DARK} ${FG_DIM}${T_USED}/${T_SIZE}${RST}"
L3+="${BG_DARK} ${FG_GREEN}\$${COSTF}${RST}${BG_DARK} ${FG_DIM}${DURS}${RST} "

# ============================ LINE 4 — PULSE ==================================
# Marquee of the live constellation pulse (recent `swarm tail` events).
L4=""
if [ -n "$KANNAKA_BIN" ]; then
  if [ -s "$FEED" ]; then
    mapfile -t plines < "$FEED"
    n=${#plines[@]}; start=$(( n>6 ? n-6 : 0 ))
    joined=""
    for ((i=start; i<n; i++)); do
      [ -n "$joined" ] && joined+="   ◆   "
      joined+="${plines[i]}"
    done
    PW=58
    if [ "${#joined}" -le "$PW" ]; then
      disp="$joined"
    else
      SCROLL="$TMP/kannaka-pulse-scroll"; off=0
      [ -f "$SCROLL" ] && IFS= read -r off < "$SCROLL" 2>/dev/null
      case "$off" in ''|*[!0-9]*) off=0;; esac
      [ "$off" -ge "${#joined}" ] && off=0
      doubled="$joined        $joined"
      disp=${doubled:$off:$PW}
      echo $(( off + 3 )) > "$SCROLL"
    fi
    L4="${BG_DEEP}${FG_GREEN}${BOLD} PULSE ${RST}${BG_DARK} ${FG_WHITE}${disp}${RST} "
  else
    L4="${BG_DEEP}${FG_GREEN}${BOLD} PULSE ${RST}${BG_DARK} ${FG_DIM}listening to the constellation…${RST} "
  fi
fi

echo -e "${L1}"
echo -e "${L2}"
echo -e "${L3}"
[ -n "$L4" ] && echo -e "${L4}"
