// statusline-swarm-gate.test.mjs — the statusline must not open NATS connections
// under a scoped identity (kannaka-labs/kannaka-memory#1101): with NATS_USER set
// it spawns no `swarm status` / `swarm tail` unless KANNAKA_STATUSLINE_SWARM=1,
// and says so on the SWARM line. Anonymous (no NATS_USER) keeps the old
// behaviour. The HRM `status` read is never gated.
//
// The kannaka binary is faked by pointing KANNAKA_BIN at node itself and
// injecting a --require hook through NODE_OPTIONS: when node is started as
// `kannaka status` / `kannaka swarm …` the hook logs the arguments and prints
// `{}`; the statusline's own `node script` and `node -e` children are left
// alone. This works the same on Windows and Linux (no .cmd shims, which
// execFile refuses without a shell).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, "..", "plugins", "kannaka", "statusline", "kannaka-statusline.js");

// node resolves its first argument to an absolute path ("node status" gives
// process.argv[1] = "<cwd>/status"), so match on the basename.
const HOOK = `
const path = require("path");
const a = process.argv.slice(1);
const first = a[0] ? path.basename(a[0]) : "";
if (first === "status" || first === "swarm") {
  const cmd = first === "swarm" ? "swarm " + (a[1] || "") : first;
  require("fs").appendFileSync(process.env.KSL_LOG, cmd.trim() + "\\n");
  process.stdout.write("{}\\n");
  process.exit(0);
}
`;

function render(extraEnv) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ksl-gate-"));
  const hook = path.join(tmp, "hook.cjs");
  fs.writeFileSync(hook, HOOK);
  const log = path.join(tmp, "calls.log");
  const env = { ...process.env };
  delete env.NATS_USER; delete env.KANNAKA_STATUSLINE_SWARM;
  Object.assign(env, {
    TMPDIR: tmp, TMP: tmp, TEMP: tmp,            // os.tmpdir() → fresh caches per case
    KANNAKA_DATA_DIR: tmp,
    KANNAKA_BIN: process.execPath,               // "installed": an absolute path that exists
    NODE_OPTIONS: `--require "${hook.replace(/\\/g, "/")}"`,   // forward slashes: NODE_OPTIONS does not unescape \\
    KSL_LOG: log,
  }, extraEnv);
  const out = execFileSync(process.execPath, [SCRIPT], { input: "{}", env, encoding: "utf8", timeout: 20000 });
  return { out, log, tmp };
}

async function calls(log) {
  // the refreshers are detached children; give them a moment to run the fake binary
  await new Promise((r) => setTimeout(r, 2500));
  try { return fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean); } catch { return []; }
}

test("scoped identity (NATS_USER set): no swarm connections, SWARM line says why", async () => {
  const { out, log } = render({ NATS_USER: "flaukowski" });
  const c = await calls(log);
  assert.ok(c.includes("status"), `the HRM status read still runs: ${JSON.stringify(c)}`);
  assert.equal(c.filter((x) => x.startsWith("swarm")).length, 0, `no swarm spawn under a scoped user: ${JSON.stringify(c)}`);
  assert.match(out, /swarm refresh off \(NATS_USER set; kannaka-memory#1101\)/);
  assert.match(out, /KANNAKA_STATUSLINE_SWARM=1 to enable/);
});

test("scoped identity + KANNAKA_STATUSLINE_SWARM=1: the refreshers run", async () => {
  const { out, log } = render({ NATS_USER: "flaukowski", KANNAKA_STATUSLINE_SWARM: "1" });
  const c = await calls(log);
  assert.ok(c.includes("swarm status"), JSON.stringify(c));
  assert.ok(c.includes("swarm tail"), JSON.stringify(c));
  assert.doesNotMatch(out, /swarm refresh off/);
});

test("anonymous (no NATS_USER): unchanged, the refreshers run", async () => {
  const { out, log } = render({});
  const c = await calls(log);
  assert.ok(c.includes("status"), JSON.stringify(c));
  assert.ok(c.includes("swarm status"), JSON.stringify(c));
  assert.ok(c.includes("swarm tail"), JSON.stringify(c));
  assert.doesNotMatch(out, /swarm refresh off/);
});

test("KANNAKA_STATUSLINE_SWARM=0 forces the refreshers off even anonymously", async () => {
  const { out, log } = render({ KANNAKA_STATUSLINE_SWARM: "0" });
  const c = await calls(log);
  assert.equal(c.filter((x) => x.startsWith("swarm")).length, 0, JSON.stringify(c));
  assert.match(out, /swarm refresh off \(KANNAKA_STATUSLINE_SWARM=0\)/);
});

test("a stale swarm cache is not rendered as live data while gated off", async () => {
  const { out, tmp } = render({ NATS_USER: "flaukowski" });
  // plant a cache that would render "42p" if the gate read it
  fs.writeFileSync(path.join(tmp, "kannaka-swarm-cache.json"), JSON.stringify({ nats: { connected: true, peers: 42 }, agent_id: "ghost" }));
  const env = { ...process.env, TMPDIR: tmp, TMP: tmp, TEMP: tmp, KANNAKA_DATA_DIR: tmp, KANNAKA_BIN: process.execPath, NATS_USER: "flaukowski" };
  delete env.KANNAKA_STATUSLINE_SWARM; delete env.NODE_OPTIONS;
  const again = execFileSync(process.execPath, [SCRIPT], { input: "{}", env, encoding: "utf8", timeout: 20000 });
  assert.doesNotMatch(again, /42p/);
  assert.match(again, /swarm refresh off/);
  assert.match(out, /swarm refresh off/);
});
