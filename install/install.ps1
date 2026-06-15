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
  [switch]$WithClaude,
  [switch]$SkipStatusline
)

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
$asset = "kannaka-windows-x86_64.exe"
$base  = "https://github.com/$ReleaseRepo/releases/latest/download"
$exe   = Join-Path $dest "kannaka.exe"
$old   = "$exe.old"
if (Test-Path $old) { try { Remove-Item $old -Force -ErrorAction Stop } catch {} }
$tmpExe = Join-Path $env:TEMP ("kannaka-download-" + [guid]::NewGuid().ToString("N") + ".exe")

Say "Downloading kannaka binary…"
try {
  Invoke-WebRequest -Uri "$base/$asset" -OutFile $tmpExe -UseBasicParsing
} catch {
  throw "Failed to download $asset from $base — check your internet connection. ($_)"
}

# Verify checksum if available (fetch tolerantly; compare strictly).
$want = $null
try {
  $want = (((Invoke-WebRequest -Uri "$base/$asset.sha256" -UseBasicParsing).Content) -split '\s+')[0]
} catch { Warn "sha256 checksum unavailable, skipping verification ($_)" }
if ($want) {
  $got = (Get-FileHash $tmpExe -Algorithm SHA256).Hash
  if ($want.ToLower() -ne $got.ToLower()) {
    Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    throw "kannaka.exe sha256 mismatch (expected $want, got $got)"
  }
  Say "sha256 verified"
}

# Swap the new binary into place (handles the exe being locked while running).
try {
  Move-Item -Force $tmpExe $exe -ErrorAction Stop
} catch {
  Move-Item -Force $exe $old -ErrorAction Stop
  Move-Item -Force $tmpExe $exe -ErrorAction Stop
  Say "existing kannaka.exe was in use — parked as kannaka.exe.old (cleaned up on next run)"
}
Ok "kannaka binary installed → $exe"

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
