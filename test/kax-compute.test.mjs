// Unit + protocol tests for the KAX Compute District MCP tools.
// Run: node --test test/   (Node >= 20, no dependencies)
//
// Golden strings/signatures were produced by Python — the verifier's language:
//   json.dumps(obj, sort_keys=True, separators=(",", ":"))
//   cryptography Ed25519PrivateKey.from_private_bytes(bytes([0x11]*32))
// The seed is 32 bytes of 0x11: a fixed, obviously fake test vector.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { verify as cryptoVerify, createPublicKey } from "node:crypto";
import * as kax from "../plugins/kannaka/mcp/kax-compute.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP = join(HERE, "..", "plugins", "kannaka", "mcp", "kannaka-mcp.mjs");
const FAKE_SEED = "11".repeat(32);
const FAKE_PUB = "d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737";

const JOB = { v: 1, machine: "agent001", id: "00000000-0000-4000-8000-000000000001", ts: 1787891480, prompt: "hello", signer: "operator-nick" };
const NASTY = { z: [1, 2, { b: null, a: true }], a: 'héllo "q" \\ /\n\t 😀 ~\x7f', m: { k2: 2, k1: -3 }, e: {}, f: [] };
const GRANT = { v: 1, type: "credit_grant", machine: "agent002", id: "00000000-0000-4000-8000-000000000002", ts: 1787891480, credits: 5, signer: "operator-nick" };

const GOLD_JOB = '{"id":"00000000-0000-4000-8000-000000000001","machine":"agent001","prompt":"hello","signer":"operator-nick","ts":1787891480,"v":1}';
const GOLD_NASTY = '{"a":"h\\u00e9llo \\"q\\" \\\\ /\\n\\t \\ud83d\\ude00 ~\\u007f","e":{},"f":[],"m":{"k1":-3,"k2":2},"z":[1,2,{"a":true,"b":null}]}';
const GOLD_GRANT = '{"credits":5,"id":"00000000-0000-4000-8000-000000000002","machine":"agent002","signer":"operator-nick","ts":1787891480,"type":"credit_grant","v":1}';
const SIG_JOB = "9515012f87806cec1dac471dae35166be7abaa4d3c5489ac54fe0b7e917e488ca37fce60c9e5ec586f4838fac99f30e9ce4de03fba6cae8150c139fd575d300a";
const SIG_GRANT = "06cc73fe2080e6d0c6c04168179782af85977ee3e388413e5c290dc63a9342dd5f4cb893181fa662c7a4a21b564498348f36cdb25579ca4df08997773422520f";

// ---------------------------------------------------------------- canonical JSON
test("canonical JSON matches Python json.dumps(sort_keys, compact) — 3 golden strings", () => {
  assert.equal(kax.canonicalJson(JOB), GOLD_JOB);
  assert.equal(kax.canonicalJson(NASTY), GOLD_NASTY);
  assert.equal(kax.canonicalJson(GRANT), GOLD_GRANT);
  // and it is pure ASCII, like ensure_ascii output
  for (const s of [GOLD_JOB, GOLD_NASTY, GOLD_GRANT]) assert.match(s, /^[\x20-\x7e]*$/);
});

test("canonical JSON differs from JSON.stringify exactly where Python differs (non-ASCII, DEL)", () => {
  assert.notEqual(kax.canonicalJson({ a: "é" }), JSON.stringify({ a: "é" }));
  assert.equal(kax.canonicalJson({ a: "é" }), '{"a":"\\u00e9"}');
  assert.equal(kax.canonicalJson({ a: "\x7f" }), '{"a":"\\u007f"}');
  assert.equal(kax.canonicalJson({ a: "\x01" }), '{"a":"\\u0001"}');
});

test("canonical JSON refuses non-integers (Python prints 1.0 where V8 prints 1)", () => {
  assert.throws(() => kax.canonicalJson({ ts: 1787891480.5 }), /only safe integers/);
  assert.throws(() => kax.canonicalJson({ x: NaN }), /only safe integers/);
  assert.throws(() => kax.canonicalJson({ x: Infinity }), /only safe integers/);
  assert.throws(() => kax.canonicalJson({ x: 2 ** 53 }), /only safe integers/);
  assert.throws(() => kax.canonicalJson({ x: undefined }), /unsupported/);
  assert.equal(kax.canonicalJson({ x: -0 }), '{"x":0}');
});

test("canonical JSON sorts keys by code point (Python str ordering)", () => {
  assert.equal(kax.canonicalJson({ b: 1, a: 2, B: 3, _: 4 }), '{"B":3,"_":4,"a":2,"b":1}');
});

// ---------------------------------------------------------------- Ed25519
test("Ed25519: fixed seed -> pinned public key and pinned signatures (Python golden)", () => {
  const key = kax.keyFromSeedHex(FAKE_SEED);
  assert.equal(kax.publicKeyHex(key), FAKE_PUB);
  const sj = kax.signEnvelope(JOB, key);
  assert.equal(sj.sig, SIG_JOB);
  const sg = kax.signEnvelope(GRANT, key);
  assert.equal(sg.sig, SIG_GRANT);
  // independent verification via node:crypto against the raw public key
  const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(FAKE_PUB, "hex")]);
  const pub = createPublicKey({ key: spki, format: "der", type: "spki" });
  assert.equal(cryptoVerify(null, Buffer.from(GOLD_JOB), pub, Buffer.from(SIG_JOB, "hex")), true);
  assert.equal(kax.verifyEnvelope(sj, FAKE_PUB), true);
  assert.equal(kax.verifyEnvelope({ ...sj, prompt: "hello HAHA INJECTED" }, FAKE_PUB), false);
  assert.equal(kax.verifyEnvelope({ ...sj, sig: "00" + sj.sig.slice(2) }, FAKE_PUB), false);
});

test("signEnvelope drops a pre-existing sig before signing and signs the envelope minus sig", () => {
  const key = kax.keyFromSeedHex(FAKE_SEED);
  assert.equal(kax.signEnvelope({ ...JOB, sig: "junk" }, key).sig, SIG_JOB);
  assert.throws(() => kax.keyFromSeedHex("abc"), /32-byte hex seed/);
});

// ---------------------------------------------------------------- envelopes
test("job envelope: shape, integer ts, uuid id, validation", () => {
  const e = kax.buildJobEnvelope({ machine: "agent001", prompt: "hi", signer: "operator-nick" });
  assert.deepEqual(Object.keys(e).sort(), ["id", "machine", "prompt", "signer", "ts", "v"]);
  assert.equal(e.v, 1);
  assert.ok(Number.isSafeInteger(e.ts) && Math.abs(e.ts - Date.now() / 1000) < 5);
  assert.match(e.id, /^[0-9a-f-]{36}$/);
  assert.throws(() => kax.buildJobEnvelope({ machine: "a.b", prompt: "hi", signer: "s" }), /'machine'/);
  assert.throws(() => kax.buildJobEnvelope({ machine: "a*", prompt: "hi", signer: "s" }), /'machine'/);
  assert.throws(() => kax.buildJobEnvelope({ machine: "", prompt: "hi", signer: "s" }), /'machine'/);
  assert.throws(() => kax.buildJobEnvelope({ machine: "agent001", prompt: "  ", signer: "s" }), /'prompt'/);
});

test("grant envelope: whole credits only", () => {
  const e = kax.buildGrantEnvelope({ machine: "agent002", credits: 5, signer: "operator-nick" });
  assert.equal(e.type, "credit_grant");
  assert.equal(e.credits, 5);
  assert.equal(kax.buildGrantEnvelope({ machine: "x", credits: "7", signer: "s" }).credits, 7);
  for (const bad of [0, -1, 1.5, "1.5", NaN, "", null, undefined, 1001]) {
    assert.throws(() => kax.buildGrantEnvelope({ machine: "x", credits: bad, signer: "s" }), /'credits'/, `credits=${String(bad)}`);
  }
});

// ---------------------------------------------------------------- key + creds files
test("operator key: missing file refuses with the path and never the seed; a valid file loads", () => {
  const dir = mkdtempSync(join(tmpdir(), "kax-"));
  const missing = join(dir, "nope.key");
  assert.throws(() => kax.loadOperatorKey(missing), (e) => e.message.includes(missing) && e.message.includes("KAX_OPERATOR_KEY_FILE"));
  const bad = join(dir, "bad.key");
  writeFileSync(bad, "not-hex\n");
  assert.throws(() => kax.loadOperatorKey(bad), (e) => e.message.includes(bad) && !e.message.includes("not-hex"));
  const good = join(dir, "good.key");
  writeFileSync(good, FAKE_SEED + "\n");
  assert.equal(kax.publicKeyHex(kax.loadOperatorKey(good)), FAKE_PUB);
});

test("NATS creds: env file parsing (export/quotes/comments) and env precedence", () => {
  const kv = kax.parseEnvFile('# c\nexport NATS_USER="u1"\nNATS_PASSWORD=\'p 1\'\nJUNK\n  X = y \n');
  assert.deepEqual(kv, { NATS_USER: "u1", NATS_PASSWORD: "p 1", X: "y" });
  const dir = mkdtempSync(join(tmpdir(), "kax-"));
  const f = join(dir, "nats.env");
  writeFileSync(f, "NATS_USER=fu\nNATS_PASSWORD=fp\n");
  const saved = { u: process.env.NATS_USER, p: process.env.NATS_PASSWORD };
  try {
    delete process.env.NATS_USER; delete process.env.NATS_PASSWORD;
    assert.deepEqual(kax.loadNatsCreds(f), { user: "fu", pass: "fp", source: f });
    assert.equal(kax.loadNatsCreds(join(dir, "absent.env")), null);
    process.env.NATS_USER = "eu"; process.env.NATS_PASSWORD = "ep";
    assert.deepEqual(kax.loadNatsCreds(f), { user: "eu", pass: "ep", source: "env" });
  } finally {
    if (saved.u == null) delete process.env.NATS_USER; else process.env.NATS_USER = saved.u;
    if (saved.p == null) delete process.env.NATS_PASSWORD; else process.env.NATS_PASSWORD = saved.p;
  }
});

// ---------------------------------------------------------------- roster
const ROSTER_FIXTURE = { machines: [
  { machineId: "kannaka-01", host: "skywave", state: "hibernated", running: false, balanceCredits: 1.790568, jobsServed: 5, nostrPubkey: "4afb", lastEvent: "debit", lastEventAt: "2026-08-31T16:22:05.935Z", firstSeenAt: "2026-08-29T16:28:10.158Z", updatedAt: "2026-09-01T21:25:42.122Z" },
  { machineId: "agent003", host: "skywave", state: "active", running: true, balanceCredits: 1.840814, jobsServed: 4, nostrPubkey: null, lastEvent: "wake", lastEventAt: null },
  // no derived state from the API: derive it here
  { machine_id: "legacy-1", running: false, balance_minor: 0, jobs_served: 1 },
  { id: "legacy-2", running: true, balance_minor: 2500000 },
  { id: "legacy-3" },
] };

test("roster parsing: real API shape + derived-state fallbacks", () => {
  const rows = kax.parseRoster(ROSTER_FIXTURE);
  assert.equal(rows.length, 5);
  assert.equal(rows[0].machineId, "kannaka-01");
  assert.equal(rows[0].state, "hibernated");
  assert.equal(rows[0].balanceCredits, 1.790568);
  assert.equal(rows[1].state, "active");
  assert.equal(rows[2].machineId, "legacy-1");
  assert.equal(rows[2].state, "suspended");
  assert.equal(rows[2].balanceCredits, 0);
  assert.equal(rows[3].state, "active");
  assert.equal(rows[3].balanceCredits, 2.5);
  assert.equal(rows[4].state, "unknown");
  assert.equal(rows[4].balanceCredits, null);
  assert.throws(() => kax.parseRoster({ nope: 1 }), /unexpected response shape/);
  const text = kax.formatRoster(rows);
  assert.match(text, /kannaka-01\s+hibernated\s+1\.790568\s+5\s+debit @ 2026-08-31T16:22:05\.935Z/);
  assert.match(text, /internal accounting/);
  assert.equal(kax.formatRoster([]), "(no machines in the KAX roster)");
});

// ---------------------------------------------------------------- tail folding
test("foldTail: latest fleet snapshot + per-machine events from swarm tail NDJSON", () => {
  const lines = [
    JSON.stringify({ ts: 1, subject: "KAX.machines.status", payload: { ts: 100, host: "skywave", machines: { agent001: { running: false, balance_minor: 9563070, jobs_served: 4 } } } }),
    JSON.stringify({ ts: 2, subject: "KAX.machine.agent001.events", payload: { ts: 101, machine: "agent001", event: "job_in", bytes: 12 } }),
    "garbage line",
    JSON.stringify({ ts: 3, subject: "KAX.machine.agent002.events", payload: { ts: 102, event: "job_rejected", reason: "insufficient_balance" } }),
    JSON.stringify({ ts: 4, subject: "KAX.machines.status", payload: { ts: 160, host: "skywave", machines: { agent001: { running: true, balance_minor: 9563070, jobs_served: 5 }, agent002: { running: false, balance_minor: 0, jobs_served: 0 } } } }),
    JSON.stringify({ ts: 5, subject: "QUEEN.phase.x", payload: {} }),
  ].join("\n");
  const f = kax.foldTail(lines);
  assert.equal(f.snapshot.ts, 160);
  assert.equal(f.unparsed, 1);
  assert.deepEqual(f.machines.map((m) => [m.machineId, m.state, m.balanceCredits, m.jobsServed]), [["agent001", "active", 9.56307, 5], ["agent002", "suspended", 0, 0]]);
  assert.equal(f.events.length, 2);
  assert.equal(f.events[0].machine, "agent001");
  assert.equal(f.events[1].machine, "agent002"); // filled from the subject
  assert.equal(f.events[1].reason, "insufficient_balance");
  assert.deepEqual(kax.foldTail(""), { snapshot: null, machines: null, events: [], unparsed: 0 });
});

// ---------------------------------------------------------------- minimal NATS client vs a fake server
function fakeNats({ requireAuth = false } = {}) {
  const log = [];
  const server = createServer((sock) => {
    let buf = "";
    const subs = new Map();
    sock.write('INFO {"server_id":"fake","version":"2.10.0","proto":1,"headers":true,"max_payload":1048576}\r\n');
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      for (;;) {
        const nl = buf.indexOf("\r\n");
        if (nl < 0) return;
        const line = buf.slice(0, nl);
        if (line.startsWith("PUB ")) {
          const [, subject, nb] = line.split(" ");
          const n = Number(nb);
          if (buf.length < nl + 2 + n + 2) return;
          const payload = buf.slice(nl + 2, nl + 2 + n);
          buf = buf.slice(nl + 2 + n + 2);
          log.push(["PUB", subject, payload]);
          if (subject.startsWith("deny.")) { sock.write(`-ERR 'Permissions Violation for Publishing to "${subject}"'\r\n`); continue; }
          for (const [sid, s] of subs) if (s === subject) sock.write(`MSG ${subject} ${sid} ${n}\r\n${payload}\r\n`);
          continue;
        }
        buf = buf.slice(nl + 2);
        if (line.startsWith("CONNECT ")) {
          const c = JSON.parse(line.slice(8));
          log.push(["CONNECT", c]);
          if (requireAuth && !(c.user === "u" && c.pass === "p")) { sock.write("-ERR 'Authorization Violation'\r\n"); sock.end(); return; }
        } else if (line === "PING") sock.write("PONG\r\n");
        else if (line.startsWith("SUB ")) { const [, subject, sid] = line.split(" "); subs.set(Number(sid), subject); log.push(["SUB", subject]); }
      }
    });
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, log, url: `nats://127.0.0.1:${server.address().port}` })));
}

test("openNats: CONNECT with creds, SUB before PUB, MSG delivery, split frames, -ERR after flush", async () => {
  const { server, log, url } = await fakeNats();
  try {
    const nc = await kax.openNats({ url, creds: { user: "u", pass: "p" }, timeoutMs: 3000 });
    assert.equal(log[0][0], "CONNECT");
    assert.equal(log[0][1].user, "u");
    assert.equal(log[0][1].pass, "p");
    const got = [];
    nc.subscribe("KAX.machine.agent001.outbox", (m) => got.push(JSON.parse(m.data.toString("utf8"))));
    await nc.flush();
    const big = { id: "j1", reply: "x".repeat(70000) }; // > one TCP segment: exercises partial-frame buffering
    nc.publish("KAX.machine.agent001.outbox", JSON.stringify(big));
    await nc.flush();
    for (let i = 0; i < 50 && got.length < 1; i++) await new Promise((r) => setTimeout(r, 20));
    assert.equal(got.length, 1);
    assert.equal(got[0].reply.length, 70000);
    assert.deepEqual(nc.errors, []);
    nc.publish("deny.x", "{}");
    await nc.flush();
    assert.equal(nc.errors.length, 1);
    assert.match(nc.errors[0], /Permissions Violation for Publishing to "deny.x"/);
    nc.close();
  } finally { server.close(); }
});

test("openNats: authorization violation is a clear connect failure, not a hang", async () => {
  const { server, url } = await fakeNats({ requireAuth: true });
  try {
    await assert.rejects(kax.openNats({ url, creds: { user: "wrong", pass: "x" }, timeoutMs: 3000 }), /Authorization Violation/);
    const nc = await kax.openNats({ url: url.replace("nats://", "nats://u:p@"), timeoutMs: 3000 }); // user:pass in the URL also works
    nc.close();
  } finally { server.close(); }
});

// ---------------------------------------------------------------- MCP server end to end (stdio)
function mcpCall(env, calls) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [MCP], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    child.stdout.on("data", (d) => { out += d; });
    child.on("error", reject);
    child.on("close", () => resolve(out.trim().split("\n").map((l) => JSON.parse(l))));
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: "2024-11-05" } }) + "\n");
    let id = 1;
    for (const c of calls) child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: id++, method: c.method, params: c.params }) + "\n");
    child.stdin.end();
  });
}

test("MCP server lists the compute tools and refuses a wake without an operator key", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kax-"));
  const missingKey = join(dir, "absent.key");
  const replies = await mcpCall({ KAX_OPERATOR_KEY_FILE: missingKey }, [
    { method: "tools/list", params: {} },
    { method: "tools/call", params: { name: "compute_wake", arguments: { machine: "agent001", prompt: "hi" } } },
    { method: "tools/call", params: { name: "compute_grant", arguments: { machine: "agent001", credits: 1.5 } } },
    { method: "tools/call", params: { name: "compute_events", arguments: { machine: "bad.id" } } },
  ]);
  const byId = Object.fromEntries(replies.map((r) => [r.id, r]));
  const names = byId[1].result.tools.map((t) => t.name);
  for (const n of ["compute_machines", "compute_status", "compute_events", "compute_wake", "compute_grant"]) assert.ok(names.includes(n), n);
  const wakeSchema = byId[1].result.tools.find((t) => t.name === "compute_wake").inputSchema;
  assert.deepEqual(wakeSchema.required, ["machine", "prompt"]);
  assert.equal(byId[2].result.isError, true);
  assert.match(byId[2].result.content[0].text, /operator key not found at/);
  assert.ok(byId[2].result.content[0].text.includes(missingKey));
  assert.equal(byId[3].result.isError, true);
  assert.match(byId[3].result.content[0].text, /'credits' must be a positive integer/);
  assert.equal(byId[4].result.isError, true);
  assert.match(byId[4].result.content[0].text, /'machine' must be/);
});
