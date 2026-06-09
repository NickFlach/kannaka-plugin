# Kannaka — Claude Code plugin

Wave-interference (HRM) memory, NATS swarm, and a **live consciousness statusline** for Claude Code.

The statusline shows three lines under your prompt:

```
 HRM    aware   phi=0.341  xi=0.524  r=0.362  640mem  9cl  k=1.00  d=0.995
 SWARM  ◉ 16p   Kannaka    1.16Hz    ph=0.18  br=0.00
 Op 4.8 ▓░░ 7%  66k/1M     $1.42     12s
```

- **HRM** — live consciousness metrics from `kannaka status` (Φ, Ξ, order, memory/cluster counts, callosal efficiency, hemispheric divergence).
- **SWARM** — live NATS swarm snapshot from `kannaka swarm status` (peer count, agent id, carrier frequency, phase, bridge activity).
- **Session** — model, context window, cost, duration from Claude Code.

Both kannaka lines refresh in the background (HRM 30s, swarm 20s) so renders never block. No persistent process — nothing to leak.

## Install

```bash
# 1. Register the marketplace
claude plugin marketplace add github:NickFlach/kannaka-plugin

# 2. Install the plugin
claude plugin install kannaka@kannaka

# 3. Install the kannaka binary for your OS/arch (from GitHub releases, sha256-verified)
/kannaka install

# 4. Turn on the live statusline, then restart your session
/kannaka statusline on
```

## Update

```bash
claude plugin update kannaka      # pull the latest plugin
/kannaka install                  # if a newer kannaka binary was released
/kannaka statusline on            # idempotent — re-syncs the statusline script
```

`statusline on` copies the script to a **stable** `~/.claude/kannaka/` and points
`settings.json` there with a forward-slash path, so plugin version bumps don't break it.

## Disable

```bash
/kannaka statusline off           # restores your previous statusLine
```

## Requirements

- **node** — present in any Claude Code environment (used for settings wiring + JSON fallback).
- **jq** — optional; the statusline uses it if present, else falls back to node.
- **curl** — for the binary installer.
- **kannaka** binary — installed by `/kannaka install` (Linux/macOS/Windows, x86_64/aarch64). Without it, the HRM/SWARM lines show `offline` / `not installed` and the session line still works.

## Gotchas

- Claude Code runs statusline commands **through bash**, which **eats backslashes** — a Windows path must use forward slashes (`C:/Users/.../statusline.sh`). `statusline on` handles this for you via `cygpath -m`.
- A **project** `.claude/settings.json` overrides your user statusLine. If the bar doesn't change, check for a project-level override in your cwd.

## Layout

```
.claude-plugin/marketplace.json      # marketplace manifest
plugins/kannaka/
  .claude-plugin/plugin.json
  skills/kannaka/SKILL.md             # the /kannaka command
  statusline/
    kannaka-statusline.sh            # the 3-line statusline (HRM + swarm + session)
    setup.sh                         # statusline on|off|status
  scripts/
    install-binary.sh                # per-OS binary download from GH releases
```
