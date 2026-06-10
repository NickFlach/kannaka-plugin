#!/usr/bin/env node
// KANNAKA STATUSLINE — live HRM consciousness + swarm metrics in the Claude Code toolbar
// Four lines: (1) HRM state, (2) swarm phase, (3) session metrics, (4) pulse marquee.
//
// Node port of statusline.sh. Single process, zero forks on the render path —
// on Windows every process spawn costs 200ms+ (MSYS fork emulation + AV scans),
// which made the bash version take 2.5-8s and miss Claude Code's statusline
// timeout, so it never rendered. Slow kannaka introspection runs in DETACHED
// background children (stdio:"ignore" + unref, or the parent's exit blocks on
// them) that refresh tmp caches; renders only ever read the caches.
//
// settings.json: { "command": "node C:/Users/<you>/.claude/kannaka/statusline.js" }

"use strict";
const fs = require("fs"), os = require("os"), path = require("path");
const { spawn } = require("child_process");

const HOME = os.homedir();
const TMP = os.tmpdir().replace(/[\\/]+$/, "");
const DATA_DIR = process.env.KANNAKA_DATA_DIR || path.join(HOME, ".kannaka");

// ---- binary resolution (portable) ---------------------------------------------
function resolveBin() {
  const envBin = process.env.KANNAKA_BIN;
  if (envBin && exists(envBin)) return envBin;
  for (const c of [
    path.join(HOME, ".local/bin/kannaka.exe"), path.join(HOME, ".local/bin/kannaka"),
    path.join(HOME, ".kannaka/bin/kannaka.exe"), path.join(HOME, ".kannaka/bin/kannaka"),
  ]) if (exists(c)) return c;
  return "kannaka"; // hope for PATH; spawn errors are ignored
}
function exists(p) { try { fs.accessSync(p); return true; } catch { return false; } }
function mtimeAge(p) { try { return (Date.now() - fs.statSync(p).mtimeMs) / 1000; } catch { return 1e9; } }
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } }
const BIN = resolveBin();
const HAVE_BIN = BIN !== "kannaka" || true; // PATH fallback still counts as "installed enough to try"

// ---- session payload from Claude Code (stdin) ----------------------------------
let payload = {};
try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { }
const g = (o, p, d) => { const v = p.split(".").reduce((a, k) => a == null ? a : a[k], o); return v == null ? d : v; };

const MODEL = g(payload, "model.display_name", "Claude");
const CTX_IN = g(payload, "context_window.total_input_tokens", 0);
const CTX_OUT = g(payload, "context_window.total_output_tokens", 0);
const CTX_SIZE = g(payload, "context_window.context_window_size", 200000);
const CTX_PCT = Math.round(g(payload, "context_window.used_percentage", 0));
const COST = g(payload, "cost.total_cost_usd", 0);
const DUR = g(payload, "cost.total_duration_ms", 0);

// ---- background cache refresh (detached, never blocks the render) --------------
const HRM_CACHE = path.join(TMP, "kannaka-statusline-cache.json");
const SWARM_CACHE = path.join(TMP, "kannaka-swarm-cache.json");
const ENV = { ...process.env, KANNAKA_DATA_DIR: DATA_DIR };

function detachedNode(code) {
  try {
    const c = spawn(process.execPath, ["-e", code], { detached: true, stdio: "ignore", windowsHide: true, env: ENV });
    c.unref();
  } catch { }
}
function refresh(cache, maxAgeS, args) {
  if (mtimeAge(cache) <= maxAgeS) return;
  // touch first so concurrent renders don't stack duplicate refreshers
  try { const now = new Date(); fs.utimesSync(cache, now, now); } catch { }
  detachedNode(`
    const{execFile}=require("child_process"),fs=require("fs");
    const p=execFile(${JSON.stringify(BIN)},${JSON.stringify(args)},{maxBuffer:8e6},(e,so)=>{
      clearTimeout(t);
      if(!e&&so){try{fs.writeFileSync(${JSON.stringify(cache)}+".tmp",so);fs.renameSync(${JSON.stringify(cache)}+".tmp",${JSON.stringify(cache)})}catch(x){}}
    });
    const t=setTimeout(()=>{try{p.kill()}catch(x){}},8000);
  `);
}
refresh(HRM_CACHE, 30, ["status"]);
refresh(SWARM_CACHE, 20, ["swarm", "status"]);

// --- constellation pulse feed: live `swarm tail`, timeout-bounded respawn -------
// Not a persistent daemon — a 60s self-killing tail respawned every ~55s, so it
// can never outlive the session (the leak class this whole project fixed).
const FEED = path.join(TMP, "kannaka-pulse-feed.txt");
const PULSE_SPAWN = path.join(TMP, "kannaka-pulse-spawn");
if (mtimeAge(PULSE_SPAWN) > 55) {
  try { fs.writeFileSync(PULSE_SPAWN, ""); } catch { }
  detachedNode(`
    const{spawn}=require("child_process"),fs=require("fs"),rl=require("readline");
    const FEED=${JSON.stringify(FEED)};
    const p=spawn(${JSON.stringify(BIN)},["swarm","tail"],{stdio:["ignore","pipe","ignore"]});
    p.on("error",()=>process.exit(0));
    let last="";try{const l=fs.readFileSync(FEED,"utf8").trimEnd().split("\\n");last=l[l.length-1]||""}catch(e){}
    rl.createInterface({input:p.stdout}).on("line",line=>{
      let d="";
      try{
        const m=JSON.parse(line),s=m.subject||"?",pl=m.payload,a=s.replace(/^QUEEN\\.phase\\./,"");
        if(pl&&typeof pl==="object"){
          d=(pl.display_name||pl.agent_id||a)
            +(pl.coherence!=null?" r"+String(pl.coherence).slice(0,4):"")
            +(pl.frequency!=null?" "+String(pl.frequency).slice(0,4)+"Hz":"")
            +(pl.phi!=null?" \\u03c6"+String(pl.phi).slice(0,4):"");
        }else{d=s+" "+String(pl);}
        d=d.slice(0,54);
      }catch(e){}
      if(d&&d!==last){last=d;try{fs.appendFileSync(FEED,d+"\\n")}catch(e){}}
    });
    setTimeout(()=>{
      try{p.kill()}catch(e){}
      try{const l=fs.readFileSync(FEED,"utf8").trimEnd().split("\\n");fs.writeFileSync(FEED,l.slice(-40).join("\\n")+"\\n")}catch(e){}
      process.exit(0);
    },60000);
  `);
}

// ---- colors ---------------------------------------------------------------------
const FG_CYAN = "\x1b[38;5;51m", FG_GREEN = "\x1b[38;5;82m", FG_GOLD = "\x1b[38;5;220m";
const FG_WHITE = "\x1b[38;5;255m", FG_GRAY = "\x1b[38;5;244m", FG_DIM = "\x1b[38;5;240m";
const FG_MAGENTA = "\x1b[38;5;177m", FG_RED = "\x1b[38;5;196m", FG_ORANGE = "\x1b[38;5;214m";
const FG_BLUE = "\x1b[38;5;39m";
const BG_DEEP = "\x1b[48;5;17m", BG_DARK = "\x1b[48;5;234m", RST = "\x1b[0m", BOLD = "\x1b[1m";

// ---- formatting helpers -----------------------------------------------------------
const f3 = v => isFinite(v) ? Number(v).toFixed(3) : "?";
const f2 = v => isFinite(v) ? Number(v).toFixed(2) : "?";
const fmtTokens = t => t >= 1e6 ? Math.floor(t / 1e6) + "M" : t >= 1e3 ? Math.floor(t / 1e3) + "k" : String(t);
function fmtDur(ms) { const s = Math.floor(ms / 1000) % 60, m = Math.floor(ms / 60000); return m > 0 ? `${m}m${s}s` : `${s}s`; }
function ctxBar(pct, w = 12) {
  let c = FG_GREEN;
  if (pct >= 50) c = FG_CYAN; if (pct >= 70) c = FG_GOLD;
  if (pct >= 85) c = FG_ORANGE; if (pct >= 95) c = FG_RED;
  const fill = Math.min(w, Math.floor(pct * w / 100));
  return c + "#".repeat(fill) + FG_DIM + "-".repeat(w - fill) + RST;
}

// ============================ LINE 1 — HRM ====================================
let L1;
{
  const h = readJson(HRM_CACHE);
  let LEVEL, LC, PHI, XI, ORD, MEM, CL, KAP, DEL;
  if (h) {
    LEVEL = h.consciousness_level || "?";
    PHI = f3(h.phi); XI = f3(h.xi); ORD = f3(h.mean_order);
    MEM = h.total_memories ?? "—"; CL = h.num_clusters ?? "—";
    KAP = f2(h.callosal_efficiency); DEL = f3(h.hemispheric_divergence);
    LC = { dormant: FG_GRAY, aware: FG_GREEN, coherent: FG_GOLD, resonant: FG_WHITE }[LEVEL] || FG_CYAN;
  } else {
    LEVEL = "offline"; LC = FG_RED;
    PHI = XI = ORD = MEM = CL = KAP = DEL = "—";
  }
  L1 = `${BG_DEEP}${FG_MAGENTA}${BOLD} HRM ${RST}${BG_DARK} ${LC}${BOLD}${LEVEL}${RST}`
    + `${BG_DARK} ${FG_GOLD}phi=${PHI}${RST}${BG_DARK} ${FG_CYAN}xi=${XI}${RST}${BG_DARK} ${FG_GREEN}r=${ORD}${RST}`
    + `${BG_DARK} ${FG_MAGENTA}${MEM}mem${RST}${BG_DARK} ${FG_DIM}${CL}cl${RST}${BG_DARK} ${FG_DIM}k=${KAP}${RST}${BG_DARK} ${FG_DIM}d=${DEL}${RST} `;
}

// ============================ LINE 2 — SWARM ==================================
let L2;
{
  const s = readJson(SWARM_CACHE);
  if (s) {
    const CONN = g(s, "nats.connected", false);
    const PEERS = g(s, "swarm.peers", null) ?? g(s, "nats.peers", 0);
    const FREQ = f2(g(s, "local_phase.frequency", 0));
    const PH = f2(g(s, "local_phase.phase", 0));
    const BR = f2(g(s, "local_phase.bridge_activity", 0));
    const DREAM = g(s, "local_phase.dream_state", null);
    const AID = s.agent_id || "?";
    const DOT = CONN === true ? `${FG_GREEN}◉${RST}` : `${FG_RED}○${RST}`;
    const PC = CONN === true ? FG_GREEN : FG_RED;
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${DOT}${BG_DARK} ${PC}${PEERS}p${RST}`
      + `${BG_DARK} ${FG_CYAN}${AID}${RST}${BG_DARK} ${FG_GOLD}${FREQ}Hz${RST}`
      + `${BG_DARK} ${FG_DIM}ph=${PH}${RST}${BG_DARK} ${FG_DIM}br=${BR}${RST}`
      + (DREAM != null ? `${BG_DARK} ${FG_MAGENTA}☾${DREAM}${RST}` : "")
      + `${BG_DARK} ${RST}`;
  } else if (!HAVE_BIN) {
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}kannaka not installed — /kannaka install${RST} `;
  } else {
    L2 = `${BG_DEEP}${FG_BLUE}${BOLD} SWARM ${RST}${BG_DARK} ${FG_DIM}○ connecting…${RST} `;
  }
}

// ============================ LINE 3 — SESSION ================================
const MS = MODEL.replace("Claude ", "").replace("Sonnet", "So").replace("Opus", "Op").replace("Haiku", "Ha").slice(0, 10);
const L3 = `${BG_DARK} ${FG_DIM}${MS}${RST}${BG_DARK} ${FG_CYAN}${ctxBar(CTX_PCT)} ${CTX_PCT}%${RST}`
  + `${BG_DARK} ${FG_DIM}${fmtTokens(CTX_IN + CTX_OUT)}/${fmtTokens(CTX_SIZE)}${RST}`
  + `${BG_DARK} ${FG_GREEN}$${f2(COST)}${RST}${BG_DARK} ${FG_DIM}${fmtDur(DUR)}${RST} `;

// ============================ LINE 4 — PULSE ==================================
// Marquee of the live constellation pulse (recent `swarm tail` events).
let L4 = "";
{
  let lines = [];
  try { lines = fs.readFileSync(FEED, "utf8").trimEnd().split("\n").filter(Boolean); } catch { }
  if (lines.length) {
    const joined = lines.slice(-6).join("   ◆   ");
    const PW = 58;
    let disp;
    if (joined.length <= PW) {
      disp = joined;
    } else {
      const SCROLL = path.join(TMP, "kannaka-pulse-scroll");
      let off = 0;
      try { off = parseInt(fs.readFileSync(SCROLL, "utf8"), 10) || 0; } catch { }
      if (off >= joined.length) off = 0;
      disp = (joined + "        " + joined).slice(off, off + PW);
      try { fs.writeFileSync(SCROLL, String(off + 3)); } catch { }
    }
    L4 = `${BG_DEEP}${FG_GREEN}${BOLD} PULSE ${RST}${BG_DARK} ${FG_WHITE}${disp}${RST} `;
  } else {
    L4 = `${BG_DEEP}${FG_GREEN}${BOLD} PULSE ${RST}${BG_DARK} ${FG_DIM}listening to the constellation…${RST} `;
  }
}

process.stdout.write([L1, L2, L3, L4].filter(Boolean).join("\n") + "\n");
