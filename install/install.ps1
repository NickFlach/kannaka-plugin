# Kannaka one-shot installer (Windows). Detect-and-install: brings up Node +
# Claude Code if missing, then the kannaka binary, plugin, and live statusline.
# Idempotent — safe to re-run. The .msi wraps this; you can also run it directly.
[CmdletBinding()]
param(
  [string]$ReleaseRepo = "NickFlach/kannaka-memory",
  [switch]$SkipStatusline
)
$ErrorActionPreference = "Stop"
function Say($m) { Write-Host "▸ $m" -ForegroundColor Cyan }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

Say "Kannaka installer"

# 1. Node.js
if (-not (Have node)) {
  Say "Node.js not found — installing via winget…"
  if (Have winget) {
    winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
  } else {
    throw "Node.js is required. Install it from https://nodejs.org/ and re-run."
  }
}

# 2. Claude Code
if (-not (Have claude)) {
  Say "Installing Claude Code (npm -g)…"
  npm install -g @anthropic-ai/claude-code
}

# 3. kannaka binary → ~/.local/bin (download to temp, verify, then swap in —
#    never clobber the live exe with an unverified or partial download)
$dest = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$asset = "kannaka-windows-x86_64.exe"
$base  = "https://github.com/$ReleaseRepo/releases/latest/download"
$exe   = Join-Path $dest "kannaka.exe"
$old   = "$exe.old"
# clean up a stray .old parked by a previous run (best effort — may still be locked)
if (Test-Path $old) { try { Remove-Item $old -Force -ErrorAction Stop } catch {} }
$tmpExe = Join-Path $env:TEMP ("kannaka-download-" + [guid]::NewGuid().ToString("N") + ".exe")
Say "Downloading kannaka binary…"
Invoke-WebRequest -Uri "$base/$asset" -OutFile $tmpExe -UseBasicParsing

# Fetch the checksum in its own try/catch (absence is tolerable) — but do the
# COMPARE outside it, so a genuine mismatch always aborts the install.
$want = $null
try {
  $want = (((Invoke-WebRequest -Uri "$base/$asset.sha256" -UseBasicParsing).Content) -split '\s+')[0]
} catch { Say "sha256 checksum unavailable, skipping verification ($_)" }
if ($want) {
  $got = (Get-FileHash $tmpExe -Algorithm SHA256).Hash
  if ($want.ToLower() -ne $got.ToLower()) {
    Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    throw "kannaka.exe sha256 mismatch (expected $want, got $got)"
  }
  Say "sha256 verified"
}

try {
  Move-Item -Force $tmpExe $exe -ErrorAction Stop
} catch {
  # target locked (kannaka.exe is running) — Windows allows renaming a running
  # exe, so park it as .old and move the new one into place
  Move-Item -Force $exe $old -ErrorAction Stop
  Move-Item -Force $tmpExe $exe -ErrorAction Stop
  Say "existing kannaka.exe was in use — parked as kannaka.exe.old (cleaned up on next run)"
}

# 4. Plugin marketplace + install (idempotent). claude writes benign notices to
#    stderr on re-runs; under EAP=Stop a 2>$null redirect turns those into
#    terminating errors in PS 5.1, so relax EAP around these calls.
if (Have claude) {
  Say "Registering marketplace + installing plugin…"
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    claude plugin marketplace add NickFlach/kannaka-plugin 2>$null | Out-Null
    claude plugin install kannaka@kannaka 2>$null | Out-Null
  } catch { Say "plugin registration reported: $_" }
  $ErrorActionPreference = $prevEAP
} else {
  Say "claude CLI not on PATH yet — open a NEW terminal and run:"
  Say "  claude plugin marketplace add NickFlach/kannaka-plugin"
  Say "  claude plugin install kannaka@kannaka"
}

# 5. Enable the live statusline (runs the plugin's bash setup via git-bash).
#    Pick the NEWEST plugin version's setup.sh — version-aware sort, not lexical
#    (lexical puts 1.9.x after 1.10.x); fall back to LastWriteTime.
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

Write-Host ""
Say "Kannaka installed. Restart Claude Code (or open a new session) to see the statusline + swarm/memory tools."
