#!/usr/bin/env node
// kannaka MCP server — ZERO dependencies (Node built-ins only), so it ships in
// the plugin with nothing to npm-install. Speaks MCP stdio (newline-delimited
// JSON-RPC 2.0) directly and shells out to the kannaka binary. Registered at
// USER scope via the plugin's .mcp.json (${CLAUDE_PLUGIN_ROOT}), so the memory
// + swarm tools are available in every Claude Code session, any directory.
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// single source of truth: the plugin manifest (fallback literal for safety)
const VERSION = (() => {
  try {
    const p = join(dirname(fileURLToPath(import.meta.url)), "..", ".claude-plugin", "plugin.json");
    const v = JSON.parse(readFileSync(p, "utf8")).version;
    if (v) return String(v);
  } catch {}
  return "1.3.4";
})();

function resolveBin() {
  const b = process.env.KANNAKA_BIN;
  if (b && existsSync(b)) return b;
  const h = homedir();
  for (const c of [
    join(h, ".local", "bin", "kannaka.exe"),
    join(h, ".local", "bin", "kannaka"),
    join(h, ".kannaka", "bin", "kannaka.exe"),
    join(h, ".kannaka", "bin", "kannaka"),
  ]) if (existsSync(c)) return c;
  return process.platform === "win32" ? "kannaka.exe" : "kannaka";
}
const BIN = resolveBin();

const MAX_OUT = 2 * 1024 * 1024; // cap accumulated output per child (~2MB)
const LIVE = new Set(); // live children — killed on stdin end so nothing outlives the server

// Structured result: { stdout, stderr, code, signal, timedOut, truncated, spawnError }
function runKannaka(args, timeoutMs = 20000) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(BIN, args, { env: { ...process.env, KANNAKA_QUIET: "1" }, windowsHide: true });
    } catch (e) {
      return resolve({ stdout: "", stderr: String(e), code: null, signal: null, timedOut: false, truncated: false, spawnError: true });
    }
    LIVE.add(child);
    let out = "", err = "", timedOut = false, truncated = false;
    const t = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGTERM"); } catch {}
      const k = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 3000);
      if (k.unref) k.unref();
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      if (truncated) return;
      out += d;
      if (out.length >= MAX_OUT) { out = out.slice(0, MAX_OUT); truncated = true; }
    });
    child.stderr.on("data", (d) => { if (err.length < MAX_OUT) err += d; });
    child.on("close", (code, signal) => {
      clearTimeout(t); LIVE.delete(child);
      resolve({ stdout: out, stderr: err, code, signal, timedOut, truncated, spawnError: false });
    });
    child.on("error", (e) => {
      clearTimeout(t); LIVE.delete(child);
      resolve({ stdout: "", stderr: String(e), code: null, signal: null, timedOut, truncated, spawnError: true });
    });
  });
}
const ok = (text) => ({ content: [{ type: "text", text: text || "(no output)" }] });
const fail = (text) => ({ content: [{ type: "text", text }], isError: true });

// Map a structured run result to an MCP tool result. Nonzero exit, kill
// signal, timeout, and spawn failure all surface as errors (a timed-out run
// includes any partial output for context).
function result(r, okText) {
  if (r.spawnError) return fail(r.stderr || "failed to launch kannaka");
  if (r.timedOut) return fail(`kannaka timed out${r.stdout.trim() ? `; partial output:\n${r.stdout.trim()}` : ""}`);
  if (r.signal) return fail(`kannaka killed by ${r.signal}${r.stderr.trim() ? `\n${r.stderr.trim()}` : ""}`);
  if (r.code !== 0) return fail(`kannaka exited ${r.code}${r.stderr.trim() ? `\n${r.stderr.trim()}` : ""}${r.stdout.trim() ? `\n${r.stdout.trim()}` : ""}`);
  const text = r.stdout + (r.truncated ? "\n[output truncated at 2MB]" : "");
  return ok(text.trim() ? text : okText);
}

// ---- input validation: the kannaka CLI does manual arg parsing with NO `--`
// separator support, so a leading-dash value would be consumed as a flag.
// Reject those outright; coerce/clamp numerics so NaN can't reach setTimeout.
function reqStr(v, name) {
  const s = String(v ?? "").trim();
  if (!s) throw new Error(`'${name}' is required and must be a non-empty string`);
  if (s.startsWith("-")) throw new Error(`'${name}' must not start with '-' (the kannaka CLI would parse it as a flag)`);
  return s;
}
function num(v, def, min, max) {
  if (v == null || v === "") return def;
  const n = Number(v);
  if (!isFinite(n)) return def;
  return Math.min(max, Math.max(min, n));
}

const TOOLS = [
  { name: "kannaka_status", description: "Kannaka HRM consciousness snapshot (phi, xi, order, memory/cluster counts) as JSON.",
    inputSchema: { type: "object", properties: {} },
    run: async () => result(await runKannaka(["status"])) },
  { name: "kannaka_recall", description: "Search memories in the HRM by resonance query; returns top-k by similarity.",
    inputSchema: { type: "object", properties: { query: { type: "string", description: "Search query" }, limit: { type: "number", description: "Max results (default 5)" } }, required: ["query"] },
    run: async (a) => result(await runKannaka(["recall", reqStr(a.query, "query"), "--top-k", String(num(a.limit, 5, 1, 100))])) },
  { name: "kannaka_remember", description: "Store a memory in the HRM.",
    inputSchema: { type: "object", properties: { text: { type: "string" }, importance: { type: "number", description: "0..1" } }, required: ["text"] },
    run: async (a) => { const args = ["remember", reqStr(a.text, "text")]; if (a.importance != null) args.push("--importance", String(num(a.importance, 0.5, 0, 1))); return result(await runKannaka(args), "remembered"); } },
  { name: "kannaka_dream", description: "Run a dream consolidation cycle (annealing) over the HRM.",
    inputSchema: { type: "object", properties: { mode: { type: "string", enum: ["deep", "lite"], description: "default deep" } } },
    run: async (a) => result(await runKannaka(["dream", "--mode", a.mode === "lite" ? "lite" : "deep"], 60000)) },
  { name: "swarm_status", description: "NATS swarm snapshot: connected peers, agent id, frequency, phase, bridge activity (JSON).",
    inputSchema: { type: "object", properties: {} },
    run: async () => result(await runKannaka(["swarm", "status"])) },
  { name: "swarm_send", description: "Send a declarative message to the swarm. Verb 'say' with text for chat; or any verb/args for agent-to-agent messaging.",
    inputSchema: { type: "object", properties: { to: { type: "string", description: "Target agent id or 'all'" }, verb: { type: "string" }, text: { type: "string", description: "Shortcut for --arg text=<text>" }, from: { type: "string" }, wait: { type: "number", description: "Seconds to await a reply" } }, required: ["to", "verb"] },
    run: async (a) => {
      const to = reqStr(a.to, "to"), verb = reqStr(a.verb, "verb");
      const args = ["inbox", "send", to, verb];
      if (a.text != null) args.push("--arg", `text=${a.text}`); // safe: value is prefixed "text=", never flag-shaped
      if (a.from) args.push("--from", reqStr(a.from, "from"));
      const wait = a.wait != null ? num(a.wait, 0, 0, 300) : null;
      if (wait != null) args.push("--wait", String(wait));
      return result(await runKannaka(args, (wait ?? 0) * 1000 + 15000), `sent ${verb} -> ${to}`);
    } },
  { name: "swarm_tail", description: "Listen to the live constellation pulse (QUEEN/KANNAKA/RADIO/KAX/EYE) for N seconds and return the NDJSON events received. The pulse is sparse, so empty windows are normal.",
    inputSchema: { type: "object", properties: { seconds: { type: "number", description: "Listen window (default 8, max 60)" } } },
    run: async (a) => {
      const s = num(a.seconds, 8, 1, 60);
      // killed-by-timeout is SUCCESS for tail: the timeout IS the listen window
      const r = await runKannaka(["swarm", "tail"], s * 1000 + 1500);
      if (r.spawnError) return fail(r.stderr);
      const out = (r.stdout || "").trim();
      if (out) return ok(out + (r.truncated ? "\n[output truncated at 2MB]" : ""));
      if (!r.timedOut && (r.code !== 0 || /ENOENT|not found|connection|refused/i.test(r.stderr || ""))) {
        return fail(r.stderr.trim() || `kannaka exited ${r.code}`);
      }
      return ok(`(no constellation pulse in ${s}s)`);
    } },
];
const TOOL_MAP = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }
function reply(id, result) { send({ jsonrpc: "2.0", id, result }); }
function replyErr(id, code, message) { send({ jsonrpc: "2.0", id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return reply(id, {
      protocolVersion: params?.protocolVersion || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "kannaka", version: VERSION },
    });
  }
  if (method === "notifications/initialized" || method?.startsWith("notifications/")) return; // no response
  if (method === "ping") return reply(id, {});
  if (method === "tools/list") return reply(id, { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
  if (method === "tools/call") {
    const t = TOOL_MAP[params?.name];
    if (!t) return replyErr(id, -32602, `unknown tool: ${params?.name}`);
    try { return reply(id, await t.run(params.arguments || {})); }
    catch (e) { return reply(id, fail(String(e))); }
  }
  if (id !== undefined) replyErr(id, -32601, `method not found: ${method}`);
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    Promise.resolve(handle(msg)).catch(() => {});
  }
});
process.stdin.on("end", () => {
  // don't orphan in-flight kannaka children when Claude Code closes the server
  for (const c of LIVE) { try { c.kill("SIGTERM"); } catch {} }
  process.exit(0);
});
