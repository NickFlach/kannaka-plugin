// KAX Compute District helpers for the kannaka MCP server — ZERO dependencies
// (Node built-ins only), same rule as kannaka-mcp.mjs.
//
// Wire contract (kax-computer/manager/manager.py):
//   wake   {v:1, machine, id, ts, prompt, signer, sig}            -> KAX.machine.<id>.inbox
//   grant  {v:1, type:"credit_grant", machine, id, ts, credits, signer, sig}
//   sig    = Ed25519 hex over canonical JSON of the envelope minus `sig`, where
//            canonical == Python `json.dumps(obj, sort_keys=True, separators=(",",":"))`
//            (ensure_ascii=True: every non-ASCII code unit is \uXXXX-escaped).
//   The verifier RE-SERIALISES in Python, so numerics must be integers: V8
//   prints 1 where Python prints 1.0 and the signature would never match.
import { createPrivateKey, createPublicKey, sign as cryptoSign, verify as cryptoVerify, randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { connect as netConnect } from "node:net";

export const MINOR_PER_CREDIT = 1_000_000; // 1 credit = 1,000,000 minor units (internal accounting, never a currency rate)
export const MAX_GRANT_CREDITS = 1000;
export const DEFAULT_KAX_API_URL = "https://kax.ninja-portal.com";
export const DEFAULT_NATS_URL = "nats://swarm.ninja-portal.com:4222";
export const SUBJECT_FLEET_STATUS = "KAX.machines.status";
export const SUBJECT_ALL_EVENTS = "KAX.machine.*.events";
export const subjectInbox = (id) => `KAX.machine.${id}.inbox`;
export const subjectOutbox = (id) => `KAX.machine.${id}.outbox`;
export const subjectEvents = (id) => `KAX.machine.${id}.events`;
export const subjectIdentity = (id) => `KAX.machine.${id}.identity`;

export const kaxApiUrl = () => (process.env.KAX_API_URL || DEFAULT_KAX_API_URL).replace(/\/+$/, "");
export const natsUrl = () => process.env.KANNAKA_NATS_URL || process.env.NATS_URL || DEFAULT_NATS_URL;
export const operatorSigner = () => process.env.KAX_OPERATOR_SIGNER || "operator-nick";
export const operatorKeyPath = () => process.env.KAX_OPERATOR_KEY_FILE || join(homedir(), ".kannaka", "kax-operator.key");

// ---------------------------------------------------------------- canonical JSON
// Python's ensure_ascii escaper: `"` and `\` plus the short forms \n \r \t \b \f,
// then EVERYTHING outside 0x20..0x7e as lowercase \uXXXX per UTF-16 code unit
// (astral chars become surrogate pairs, DEL 0x7f is escaped — JSON.stringify
// would emit both raw, so it cannot be used here).
function pyString(s) {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x22) out += '\\"';
    else if (c === 0x5c) out += "\\\\";
    else if (c === 0x0a) out += "\\n";
    else if (c === 0x0d) out += "\\r";
    else if (c === 0x09) out += "\\t";
    else if (c === 0x08) out += "\\b";
    else if (c === 0x0c) out += "\\f";
    else if (c >= 0x20 && c <= 0x7e) out += s[i];
    else out += "\\u" + c.toString(16).padStart(4, "0");
  }
  return out + '"';
}
// Python sorts str keys by code point; JS default sort compares UTF-16 units.
function cmpCodePoints(a, b) {
  const A = Array.from(a), B = Array.from(b);
  const n = Math.min(A.length, B.length);
  for (let i = 0; i < n; i++) {
    const d = A[i].codePointAt(0) - B[i].codePointAt(0);
    if (d) return d;
  }
  return A.length - B.length;
}
export function canonicalJson(v) {
  if (v === null) return "null";
  if (v === true) return "true";
  if (v === false) return "false";
  if (typeof v === "number") {
    if (!Number.isSafeInteger(v)) throw new Error(`canonical JSON: only safe integers are allowed, got ${String(v)} (Python and V8 format floats differently, so a float can never be signed portably)`);
    return String(v);
  }
  if (typeof v === "string") return pyString(v);
  if (Array.isArray(v)) return "[" + v.map(canonicalJson).join(",") + "]";
  if (typeof v === "object") {
    const keys = Object.keys(v).sort(cmpCodePoints);
    return "{" + keys.map((k) => pyString(k) + ":" + canonicalJson(v[k])).join(",") + "}";
  }
  throw new Error(`canonical JSON: unsupported value type ${typeof v}`);
}

// ---------------------------------------------------------------- Ed25519
// PKCS#8 wrapper for a raw 32-byte Ed25519 seed (RFC 8410): the DER prefix is
// constant, so key object = prefix || seed.
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
export function keyFromSeedHex(seedHex) {
  const hex = String(seedHex ?? "").trim();
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error("operator key must be a 32-byte hex seed (64 hex chars)");
  return createPrivateKey({ key: Buffer.concat([PKCS8_ED25519_PREFIX, Buffer.from(hex, "hex")]), format: "der", type: "pkcs8" });
}
export function publicKeyHex(priv) {
  const spki = createPublicKey(priv).export({ type: "spki", format: "der" });
  return spki.subarray(spki.length - 32).toString("hex"); // raw key is the last 32 bytes of the SPKI DER
}
export function signEnvelope(envelope, priv) {
  const { sig: _drop, ...base } = envelope;
  const data = Buffer.from(canonicalJson(base), "utf8");
  return { ...base, sig: cryptoSign(null, data, priv).toString("hex") };
}
export function verifyEnvelope(envelope, pubHex) {
  const { sig, ...base } = envelope;
  if (typeof sig !== "string" || !/^[0-9a-f]{128}$/i.test(sig)) return false;
  const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(pubHex, "hex")]);
  const pub = createPublicKey({ key: spki, format: "der", type: "spki" });
  return cryptoVerify(null, Buffer.from(canonicalJson(base), "utf8"), pub, Buffer.from(sig, "hex"));
}
// Reads the seed file. Error messages name the PATH only — the seed itself is
// never echoed, logged, or included in a tool result.
export function loadOperatorKey(path = operatorKeyPath()) {
  if (!existsSync(path)) throw new Error(`operator key not found at ${path} — set KAX_OPERATOR_KEY_FILE to your 32-byte hex Ed25519 seed (generate one with kax-computer/operator/kax_keygen.py and register its public key in the host's trusted_keys.json)`);
  let hex;
  try { hex = readFileSync(path, "utf8").trim(); } catch (e) { throw new Error(`operator key at ${path} could not be read: ${e.message}`); }
  try { return keyFromSeedHex(hex); } catch (e) { throw new Error(`operator key at ${path}: ${e.message}`); }
}

// ---------------------------------------------------------------- envelopes
export const MACHINE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
export function reqMachine(v) {
  const s = String(v ?? "").trim();
  if (!MACHINE_ID_RE.test(s)) throw new Error("'machine' must be 1-64 chars of [A-Za-z0-9_-] (a NATS subject token — no dots or wildcards)");
  return s;
}
export const nowTs = () => Math.floor(Date.now() / 1000); // integer seconds: the manager accepts int|float within ±60s, and only an int re-serialises identically in Python
export function buildJobEnvelope({ machine, prompt, signer, id = randomUUID(), ts = nowTs() }) {
  const p = String(prompt ?? "");
  if (!p.trim()) throw new Error("'prompt' is required and must be a non-empty string");
  return { v: 1, machine: reqMachine(machine), id, ts, prompt: p, signer: String(signer) };
}
export function buildGrantEnvelope({ machine, credits, signer, id = randomUUID(), ts = nowTs() }) {
  const c = typeof credits === "string" && credits.trim() !== "" ? Number(credits) : credits;
  if (!Number.isSafeInteger(c) || c <= 0 || c > MAX_GRANT_CREDITS) throw new Error(`'credits' must be a positive integer (1-${MAX_GRANT_CREDITS}); grants are whole credits only`);
  return { v: 1, type: "credit_grant", machine: reqMachine(machine), id, ts, credits: c, signer: String(signer) };
}

// ---------------------------------------------------------------- NATS creds
export const natsEnvPath = () => process.env.KANNAKA_NATS_ENV || join(homedir(), ".kannaka-nats.env");
export function parseEnvFile(text) {
  const kv = {};
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    let val = m[2].trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) val = val.slice(1, -1);
    kv[m[1]] = val;
  }
  return kv;
}
// Env wins; else ~/.kannaka-nats.env (the same file kax_send.py and the fleet
// use). Returns null when nothing usable is found — KAX subjects are denied to
// anonymous connections, so callers must refuse rather than try anon.
export function loadNatsCreds(envFile = natsEnvPath()) {
  if (process.env.NATS_USER && process.env.NATS_PASSWORD) return { user: process.env.NATS_USER, pass: process.env.NATS_PASSWORD, source: "env" };
  if (!existsSync(envFile)) return null;
  try {
    const kv = parseEnvFile(readFileSync(envFile, "utf8"));
    if (kv.NATS_USER && kv.NATS_PASSWORD) return { user: kv.NATS_USER, pass: kv.NATS_PASSWORD, source: envFile };
  } catch {}
  return null;
}

// ---------------------------------------------------------------- minimal NATS client
// Just enough of the NATS text protocol (INFO/CONNECT/PING/PONG/PUB/SUB/MSG/-ERR)
// for a signed publish plus a bounded wait on a reply subject. Plain nats://
// only (the swarm bus does not require TLS); refuses if the server says
// tls_required. `flush()` resolves on the next PONG — a server-side
// permissions violation for a preceding PUB/SUB arrives BEFORE that PONG, so
// `errors` is authoritative after a flush.
export function openNats({ url = natsUrl(), creds = null, timeoutMs = 8000, name = "kannaka-mcp" } = {}) {
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(url); } catch { return reject(new Error(`bad NATS url: ${url}`)); }
    const host = u.hostname, port = Number(u.port || 4222);
    const user = creds?.user ?? (u.username ? decodeURIComponent(u.username) : undefined);
    const pass = creds?.pass ?? (u.password ? decodeURIComponent(u.password) : undefined);
    const sock = netConnect({ host, port });
    sock.setNoDelay(true);
    let buf = Buffer.alloc(0), sid = 0, ready = false, closed = false;
    const subs = new Map(), pongWaiters = [], errors = [];
    const timer = setTimeout(() => { if (!ready) { sock.destroy(); reject(new Error(`NATS connect timeout (${host}:${port})`)); } }, timeoutMs);
    const write = (s) => { if (!closed) sock.write(s); };
    const api = {
      publish(subject, payload) {
        const b = Buffer.from(payload);
        write(`PUB ${subject} ${b.length}\r\n`); write(b); write("\r\n");
      },
      subscribe(subject, handler) { const id = ++sid; subs.set(id, handler); write(`SUB ${subject} ${id}\r\n`); return id; },
      flush() { return new Promise((res, rej) => { if (closed) return rej(new Error("NATS connection closed")); pongWaiters.push({ res, rej }); write("PING\r\n"); }); },
      close() { closed = true; try { sock.end(); } catch {} try { sock.destroy(); } catch {} },
      errors,
    };
    const fail = (e) => {
      clearTimeout(timer);
      if (!ready) reject(e);
      for (const w of pongWaiters.splice(0)) w.rej(e);
    };
    sock.on("error", (e) => fail(e));
    sock.on("close", () => { closed = true; fail(new Error(`NATS connection closed${errors.length ? `: ${errors[errors.length - 1]}` : ""}`)); });
    sock.on("data", (d) => { buf = Buffer.concat([buf, d]); parse(); });
    function parse() {
      for (;;) {
        const nl = buf.indexOf("\r\n");
        if (nl < 0) return;
        const line = buf.subarray(0, nl).toString("utf8");
        if (line.startsWith("MSG ")) {
          const parts = line.split(" "); // MSG <subject> <sid> [reply-to] <#bytes>
          const nbytes = Number(parts[parts.length - 1]);
          const total = nl + 2 + nbytes + 2;
          if (buf.length < total) return;
          const data = Buffer.from(buf.subarray(nl + 2, nl + 2 + nbytes));
          buf = buf.subarray(total);
          const h = subs.get(Number(parts[2]));
          if (h) { try { h({ subject: parts[1], reply: parts.length === 5 ? parts[3] : undefined, data }); } catch {} }
          continue;
        }
        buf = buf.subarray(nl + 2);
        if (line.startsWith("INFO ")) {
          let info = {}; try { info = JSON.parse(line.slice(5)); } catch {}
          if (info.tls_required) { fail(new Error("NATS server requires TLS; this client speaks plain nats:// only")); sock.destroy(); return; }
          const connect = { verbose: false, pedantic: false, name, lang: "node", version: "1", protocol: 1, headers: false };
          if (user) { connect.user = user; connect.pass = pass; }
          write(`CONNECT ${JSON.stringify(connect)}\r\nPING\r\n`); // first PONG == authenticated
        } else if (line === "PING") {
          write("PONG\r\n");
        } else if (line === "PONG") {
          if (!ready) { ready = true; clearTimeout(timer); resolve(api); }
          else { const w = pongWaiters.shift(); if (w) w.res(); }
        } else if (line.startsWith("-ERR")) {
          const msg = line.slice(4).trim().replace(/^'(.*)'$/, "$1");
          errors.push(msg);
          if (!ready) { fail(new Error(`NATS: ${msg}`)); sock.destroy(); return; }
        }
        // +OK and anything else: ignore
      }
    }
  });
}

// ---------------------------------------------------------------- roster (HTTP)
export function parseRoster(body) {
  const list = Array.isArray(body) ? body : Array.isArray(body?.machines) ? body.machines : null;
  if (!list) throw new Error("KAX roster: unexpected response shape (expected {machines:[...]})");
  return list.map((m) => {
    const running = typeof m?.running === "boolean" ? m.running : null;
    const balanceCredits = typeof m?.balanceCredits === "number" ? m.balanceCredits
      : typeof m?.balance_minor === "number" ? m.balance_minor / MINOR_PER_CREDIT : null;
    const state = typeof m?.state === "string" && m.state ? m.state
      : running === null ? "unknown"
      : balanceCredits !== null && balanceCredits <= 0 ? "suspended"
      : running ? "active" : "hibernated";
    return {
      machineId: String(m?.machineId ?? m?.machine_id ?? m?.id ?? "?"),
      host: m?.host ?? null,
      state,
      running,
      balanceCredits,
      jobsServed: m?.jobsServed ?? m?.jobs_served ?? null,
      nostrPubkey: m?.nostrPubkey ?? m?.nostr_pubkey ?? null,
      lastEvent: m?.lastEvent ?? null,
      lastEventAt: m?.lastEventAt ?? null,
      updatedAt: m?.updatedAt ?? null,
    };
  });
}
export async function fetchRoster(base = kaxApiUrl(), timeoutMs = 15000) {
  const res = await fetch(`${base}/api/compute/machines`, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) throw new Error(`KAX roster: HTTP ${res.status} from ${base}/api/compute/machines`);
  return parseRoster(await res.json());
}
export function formatRoster(rows) {
  if (!rows.length) return "(no machines in the KAX roster)";
  const w = Math.max(9, ...rows.map((r) => r.machineId.length));
  const lines = [`${"machine".padEnd(w)}  state       credits      jobs  last event`];
  for (const r of rows) {
    const cr = r.balanceCredits == null ? "?" : r.balanceCredits.toFixed(6);
    lines.push(`${r.machineId.padEnd(w)}  ${r.state.padEnd(10)}  ${cr.padStart(11)}  ${String(r.jobsServed ?? "?").padStart(4)}  ${r.lastEvent ?? "-"}${r.lastEventAt ? ` @ ${r.lastEventAt}` : ""}`);
  }
  lines.push("(credits are KAX internal accounting units; 1 credit = 1,000,000 minor)");
  return lines.join("\n");
}

// ---------------------------------------------------------------- tail folding
// `kannaka swarm tail` emits NDJSON {ts, subject, payload}. Fold a window into
// the latest fleet snapshot + the lifecycle/ledger events seen.
export function foldTail(ndjson) {
  let snapshot = null;
  const events = [];
  let unparsed = 0;
  for (const raw of String(ndjson || "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    let rec; try { rec = JSON.parse(line); } catch { unparsed++; continue; }
    const subject = String(rec?.subject ?? "");
    const p = rec?.payload;
    if (subject === SUBJECT_FLEET_STATUS) {
      if (p && typeof p === "object" && (!snapshot || (Number(p.ts) || 0) >= (Number(snapshot.ts) || 0))) snapshot = p;
      continue;
    }
    const m = /^KAX\.machine\.([^.]+)\.events$/.exec(subject);
    if (m) {
      const ev = p && typeof p === "object" ? { ...p } : { raw: p };
      if (!ev.machine) ev.machine = m[1];
      if (ev.ts == null) ev.ts = rec.ts;
      events.push(ev);
    }
  }
  const machines = snapshot && snapshot.machines && typeof snapshot.machines === "object"
    ? Object.entries(snapshot.machines).map(([id, m]) => ({
        machineId: id,
        state: m?.running === true ? "active" : m?.running === false ? (typeof m?.balance_minor === "number" && m.balance_minor <= 0 ? "suspended" : "hibernated") : "unknown",
        running: m?.running ?? null,
        balanceCredits: typeof m?.balance_minor === "number" ? m.balance_minor / MINOR_PER_CREDIT : null,
        jobsServed: m?.jobs_served ?? null,
      }))
    : null;
  return { snapshot, machines, events, unparsed };
}
export const parseJsonSafe = (buf) => { try { return JSON.parse(Buffer.from(buf).toString("utf8")); } catch { return null; } };
