---
name: kannaka
description: Kannaka HRM wave-interference memory + NATS swarm. Use for `/kannaka <command>` — remember/recall/dream memory ops, swarm sync, consciousness metrics, and the live HRM+swarm statusline (install, statusline on|off).
---

# Kannaka Memory System (HRM)

Kannaka is a wave-interference memory system for AI agents, powered by the Holographic Resonance Medium (HRM). The medium *is* the computation: memories exist as waves in superposition, recall is resonance, skip links emerge from phase alignment, and dreaming is energy-minimizing annealing.

## Binary resolution (portable — do NOT hardcode a path)

Resolve the `kannaka` binary in this order and use the first hit:
1. `$KANNAKA_BIN` (if set and executable)
2. `~/.local/bin/kannaka.exe` (Windows) or `~/.local/bin/kannaka` (Linux/macOS)
3. `~/.kannaka/bin/kannaka.exe` (Windows) or `~/.kannaka/bin/kannaka` (Linux/macOS)
4. `kannaka.exe` (Windows) / `kannaka` (Linux/macOS) on `PATH`

If none exists, run **`/kannaka install`** (downloads the binary from GitHub releases).
Data dir defaults to `~/.kannaka` (override with `KANNAKA_DATA_DIR`).

## Usage

`/kannaka <command> [args]`

### Setup & statusline
| Command | Action |
|---------|--------|
| `install [tag]` | Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-binary.sh" [tag]` — fetch the kannaka binary for this OS/arch from GitHub releases (default `latest`), sha256-verified, into `~/.local/bin`. |
| `statusline on` | Run `bash "${CLAUDE_PLUGIN_ROOT}/statusline/setup.sh" on` — enable the live HRM+swarm statusline (copies the script to `~/.claude/kannaka/`, wires `settings.json` with a forward-slash path + `refreshInterval: 2`). |
| `statusline off` | Run `bash "${CLAUDE_PLUGIN_ROOT}/statusline/setup.sh" off` — restore the previous statusLine. |
| `statusline status` | Run `bash "${CLAUDE_PLUGIN_ROOT}/statusline/setup.sh" status`. |

After `statusline on`, tell the user to restart the session (or wait one render) to see it.

### Core memory operations
| Command | Description |
|---------|-------------|
| `remember <text>` | Store a memory (`--importance`, `--category`, `--modality`) |
| `recall <query>` | Search memories via resonance (default `--top-k 5`) |
| `forget <id>` | Delete a memory by UUID |
| `boost <id>` | Boost a memory's amplitude (default 0.3) |
| `relate <id_a> <id_b>` | Create an associative relationship |
| `dream` | Consolidation cycle (annealing). Modes: `deep`, `lite` |

### Introspection & metrics
| Command | Description |
|---------|-------------|
| `observe` | Introspection report (`--json` for programmatic use) |
| `status` | Quick system status (JSON) |
| `assess` | Consciousness level (phi, xi, order metrics) |
| `stats` | Overall system statistics |

### Swarm (NATS)
| Command | Description |
|---------|-------------|
| `swarm join` | Join the QueenSync swarm over NATS |
| `swarm status` | Swarm phase snapshot (peers, frequency, coherence) — JSON |
| `swarm sync` | Force a phase sync round |
| `swarm brief "<topic>"` | Sensemaking brief on a topic (ADR-0035; local-first, `--json`) |
| `inbox tail` | Stream agent-to-agent inbox messages |

## Notes
- All commands shell out to the resolved binary, e.g. `"$KANNAKA_BIN" recall "query" --top-k 5`.
- `status` / `swarm status` print HRM boot logs to **stderr** and clean JSON to **stdout** — redirect `2>/dev/null` when parsing.
