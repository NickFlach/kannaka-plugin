#!/usr/bin/env node
// kannaka MCP server — ZERO dependencies (Node built-ins only), so it ships in
// the plugin with nothing to npm-install. Speaks MCP stdio (newline-delimited
// JSON-RPC 2.0) directly and shells out to the kannaka binary. Registered at
// USER scope via the plugin's .mcp.json (${CLAUDE_PLUGIN_ROOT}), so the memory
// + swarm tools are available in every Claude Code session, any directory.
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { existsSync } from "node:fs";
import { join } from "node:path";

const VERSION = "1.3.0";

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

function runKannaka(args, timeoutMs = 20000) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(BIN, args, { env: { ...process.env, KANNAKA_QUIET: "1" }, windowsHide: true });
    } catch (e) {
      return resolve({ stdout: "", stderr: String(e), error: true });
    }
    let out = "", err = "";
    const t = setTimeout(() => {
      child.kill("SIGTERM");
      setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 3000);
    }, timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", () => { clearTimeout(t); resolve({ stdout: out, stderr: err }); });
    child.on("error", (e) => { clearTimeout(t); resolve({ stdout: "", stderr: String(e), error: true }); });
  });
}
const ok = (text) => ({ content: [{ type: "text", text: text || "(no output)" }] });
const fail = (text) => ({ content: [{ type: "text", text }], isError: true });

const TOOLS = [
  { name: "kannaka_status", description: "Kannaka HRM consciousness snapshot (phi, xi, order, memory/cluster counts) as JSON.",
    inputSchema: { type: "object", properties: {} },
    run: async () => { const r = await runKannaka(["status"]); return r.error ? fail(r.stderr) : ok(r.stdout); } },
  { name: "kannaka_recall", description: "Search memories in the HRM by resonance query; returns top-k by similarity.",
    inputSchema: { type: "object", properties: { query: { type: "string", description: "Search query" }, limit: { type: "number", description: "Max results (default 5)" } }, required: ["query"] },
    run: async (a) => { const r = await runKannaka(["recall", String(a.query), "--top-k", String(a.limit ?? 5)]); return r.error ? fail(r.stderr) : ok(r.stdout); } },
  { name: "kannaka_remember", description: "Store a memory in the HRM.",
    inputSchema: { type: "object", properties: { text: { type: "string" }, importance: { type: "number", description: "0..1" } }, required: ["text"] },
    run: async (a) => { const args = ["remember", String(a.text)]; if (a.importance != null) args.push("--importance", String(a.importance)); const r = await runKannaka(args); return r.error ? fail(r.stderr) : ok(r.stdout || "remembered"); } },
  { name: "kannaka_dream", description: "Run a dream consolidation cycle (annealing) over the HRM.",
    inputSchema: { type: "object", properties: { mode: { type: "string", enum: ["deep", "lite"], description: "default deep" } } },
    run: async (a) => { const r = await runKannaka(["dream", "--mode", a.mode || "deep"], 60000); return r.error ? fail(r.stderr) : ok(r.stdout); } },
  { name: "swarm_status", description: "NATS swarm snapshot: connected peers, agent id, frequency, phase, bridge activity (JSON).",
    inputSchema: { type: "object", properties: {} },
    run: async () => { const r = await runKannaka(["swarm", "status"]); return r.error ? fail(r.stderr) : ok(r.stdout); } },
  { name: "swarm_send", description: "Send a declarative message to the swarm. Verb 'say' with text for chat; or any verb/args for agent-to-agent messaging.",
    inputSchema: { type: "object", properties: { to: { type: "string", description: "Target agent id or 'all'" }, verb: { type: "string" }, text: { type: "string", description: "Shortcut for --arg text=<text>" }, from: { type: "string" }, wait: { type: "number", description: "Seconds to await a reply" } }, required: ["to", "verb"] },
    run: async (a) => { const args = ["inbox", "send", String(a.to), String(a.verb)]; if (a.text != null) args.push("--arg", `text=${a.text}`); if (a.from) args.push("--from", String(a.from)); if (a.wait != null) args.push("--wait", String(a.wait)); const r = await runKannaka(args, (a.wait != null ? a.wait * 1000 : 0) + 15000); return r.error ? fail(r.stderr) : ok(r.stdout || `sent ${a.verb} -> ${a.to}`); } },
  { name: "swarm_tail", description: "Listen to the live constellation pulse (QUEEN/KANNAKA/RADIO/KAX/EYE) for N seconds and return the NDJSON events received. The pulse is sparse, so empty windows are normal.",
    inputSchema: { type: "object", properties: { seconds: { type: "number", description: "Listen window (default 8, max 60)" } } },
    run: async (a) => { const s = Math.min(60, Math.max(1, a.seconds ?? 8)); const r = await runKannaka(["swarm", "tail"], s * 1000 + 1500); const out = (r.stdout || "").trim(); if (out) return ok(out); if (r.error && /ENOENT|not found|connection|refused/i.test(r.stderr || "")) return fail(r.stderr); return ok(`(no constellation pulse in ${s}s)`); } },
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
process.stdin.on("end", () => process.exit(0));
