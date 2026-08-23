# Kannaka one-shot installer (Windows).
#
# Binary-FIRST and Claude-OPTIONAL: the kannaka memory engine is a standalone
# binary that works with or without Claude Code. This installer always installs
# the binary first (the only hard requirement is being able to download it),
# puts it on PATH, and verifies it runs. THEN, if Claude Code is detected, it
# wires up the plugin + live statusline as a bonus — and if it isn't, it says so
# and finishes successfully rather than failing.
#
# Use -WithClaude to also install Node.js + Claude Code when they're missing
# (opt-in; off by default so standalone users aren't forced into a Node/Claude
# install they didn't ask for).
#
# Idempotent — safe to re-run. The .msi wraps this; you can also run it directly:
#   irm https://raw.githubusercontent.com/NickFlach/kannaka-plugin/master/install/install.ps1 | iex
[CmdletBinding()]
param(
  [string]$ReleaseRepo = "NickFlach/kannaka-memory",
  [string]$TuiRepo = "NickFlach/kannaka-tui",
  [switch]$WithClaude,
  [switch]$SkipStatusline,
  [switch]$SkipTui,
  # Constellation Pass credentials. Also read from the environment so the
  # portal can hand a subscriber one line that works, and so a re-run without
  # them leaves existing credentials alone rather than clearing them.
  [string]$NatsUser = $env:KANNAKA_NATS_USER,
  [string]$NatsPassword = $env:KANNAKA_NATS_PASSWORD
)

$InstallUrl = "https://raw.githubusercontent.com/NickFlach/kannaka-plugin/master/install/install.ps1"

function Say($m)  { Write-Host "▸ $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "✓ $m" -ForegroundColor Green }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

Say "Kannaka installer"

# ───────────────────────────────────────────────────────────────────────────
# 1. CORE: the kannaka binary → ~/.local/bin
#    This is the product. It needs nothing but the ability to download a file —
#    no Node, no Claude. Errors here are fatal (the install genuinely failed);
#    everything AFTER this is best-effort enhancement.
# ───────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$dest = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Download one release asset, refuse to install it unverified, and swap it into
# place even if the old copy is running.
#
# Was inline for the single binary; a second one (the TUI) made copying it the
# obvious move and the wrong one — a checksum check that exists twice is a
# checksum check that gets weakened once. Throws on any failure so the caller
# decides whether that is fatal; every failure path removes the partial file.
function Install-Verified {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Asset,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$Label
  )
  $b = "https://github.com/$Repo/releases/latest/download"
  $old = "$Target.old"
  if (Test-Path $old) { try { Remove-Item $old -Force -ErrorAction Stop } catch {} }
  # A GUID temp name per download: a shared one raced when two installs
  # overlapped and would have verified the wrong file against the wrong digest.
  $tmp = Join-Path $env:TEMP ("kannaka-download-" + [guid]::NewGuid().ToString("N") + ".exe")

  Say "Downloading $Label ($Asset)…"
  try {
    Invoke-WebRequest -Uri "$b/$Asset" -OutFile $tmp -UseBasicParsing
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "Failed to download $Asset from $b — check your internet connection. ($_)"
  }

  # The release always publishes a per-file .sha256 (Sigstore + checksums
  # trust). A MISSING checksum means we cannot verify — fail closed rather than
  # install an unverified binary. (A failed fetch used to warn and skip.)
  $want = $null
  try {
    $want = (((Invoke-WebRequest -Uri "$b/$Asset.sha256" -UseBasicParsing).Content) -split '\s+')[0]
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "checksum $Asset.sha256 could not be downloaded — refusing to install unverified. ($_)"
  }
  if (-not $want) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "checksum $Asset.sha256 was empty — refusing to install unverified."
  }
  $got = (Get-FileHash $tmp -Algorithm SHA256).Hash
  if ($want.ToLower() -ne $got.ToLower()) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw "$Label sha256 mismatch (expected $want, got $got)"
  }
  Say "sha256 verified"

  # Swap into place, handling the exe being locked because it is running.
  try {
    Move-Item -Force $tmp $Target -ErrorAction Stop
  } catch {
    Move-Item -Force $Target $old -ErrorAction Stop
    Move-Item -Force $tmp $Target -ErrorAction Stop
    Say "existing $Label was in use — parked as $(Split-Path $old -Leaf) (cleaned up on next run)"
  }
  Ok "$Label installed → $Target"
}

$exe = Join-Path $dest "kannaka.exe"
Install-Verified -Repo $ReleaseRepo -Asset "kannaka-windows-x86_64.exe" -Target $exe -Label "kannaka"

# ───────────────────────────────────────────────────────────────────────────
# 2. PATH: make sure ~/.local/bin is reachable, or `kannaka` will look like it
#    "did nothing" on a fresh machine (the #1 silent-failure cause).
# ───────────────────────────────────────────────────────────────────────────
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ';') -notcontains $dest) {
  [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(';')) + ";" + $dest), "User")
  Say "Added $dest to your PATH — open a NEW terminal for `kannaka` to be found."
}
if (($env:Path -split ';') -notcontains $dest) { $env:Path = "$env:Path;$dest" }

# Verify the binary actually runs (surfaces a broken download instead of silence).
try {
  $ver = & $exe --version 2>$null | Select-Object -First 1
  if ($ver) { Ok "kannaka is working: $ver" }
} catch { Warn "kannaka installed but '--version' failed to run ($_)" }

# ───────────────────────────────────────────────────────────────────────────
# 2b. THE DASHBOARD: kannaka-tui.exe → ~/.local/bin
#
# Its own repo and releases since the binary was extracted at v0.5.12, with the
# same asset naming, so it rides the same verified download. NOT fatal: the
# engine is the product and a missing dashboard must not cost somebody an
# otherwise working install — hence the try/catch around a function that
# throws.
#
# (consciousness-core is deliberately absent. It is a LIBRARY — no [[bin]], no
# main.rs — compiled into kannaka.exe above, so anyone who has kannaka already
# has its physics. There is nothing separate to install.)
# ───────────────────────────────────────────────────────────────────────────
$tui = Join-Path $dest "kannaka-tui.exe"
if (-not $SkipTui) {
  try {
    Install-Verified -Repo $TuiRepo -Asset "kannaka-tui-windows-x86_64.exe" -Target $tui -Label "kannaka-tui"
  } catch {
    Warn "kannaka-tui was not installed — the engine is fine; re-run to retry. ($_)"
  }
}

# ───────────────────────────────────────────────────────────────────────────
# 2c. CONSTELLATION PASS: authenticated swarm credentials.
#
# `kannaka swarm serve` and `listen --auto-sync` need an AUTHENTICATED NATS
# connection; anonymous is read-only. The binary reads NATS_USER /
# NATS_PASSWORD from the ENVIRONMENT (src/nats.rs — precedence: explicit > env
# > url), and nothing ever put them there for a person.
#
# The POSIX installer writes ~/.kannaka-nats.env and teaches the shell rc to
# source it. Windows has no rc to source, so the native equivalent is a
# USER-level environment variable: it reaches PowerShell, cmd, AND Git Bash,
# because Git Bash inherits the Windows user environment rather than keeping
# its own. One mechanism covers all three terminals a Windows subscriber
# actually uses, which a dotfile in $HOME would not — nothing on Windows reads
# that file automatically.
#
# Persisted at "User" scope rather than "Machine": these are one person's
# credentials, and Machine scope would hand them to every account on the box
# and require elevation to write.
# ───────────────────────────────────────────────────────────────────────────
if ($NatsUser -and $NatsPassword) {
  [Environment]::SetEnvironmentVariable("NATS_USER", $NatsUser, "User")
  [Environment]::SetEnvironmentVariable("NATS_PASSWORD", $NatsPassword, "User")
  # Also for THIS session, so the summary below reports the credentials rather
  # than which terminal we happen to be running in.
  $env:NATS_USER = $NatsUser
  $env:NATS_PASSWORD = $NatsPassword
  Ok "Constellation Pass credentials saved to your user environment"
  Say "Open a NEW terminal for them to take effect elsewhere."
} elseif ([Environment]::GetEnvironmentVariable("NATS_USER", "User")) {
  Say "Constellation Pass credentials already present in your user environment"
  if (-not $env:NATS_USER) {
    $env:NATS_USER = [Environment]::GetEnvironmentVariable("NATS_USER", "User")
  }
}

# ───────────────────────────────────────────────────────────────────────────
# 3. OPTIONAL: Claude Code integration. Detect-and-enhance. Never fatal.
# ───────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Continue"   # nothing below should abort a done install

if (-not (Have claude) -and $WithClaude) {
  Say "-WithClaude set — installing Node.js + Claude Code…"
  if (-not (Have node)) {
    if (Have winget) {
      winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
      $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    } else {
      Warn "winget not available — install Node.js from https://nodejs.org/ then re-run with -WithClaude."
    }
  }
  if (Have npm) { npm install -g @anthropic-ai/claude-code }
}

if (Have claude) {
  Say "Claude Code detected — registering marketplace + installing plugin…"
  try {
    claude plugin marketplace add NickFlach/kannaka-plugin 2>$null | Out-Null
    claude plugin install kannaka@kannaka 2>$null | Out-Null
    Ok "kannaka plugin installed into Claude Code"
  } catch { Warn "plugin registration reported: $_" }

  if (-not $SkipStatusline) {
    $setup = Get-ChildItem -Path (Join-Path $HOME ".claude\plugins\cache\kannaka") -Recurse -Filter setup.sh -ErrorAction SilentlyContinue |
             Sort-Object -Property @{Expression={
               $v = $null
               if ($_.FullName -match '(\d+\.\d+(\.\d+)?(\.\d+)?)') { try { $v = [version]$Matches[1] } catch {} }
               if ($v) { $v } else { [version]"0.0" }
             }}, LastWriteTime | Select-Object -Last 1
    if ($setup -and (Have bash)) {
      Say "Enabling statusline…"
      bash ($setup.FullName -replace '\\','/') on
    } else {
      Say "Statusline: run '/kannaka statusline on' inside Claude Code to enable."
    }
  }
} else {
  Write-Host ""
  Ok "Kannaka is installed and works standalone — no Claude Code required."
  Say "Try it:"
  Say "    kannaka remember `"wave interference is how memory computes`" --importance 0.8"
  Say "    kannaka recall `"how does memory work`""
  Say "    kannaka dream --mode deep"
  Write-Host ""
  Say "Want the Claude Code plugin + live statusline too? Install Claude Code, then re-run this"
  Say "installer (or pass -WithClaude), or inside Claude run:"
  Say "    claude plugin marketplace add NickFlach/kannaka-plugin"
  Say "    claude plugin install kannaka@kannaka"
}

Write-Host ""
Ok "Done. kannaka.exe → $exe"
if (Test-Path $tui) { Ok "     kannaka-tui.exe → $tui" }
if ($env:NATS_USER) {
  Ok "     Constellation Pass: authenticated as $env:NATS_USER"
} else {
  Write-Host ""
  Say "Swarm access is ANONYMOUS (read-only). A Constellation Pass unlocks"
  Say "'kannaka swarm serve' and 'listen --auto-sync'. With your pass credentials:"
  # `irm | iex` cannot take parameters — iex evaluates the text and the script's
  # param() block never sees the arguments. Rebuilding it as a scriptblock and
  # invoking THAT is the form that actually passes them.
  Say "    & ([scriptblock]::Create((irm $InstallUrl))) -NatsUser USER -NatsPassword PASS"
}
